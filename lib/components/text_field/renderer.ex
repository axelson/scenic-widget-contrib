defmodule ScenicWidgets.TextField.Renderer do
  @moduledoc """
  Rendering logic for the TextField component.

  Phase 1: Basic rendering - background, lines, cursor
  Phase 2+: Incremental updates, scrolling, wrapping

  Uses Widgex.Scroll.ScrollRenderer for scrollable content with scissor clipping.
  """

  alias Scenic.Graph
  alias Scenic.Primitives
  alias ScenicWidgets.TextField.State
  alias Widgex.Scroll.ScrollRenderer
  alias Widgex.Scroll.ScrollState

  @doc """
  Initial render of the TextField component.

  Creates the complete graph structure:
  - Background (optional - supports :clear for transparent)
  - Border
  - Line numbers (if enabled, outside scroll area)
  - Scrollable content area with scissor clipping:
    - Semantic accessibility content (hidden)
    - Text lines
    - Selection highlighting
    - Cursor
  - Scrollbars
  """
  def initial_render(graph, %State{} = state) do
    graph
    |> render_background(state)
    |> render_border(state)
    |> render_line_numbers(state)
    |> render_scrollable_content(state)
    |> ScrollRenderer.render_scrollbars(state.scroll, text_content_frame(state))
  end

  # Helper to make piping work with render_scrollable_content
  defp render_scrollable_content(graph, state), do: do_render_scrollable_content(state, graph)

  # Create a frame for the text content area (excluding line numbers)
  defp text_content_frame(%State{frame: frame, show_line_numbers: false}) do
    frame
  end

  defp text_content_frame(%State{frame: frame, show_line_numbers: true, line_number_width: ln_width}) do
    # Adjust frame to exclude line number area
    %{frame |
      size: %{frame.size | width: frame.size.width - ln_width},
      pin: %{frame.pin | x: frame.pin.x + ln_width}
    }
  end

  # Render the scrollable text content area
  defp do_render_scrollable_content(%State{} = state, graph) do
    content_frame = text_content_frame(state)
    x_offset = if state.show_line_numbers, do: state.line_number_width, else: 0

    Primitives.group(graph, fn g ->
      ScrollRenderer.scrollable_group(g, state.scroll, content_frame, fn scroll_g ->
        scroll_g
        |> render_semantic_content(state)
        |> render_selection(state)
        |> render_lines_content(state)
        |> render_cursor(state)
      end, id: :text_content)
    end, translate: {x_offset, 0})
  end

  @doc """
  Update render - intelligently updates only what changed.
  """
  def update_render(graph, old_state, new_state) do
    graph
    |> update_border_if_changed(old_state, new_state)
    |> update_scroll_if_changed(old_state, new_state)
    |> update_lines_if_changed(old_state, new_state)
    |> update_line_numbers_if_changed(old_state, new_state)
    |> update_semantic_content_if_changed(old_state, new_state)
    |> update_cursor_position(old_state, new_state)
  end

  defp update_scroll_if_changed(graph, %State{scroll: old_scroll}, %State{scroll: new_scroll} = new_state) do
    content_frame = text_content_frame(new_state)

    graph
    |> ScrollRenderer.update_scroll_transform(:text_content, old_scroll, new_scroll)
    |> ScrollRenderer.update_scrollbars(old_scroll, new_scroll, content_frame)
  end

  defp update_border_if_changed(graph, %State{focused: old_focused}, %State{focused: new_focused, colors: colors})
      when old_focused != new_focused do
    border_color = if new_focused, do: colors.focused_border, else: colors.border

    graph
    |> Graph.modify(:border, fn primitive ->
      Primitives.update_opts(primitive, stroke: {1, border_color})
    end)
  end

  defp update_border_if_changed(graph, _old_state, _new_state), do: graph

  defp update_lines_if_changed(graph, %State{lines: old_lines}, %State{lines: new_lines} = new_state)
      when old_lines != new_lines do
    # Lines changed - re-render all text lines inside the scrollable group
    # This handles word wrapping correctly by regenerating wrapped lines
    font = new_state.font
    colors = new_state.colors
    line_height = State.line_height(new_state)
    scroll = new_state.scroll
    wrap_mode = new_state.wrap_mode
    x_offset = 10  # Padding inside scroll area

    # Calculate text width for wrapping
    text_width = scroll.viewport_width - 20

    # Wrap lines
    display_lines = case wrap_mode do
      :word -> new_state.lines |> Enum.flat_map(&wrap_line(&1, text_width, font))
      :char -> new_state.lines |> Enum.flat_map(&wrap_line_by_chars(&1, text_width, font))
      :none -> new_state.lines
    end

    # Calculate max display lines we might have had before
    old_display_lines = case wrap_mode do
      :word -> old_lines |> Enum.flat_map(&wrap_line(&1, text_width, font))
      :char -> old_lines |> Enum.flat_map(&wrap_line_by_chars(&1, text_width, font))
      :none -> old_lines
    end
    max_display_lines = max(length(old_display_lines), length(display_lines))

    # Delete all old text lines and re-render
    graph = Enum.reduce(1..max(1, max_display_lines), graph, fn line_num, g ->
      Graph.delete(g, {:text_line, line_num})
    end)

    # Render all wrapped lines
    Enum.reduce(Enum.with_index(display_lines, 1), graph, fn {line_text, line_num}, g ->
      y_pos = (line_num - 1) * line_height + line_height

      g
      |> Primitives.text(
        line_text,
        translate: {x_offset, y_pos},
        fill: colors.text,
        font_size: font.size,
        font: font.name,
        id: {:text_line, line_num}
      )
    end)
  end

  defp update_lines_if_changed(graph, _old_state, _new_state), do: graph

  defp update_line_numbers_if_changed(graph, %State{lines: old_lines, show_line_numbers: true},
                                       %State{lines: new_lines, show_line_numbers: true} = new_state)
      when length(old_lines) != length(new_lines) do
    # Line count changed - update line numbers
    # Remove old line numbers
    graph = Enum.reduce(1..length(old_lines), graph, fn line_num, g ->
      Graph.delete(g, {:line_number, line_num})
    end)

    # Add new line numbers
    width = new_state.line_number_width
    font = new_state.font
    colors = new_state.colors
    line_height = State.line_height(new_state)

    Enum.reduce(1..length(new_lines), graph, fn line_num, g ->
      y_pos = (line_num - 1) * line_height + line_height
      x_pos = width - 10

      g
      |> Primitives.text(
        "#{line_num}",
        translate: {x_pos, y_pos},
        fill: colors.line_numbers,
        font_size: font.size,
        text_align: :right,
        id: {:line_number, line_num}
      )
    end)
  end

  defp update_line_numbers_if_changed(graph, _old_state, _new_state), do: graph

  defp update_semantic_content_if_changed(graph, %State{lines: old_lines}, %State{lines: new_lines} = new_state)
      when old_lines != new_lines do
    # Text changed - update semantic content for accessibility
    full_content = Enum.join(new_lines, "\n")

    graph
    |> Graph.modify(:semantic_content, fn primitive ->
      Primitives.text(primitive, full_content)
    end)
  end

  defp update_semantic_content_if_changed(graph, _old_state, _new_state), do: graph

  defp update_cursor_position(graph, %State{cursor: old_cursor}, %State{cursor: new_cursor} = new_state)
      when old_cursor != new_cursor do
    {line, col} = new_cursor
    x_offset = State.text_x_offset(new_state)
    line_height = State.line_height(new_state)

    # Get the text before cursor to calculate accurate position
    current_line = State.get_line(new_state, line)
    text_before_cursor = String.slice(current_line, 0, col - 1)

    # Use FontMetrics if available for accurate positioning
    cursor_x = x_offset + State.string_width(new_state, text_before_cursor)

    # Position cursor at line top with small padding
    # Original QuillEx had cursor at ~4px from line top, text baseline at line_height
    # This provides visual separation from descenders of previous line
    line_top = (line - 1) * line_height
    cursor_y = line_top + 4

    # Only show cursor if focused AND cursor_visible (for blinking)
    should_show_cursor = new_state.focused and new_state.cursor_visible

    graph
    |> Graph.modify(:cursor, fn primitive ->
      Primitives.update_opts(primitive, translate: {cursor_x, cursor_y}, hidden: !should_show_cursor)
    end)
  end

  defp update_cursor_position(graph, _old_state, _new_state), do: graph

  @doc """
  Quick update for cursor visibility (blink animation).
  Only updates cursor visibility without re-rendering everything.
  """
  def update_cursor_visibility(graph, %State{focused: focused, cursor_visible: cursor_visible} = state) do
    # Only show cursor if focused AND cursor_visible (for blinking)
    should_show_cursor = focused and cursor_visible

    graph
    |> Graph.modify(:cursor, fn primitive ->
      Primitives.update_opts(primitive, hidden: !should_show_cursor)
    end)
  end

  # ===== PRIVATE RENDERING FUNCTIONS =====

  defp render_background(graph, %State{colors: %{background: :clear}}) do
    # Transparent background - don't render anything
    graph
  end

  defp render_background(graph, %State{frame: frame, colors: colors}) do
    graph
    |> Primitives.rect(
      {frame.size.width, frame.size.height},
      fill: colors.background,
      id: :background
    )
  end

  defp render_border(graph, %State{frame: frame, colors: colors, focused: focused}) do
    border_color = if focused, do: colors.focused_border, else: colors.border

    graph
    |> Primitives.rect(
      {frame.size.width, frame.size.height},
      stroke: {1, border_color},
      id: :border
    )
  end

  defp render_line_numbers(graph, %State{show_line_numbers: false}), do: graph

  defp render_line_numbers(graph, %State{
    show_line_numbers: true,
    lines: lines,
    line_number_width: width,
    font: font,
    colors: colors,
    vertical_scroll_offset: scroll_y
  } = state) do
    # Render line numbers in left margin (with viewport optimization)
    line_height = State.line_height(state)
    {render_start, render_end} = State.visible_line_range(state)

    # Always render line 1, then only render visible lines
    Enum.reduce(Enum.with_index(lines, 1), graph, fn {_line, line_num}, g ->
      if line_num == 1 or (line_num >= render_start and line_num <= render_end) do
        y_pos = (line_num - 1) * line_height + line_height + scroll_y
        x_pos = width - 10  # Right-align within the margin

        g
        |> Primitives.text(
          "#{line_num}",
          translate: {x_pos, y_pos},
          fill: colors.line_numbers,
          font_size: font.size,
          text_align: :right,
          id: {:line_number, line_num}
        )
      else
        g
      end
    end)
  end

  defp render_selection(graph, %State{selection: nil}), do: graph

  defp render_selection(graph, %State{
    selection: {start_pos, end_pos},
    lines: lines,
    font: font
  } = state) do
    # Normalize selection - ensure start comes before end
    {{sel_start_line, sel_start_col}, {sel_end_line, sel_end_col}} =
      if start_pos <= end_pos do
        {start_pos, end_pos}
      else
        {end_pos, start_pos}
      end

    # Skip if selection is empty (start == end)
    if sel_start_line == sel_end_line and sel_start_col == sel_end_col do
      graph
    else
      render_selection_rectangles(
        graph,
        {sel_start_line, sel_start_col},
        {sel_end_line, sel_end_col},
        lines,
        font,
        state
      )
    end
  end

  defp render_selection_rectangles(graph, {sel_start_line, sel_start_col}, {sel_end_line, sel_end_col}, lines, _font, state) do
    x_offset = State.text_x_offset(state)
    line_height = State.line_height(state)

    # Selection color - semi-transparent blue
    selection_color = {:color_rgba, {100, 150, 200, 100}}

    # Render selection rectangles for each line in the selection
    Enum.reduce(sel_start_line..sel_end_line, graph, fn line_num, acc_graph ->
      y_position = (line_num - 1) * line_height
      line_text = Enum.at(lines, line_num - 1, "")

      # Calculate selection bounds for this line
      {start_col_on_line, end_col_on_line} =
        cond do
          line_num == sel_start_line and line_num == sel_end_line ->
            # Selection within same line
            {sel_start_col, sel_end_col}
          line_num == sel_start_line ->
            # First line of multi-line selection
            {sel_start_col, String.length(line_text) + 1}
          line_num == sel_end_line ->
            # Last line of multi-line selection
            {1, sel_end_col}
          true ->
            # Middle line of multi-line selection
            {1, String.length(line_text) + 1}
        end

      # Calculate pixel coordinates for selection rectangle using FontMetrics
      text_before_selection = String.slice(line_text, 0, start_col_on_line - 1)
      selected_text = String.slice(line_text, start_col_on_line - 1, max(0, end_col_on_line - start_col_on_line))

      start_x_offset = State.string_width(state, text_before_selection)
      selection_width = State.string_width(state, selected_text)

      # Add selection rectangle to graph
      acc_graph
      |> Primitives.rect(
        {selection_width, line_height},
        fill: selection_color,
        translate: {x_offset + start_x_offset, y_position},
        id: {:selection_highlight, line_num}
      )
    end)
  end

  # Legacy render_lines - kept for backwards compatibility
  defp render_lines(graph, %State{
    lines: lines,
    font: font,
    colors: colors,
    wrap_mode: wrap_mode,
    frame: frame,
    show_line_numbers: show_line_numbers,
    line_number_width: line_number_width,
    vertical_scroll_offset: scroll_y
  } = state) do
    x_offset = State.text_x_offset(state)
    line_height = State.line_height(state)

    # Calculate available width for text
    text_width = if show_line_numbers do
      frame.size.width - line_number_width - 20  # Account for margins
    else
      frame.size.width - 20  # 10px padding on each side
    end

    # Wrap lines if needed
    display_lines = if wrap_mode == :word do
      lines
      |> Enum.flat_map(&wrap_line(&1, text_width, font))
    else
      lines
    end

    # Calculate viewport range for optimization
    {render_start, render_end} = State.visible_line_range(state)

    # Only render lines within viewport + buffer
    Enum.reduce(Enum.with_index(display_lines, 1), graph, fn {line_text, line_num}, g ->
      if line_num >= render_start and line_num <= render_end do
        y_pos = (line_num - 1) * line_height + line_height + scroll_y

        g
        |> Primitives.text(
          line_text,
          translate: {x_offset, y_pos},
          fill: colors.text,
          font_size: font.size,
          font: font.name,
          id: {:text_line, line_num}
        )
      else
        g
      end
    end)
  end

  # Render lines inside scrollable group (scroll transform handled by group)
  defp render_lines_content(graph, %State{
    lines: lines,
    font: font,
    colors: colors,
    wrap_mode: wrap_mode,
    scroll: scroll
  } = state) do
    line_height = State.line_height(state)
    # Use small left padding within the scroll area
    x_offset = 10

    # Use the scroll viewport width for text wrapping (already excludes line numbers)
    text_width = scroll.viewport_width - 20  # 10px padding on each side
    IO.puts("[TextField] wrap_mode=#{wrap_mode}, viewport_width=#{scroll.viewport_width}, text_width=#{text_width}")

    # Wrap lines if needed
    display_lines = case wrap_mode do
      :word ->
        wrapped = lines |> Enum.flat_map(&wrap_line(&1, text_width, font))
        IO.puts("[TextField] Wrapped #{length(lines)} lines into #{length(wrapped)} display lines")
        wrapped
      :char ->
        lines |> Enum.flat_map(&wrap_line_by_chars(&1, text_width, font))
      :none ->
        lines
    end

    # Render all lines (scissor handles clipping)
    Enum.reduce(Enum.with_index(display_lines, 1), graph, fn {line_text, line_num}, g ->
      # Position from top of content, baseline at line_height
      y_pos = (line_num - 1) * line_height + line_height

      g
      |> Primitives.text(
        line_text,
        translate: {x_offset, y_pos},
        fill: colors.text,
        font_size: font.size,
        font: font.name,
        id: {:text_line, line_num}
      )
    end)
  end

  # Character-based wrapping for :char wrap_mode
  defp wrap_line_by_chars(line, max_width, font) do
    char_width = trunc(font.size * 0.6)  # Monospace approximation
    max_chars = max(1, trunc(max_width / char_width))

    if String.length(line) <= max_chars do
      [line]
    else
      line
      |> String.graphemes()
      |> Enum.chunk_every(max_chars)
      |> Enum.map(&Enum.join/1)
    end
  end

  # Wrap a single line into multiple lines based on available width
  defp wrap_line(line, max_width, font) do
    # Use font size to estimate character width (monospace approximation)
    char_width = trunc(font.size * 0.6)
    max_chars = max(1, trunc(max_width / char_width))
    IO.puts("[wrap_line] max_width=#{max_width}, font_size=#{font.size}, char_width=#{char_width}, max_chars=#{max_chars}, line_len=#{String.length(line)}")

    if String.length(line) <= max_chars do
      [line]
    else
      wrap_line_by_words(line, max_chars)
    end
  end

  # Word-based wrapping
  defp wrap_line_by_words(line, max_chars) do
    words = String.split(line, " ")

    words
    |> Enum.reduce({[], ""}, fn word, {wrapped_lines, current_line} ->
      test_line = if current_line == "", do: word, else: current_line <> " " <> word

      if String.length(test_line) <= max_chars do
        # Word fits on current line
        {wrapped_lines, test_line}
      else
        # Word doesn't fit, start new line
        if current_line == "" do
          # Single word exceeds line - just add it anyway
          {wrapped_lines ++ [word], ""}
        else
          # Move to next line
          {wrapped_lines ++ [current_line], word}
        end
      end
    end)
    |> then(fn {wrapped_lines, current_line} ->
      if current_line == "", do: wrapped_lines, else: wrapped_lines ++ [current_line]
    end)
  end

  defp render_cursor(graph, %State{
    cursor: {line, col},
    cursor_visible: visible,
    focused: focused,
    cursor_mode: cursor_mode,
    colors: colors
  } = state) do
    x_offset = State.text_x_offset(state)
    line_height = State.line_height(state)

    # Get the text before cursor to calculate accurate position
    current_line = State.get_line(state, line)
    text_before_cursor = String.slice(current_line, 0, col - 1)

    # Use FontMetrics for accurate positioning
    cursor_x = x_offset + State.string_width(state, text_before_cursor)

    # Position cursor at line top with small padding
    # Original QuillEx had cursor at ~4px from line top, text baseline at line_height
    # This provides visual separation from descenders of previous line
    line_top = (line - 1) * line_height
    cursor_y = line_top + 4

    # Calculate cursor width based on mode
    cursor_width = case cursor_mode do
      :cursor -> 2  # Thin vertical line
      :block -> State.char_width(state)  # Full character width
      :hidden -> 0  # No cursor
    end

    # Only show when focused AND visible (for blinking) AND not hidden mode
    should_show = focused and visible and cursor_mode != :hidden

    # Render cursor
    graph
    |> Primitives.rect(
      {cursor_width, line_height},
      translate: {cursor_x, cursor_y},
      fill: colors.cursor,
      hidden: !should_show,
      id: :cursor
    )
  end

  @doc """
  Render hidden semantic content for accessibility.
  This provides a single text primitive with all buffer content that can be queried
  by accessibility tools without affecting visual rendering.
  """
  defp render_semantic_content(graph, %State{lines: lines, id: id, editable: editable, mode: mode}) do
    # Join all lines into a single string for semantic access
    full_content = Enum.join(lines, "\n")

    # Add hidden text primitive with semantic metadata
    graph
    |> Primitives.text(
      full_content,
      id: :semantic_content,
      hidden: true,
      semantic: %{
        type: :text_field,
        field_id: id,
        editable: editable,
        multiline: mode == :multi_line,
        role: if(mode == :multi_line, do: :textbox, else: :textfield)
      }
    )
  end
end
