defmodule ScenicWidgets.TextField.Renderer do
  @moduledoc """
  Rendering logic for the TextField component.

  ## Architecture

  The TextField uses a two-panel layout when line numbers are enabled:

  ```
  TextField Frame
  ├── Line Number Gutter (fixed width, vertical scroll only)
  │   └── Scissor clip (gutter width × frame height)
  │       └── Group (translated by vertical scroll offset only)
  │           └── Line number primitives
  │
  └── Text Content Area (remaining width, full scroll)
      └── Scissor clip (content width × frame height)
          └── Group (translated by both scroll offsets)
              └── Text line primitives
              └── Cursor
              └── Selection
  ```

  Key features:
  - Line numbers scroll vertically WITH text but NOT horizontally
  - Both areas share the same vertical scroll state
  - Primitives are managed dynamically (no pre-allocation needed)
  - When `show_line_numbers: false`, only text content area is rendered
  """

  alias Scenic.Graph
  alias Scenic.Primitives
  alias ScenicWidgets.TextField.State

  @doc """
  Initial render of the TextField component.
  """
  def initial_render(graph, %State{} = state) do
    graph
    |> render_background(state)
    |> render_border(state)
    |> render_gutter_and_content(state)
    |> render_scrollbars(state)
  end

  @doc """
  Update render - intelligently updates only what changed.
  """
  def update_render(graph, old_state, new_state) do
    graph
    |> update_border_if_changed(old_state, new_state)
    |> update_gutter_scroll(old_state, new_state)
    |> update_content_scroll(old_state, new_state)
    |> update_lines_if_changed(old_state, new_state)
    |> update_line_numbers_if_changed(old_state, new_state)
    |> update_cursor_if_changed(old_state, new_state)
    |> update_scrollbars_if_changed(old_state, new_state)
  end

  @doc """
  Quick update for cursor visibility (blink animation).
  """
  def update_cursor_visibility(graph, %State{focused: focused, cursor_visible: cursor_visible}) do
    should_show_cursor = focused and cursor_visible

    graph
    |> Graph.modify(:cursor, fn primitive ->
      Primitives.update_opts(primitive, hidden: !should_show_cursor)
    end)
  end

  # ===== INITIAL RENDER HELPERS =====

  defp render_background(graph, %State{colors: %{background: :clear}}), do: graph

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

  # Render both the gutter (line numbers) and text content areas
  defp render_gutter_and_content(graph, %State{show_line_numbers: false} = state) do
    # No line numbers - just render text content area taking full width
    render_text_content_area(graph, state, 0, state.frame.size.width)
  end

  defp render_gutter_and_content(graph, %State{show_line_numbers: true, line_number_width: gutter_width} = state) do
    content_width = state.frame.size.width - gutter_width

    graph
    |> render_line_number_gutter(state, gutter_width)
    |> render_text_content_area(state, gutter_width, content_width)
  end

  # Render the line number gutter with its own scissor clip
  # Scrolls vertically with text but NOT horizontally
  defp render_line_number_gutter(graph, %State{} = state, gutter_width) do
    frame_height = state.frame.size.height
    scroll = state.scroll
    line_height = State.line_height(state)

    # Build line number to source line mapping for wrapped lines
    # This returns one entry per DISPLAY line
    line_mapping = build_line_number_mapping(state.lines, state)

    Primitives.group(graph, fn outer_g ->
      # Inner group that scrolls vertically
      Primitives.group(outer_g, fn inner_g ->
        # Render line numbers for each display line
        Enum.reduce(Enum.with_index(line_mapping, 1), inner_g, fn {{source_line_num, is_first_of_source}, display_line_num}, g ->
          y_pos = (display_line_num - 1) * line_height + line_height
          x_pos = gutter_width - 10  # Right-align

          # Only show line number for first display line of each source line
          line_text = if is_first_of_source, do: "#{source_line_num}", else: ""

          g
          |> Primitives.text(
            line_text,
            translate: {x_pos, y_pos},
            fill: state.colors.line_numbers,
            font_size: state.font.size,
            text_align: :right,
            id: {:line_number, display_line_num}
          )
        end)
      end,
        id: :gutter_content,
        translate: {0, -scroll.offset_y}  # Only vertical scroll
      )
    end,
      id: :gutter_group,
      scissor: {gutter_width, frame_height}
    )
  end

  # Render the main text content area with full scrolling
  defp render_text_content_area(graph, %State{} = state, x_offset, content_width) do
    frame_height = state.frame.size.height
    scroll = state.scroll
    line_height = State.line_height(state)
    text_padding = 10

    # Calculate wrapped display lines
    display_lines = wrap_lines(state)

    Primitives.group(graph, fn outer_g ->
      # Inner group that scrolls both directions
      Primitives.group(outer_g, fn inner_g ->
        inner_g
        |> render_semantic_content(state, display_lines)
        |> render_selection(state)
        |> render_text_lines(state, display_lines, text_padding, line_height)
        |> render_cursor(state, text_padding, line_height)
      end,
        id: :text_content,
        translate: {-scroll.offset_x, -scroll.offset_y}
      )
    end,
      id: :content_group,
      translate: {x_offset, 0},
      scissor: {content_width, frame_height}
    )
  end

  # Render all text lines
  defp render_text_lines(graph, %State{} = state, display_lines, x_offset, line_height) do
    Enum.reduce(Enum.with_index(display_lines, 1), graph, fn {line_text, line_num}, g ->
      y_pos = (line_num - 1) * line_height + line_height

      g
      |> Primitives.text(
        line_text,
        translate: {x_offset, y_pos},
        fill: state.colors.text,
        font_size: state.font.size,
        font: state.font.name,
        id: {:text_line, line_num}
      )
    end)
  end

  # Render the cursor
  defp render_cursor(graph, %State{
    cursor: {line, col},
    cursor_visible: visible,
    focused: focused,
    cursor_mode: cursor_mode,
    colors: colors
  } = state, x_offset, line_height) do
    # Get cursor position in display line coordinates
    {display_line, display_col} = source_to_display_cursor(state, {line, col})

    # Get the text before cursor to calculate accurate position
    display_lines = wrap_lines(state)
    current_line = Enum.at(display_lines, display_line - 1, "")
    text_before_cursor = String.slice(current_line, 0, max(0, display_col - 1))

    # Calculate cursor X position
    cursor_x = x_offset + State.string_width(state, text_before_cursor)

    # Position cursor at line top
    line_top = (display_line - 1) * line_height
    cursor_y = line_top + 4

    # Calculate cursor width based on mode
    cursor_width = case cursor_mode do
      :cursor -> 2
      :block -> State.char_width(state)
      :hidden -> 0
    end

    should_show = focused and visible and cursor_mode != :hidden

    graph
    |> Primitives.rect(
      {cursor_width, line_height},
      translate: {cursor_x, cursor_y},
      fill: colors.cursor,
      hidden: !should_show,
      id: :cursor
    )
  end

  # Render hidden semantic content for accessibility
  defp render_semantic_content(graph, %State{id: id, editable: editable, mode: mode}, display_lines) do
    full_content = Enum.join(display_lines, "\n")

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

  # Render selection highlighting
  defp render_selection(graph, %State{selection: nil}), do: graph

  defp render_selection(graph, %State{selection: {start_pos, end_pos}} = state) do
    # Normalize selection
    {{sel_start_line, sel_start_col}, {sel_end_line, sel_end_col}} =
      if start_pos <= end_pos, do: {start_pos, end_pos}, else: {end_pos, start_pos}

    if sel_start_line == sel_end_line and sel_start_col == sel_end_col do
      graph
    else
      render_selection_rectangles(graph, state, {sel_start_line, sel_start_col}, {sel_end_line, sel_end_col})
    end
  end

  defp render_selection_rectangles(graph, state, {sel_start_line, sel_start_col}, {sel_end_line, sel_end_col}) do
    x_offset = 10
    line_height = State.line_height(state)
    display_lines = wrap_lines(state)
    selection_color = {:color_rgba, {100, 150, 200, 100}}

    Enum.reduce(sel_start_line..sel_end_line, graph, fn line_num, acc_graph ->
      y_position = (line_num - 1) * line_height
      line_text = Enum.at(display_lines, line_num - 1, "")

      {start_col_on_line, end_col_on_line} =
        cond do
          line_num == sel_start_line and line_num == sel_end_line ->
            {sel_start_col, sel_end_col}
          line_num == sel_start_line ->
            {sel_start_col, String.length(line_text) + 1}
          line_num == sel_end_line ->
            {1, sel_end_col}
          true ->
            {1, String.length(line_text) + 1}
        end

      text_before_selection = String.slice(line_text, 0, start_col_on_line - 1)
      selected_text = String.slice(line_text, start_col_on_line - 1, max(0, end_col_on_line - start_col_on_line))

      start_x_offset = State.string_width(state, text_before_selection)
      selection_width = State.string_width(state, selected_text)

      acc_graph
      |> Primitives.rect(
        {selection_width, line_height},
        fill: selection_color,
        translate: {x_offset + start_x_offset, y_position},
        id: {:selection_highlight, line_num}
      )
    end)
  end

  # Render scrollbars using ScrollRenderer
  defp render_scrollbars(graph, %State{scroll: scroll, frame: frame} = _state) do
    alias Widgex.Scroll.ScrollRenderer
    ScrollRenderer.render_scrollbars(graph, scroll, frame)
  end

  # ===== UPDATE HELPERS =====

  defp update_border_if_changed(graph, %State{focused: old_focused}, %State{focused: new_focused, colors: colors})
      when old_focused != new_focused do
    border_color = if new_focused, do: colors.focused_border, else: colors.border

    graph
    |> Graph.modify(:border, fn primitive ->
      Primitives.update_opts(primitive, stroke: {1, border_color})
    end)
  end

  defp update_border_if_changed(graph, _old_state, _new_state), do: graph

  # Update gutter scroll position (vertical only)
  defp update_gutter_scroll(graph, %State{scroll: old_scroll, show_line_numbers: true},
                            %State{scroll: new_scroll, show_line_numbers: true})
      when old_scroll.offset_y != new_scroll.offset_y do
    try do
      Graph.modify(graph, :gutter_content, fn primitive ->
        Scenic.Primitive.put_style(primitive, :translate, {0, -new_scroll.offset_y})
      end)
    rescue
      _ -> graph
    end
  end

  defp update_gutter_scroll(graph, _old_state, _new_state), do: graph

  # Update content scroll position (both directions)
  defp update_content_scroll(graph, %State{scroll: old_scroll}, %State{scroll: new_scroll})
      when old_scroll.offset_x != new_scroll.offset_x or old_scroll.offset_y != new_scroll.offset_y do
    try do
      Graph.modify(graph, :text_content, fn primitive ->
        Scenic.Primitive.put_style(primitive, :translate, {-new_scroll.offset_x, -new_scroll.offset_y})
      end)
    rescue
      _ -> graph
    end
  end

  defp update_content_scroll(graph, _old_state, _new_state), do: graph

  # Rebuild the entire content area when line count increases
  # This is needed because we can't add new primitives to existing groups
  defp rebuild_content_area(graph, %State{show_line_numbers: true, line_number_width: gutter_width} = state) do
    content_width = state.frame.size.width - gutter_width

    graph
    |> Graph.delete(:content_group)
    |> render_text_content_area(state, gutter_width, content_width)
  end

  defp rebuild_content_area(graph, %State{show_line_numbers: false} = state) do
    graph
    |> Graph.delete(:content_group)
    |> render_text_content_area(state, 0, state.frame.size.width)
  end

  # Rebuild the gutter when line count increases
  defp rebuild_gutter(graph, %State{show_line_numbers: true, line_number_width: gutter_width} = state) do
    graph
    |> Graph.delete(:gutter_group)
    |> render_line_number_gutter(state, gutter_width)
  end

  defp rebuild_gutter(graph, %State{show_line_numbers: false}), do: graph

  # Update text lines when content changes
  defp update_lines_if_changed(graph, %State{lines: old_lines}, %State{lines: new_lines} = new_state)
      when old_lines != new_lines do
    old_display_lines = wrap_lines_from(old_lines, new_state)
    new_display_lines = wrap_lines(new_state)

    old_count = length(old_display_lines)
    new_count = length(new_display_lines)

    # If line count increased, we need to rebuild the content area
    if new_count > old_count do
      rebuild_content_area(graph, new_state)
    else
      # Update existing lines
      graph = Enum.reduce(Enum.with_index(new_display_lines, 1), graph, fn {line_text, line_num}, g ->
        try do
          Graph.modify(g, {:text_line, line_num}, fn primitive ->
            Scenic.Primitive.put(primitive, line_text)
          end)
        rescue
          _ -> g
        end
      end)

      # Clear any extra old lines
      if old_count > new_count do
        Enum.reduce((new_count + 1)..old_count, graph, fn line_num, g ->
          try do
            Graph.modify(g, {:text_line, line_num}, fn primitive ->
              Scenic.Primitive.put(primitive, "")
            end)
          rescue
            _ -> g
          end
        end)
      else
        graph
      end
    end
  end

  defp update_lines_if_changed(graph, _old_state, _new_state), do: graph

  # Update line numbers when source line count changes
  # Always rebuild gutter to ensure correct line number display, especially for wrapped lines
  defp update_line_numbers_if_changed(graph, %State{lines: old_lines, show_line_numbers: true},
                                       %State{lines: new_lines, show_line_numbers: true} = new_state)
      when length(old_lines) != length(new_lines) do
    # Rebuild the gutter whenever source line count changes
    # This ensures wrapped continuation lines don't incorrectly show line numbers
    rebuild_gutter(graph, new_state)
  end

  defp update_line_numbers_if_changed(graph, _old_state, _new_state), do: graph

  # Update cursor position
  defp update_cursor_if_changed(graph, %State{cursor: old_cursor}, %State{cursor: new_cursor} = new_state)
      when old_cursor != new_cursor do
    x_offset = 10
    line_height = State.line_height(new_state)

    # Get cursor position in display line coordinates
    {display_line, display_col} = source_to_display_cursor(new_state, new_cursor)

    display_lines = wrap_lines(new_state)
    current_line = Enum.at(display_lines, display_line - 1, "")
    text_before_cursor = String.slice(current_line, 0, max(0, display_col - 1))

    cursor_x = x_offset + State.string_width(new_state, text_before_cursor)
    line_top = (display_line - 1) * line_height
    cursor_y = line_top + 4

    should_show_cursor = new_state.focused and new_state.cursor_visible

    graph
    |> Graph.modify(:cursor, fn primitive ->
      Primitives.update_opts(primitive, translate: {cursor_x, cursor_y}, hidden: !should_show_cursor)
    end)
  end

  defp update_cursor_if_changed(graph, _old_state, _new_state), do: graph

  defp update_scrollbars_if_changed(graph, %State{scroll: old_scroll}, %State{scroll: new_scroll, frame: frame}) do
    alias Widgex.Scroll.ScrollRenderer
    ScrollRenderer.update_scrollbars(graph, old_scroll, new_scroll, frame)
  end

  # ===== LINE WRAPPING HELPERS =====

  defp wrap_lines(%State{lines: lines, wrap_mode: wrap_mode} = state) do
    max_width = content_area_width(state)

    case wrap_mode do
      :word -> Enum.flat_map(lines, &wrap_line(&1, max_width, state))
      :char -> Enum.flat_map(lines, &wrap_line_by_chars(&1, max_width, state))
      :none -> lines
    end
  end

  defp wrap_lines_from(lines, %State{wrap_mode: wrap_mode} = state) do
    max_width = content_area_width(state)

    case wrap_mode do
      :word -> Enum.flat_map(lines, &wrap_line(&1, max_width, state))
      :char -> Enum.flat_map(lines, &wrap_line_by_chars(&1, max_width, state))
      :none -> lines
    end
  end

  # Calculate the available width for text content
  defp content_area_width(%State{scroll: scroll, show_line_numbers: show_ln, line_number_width: ln_width}) do
    gutter_width = if show_ln, do: ln_width, else: 0
    scroll.viewport_width - gutter_width - 20  # 20 for padding
  end

  # Build mapping from display line number to {source_line_number, is_first_of_source}
  # Returns one entry per DISPLAY line, tracking which source line it came from
  # and whether it's the first display line for that source (to show the line number)
  defp build_line_number_mapping(source_lines, %State{} = state) do
    # We need to wrap each source line individually to track display line counts
    max_width = content_area_width(state)

    {mapping, _display_idx} = Enum.reduce(Enum.with_index(source_lines, 1), {[], 1}, fn {source_line, source_num}, {acc, _display_idx} ->
      # Wrap this source line to see how many display lines it produces
      wrapped = case state.wrap_mode do
        :word -> wrap_line(source_line, max_width, state)
        :char -> wrap_line_by_chars(source_line, max_width, state)
        :none -> [source_line]
      end

      # Create mapping entries: first one shows source line number, rest are blank
      entries = Enum.with_index(wrapped, 0)
                |> Enum.map(fn {_text, idx} ->
                  {source_num, idx == 0}  # is_first_of_source is true only for idx 0
                end)

      {acc ++ entries, 0}  # display_idx not used
    end)

    mapping
  end

  # Overload for when called with just display_lines list (from update functions)
  defp build_line_number_mapping(source_lines, display_lines) when is_list(display_lines) do
    # Fallback: simple 1:1 mapping when we don't have full state
    # This is used during updates where we don't have the full state context
    total_display = length(display_lines)
    total_source = length(source_lines)

    if total_display == total_source do
      # No wrapping - simple 1:1 mapping
      Enum.map(1..max(1, total_source), fn n -> {n, true} end)
    else
      # Wrapping occurred - create entries for each display line
      # First N entries (where N = source count) show line numbers
      # Remaining entries are blank (wrapped continuations)
      Enum.with_index(1..total_display, 1)
      |> Enum.map(fn {_display_num, idx} ->
        if idx <= total_source do
          {idx, true}
        else
          {0, false}
        end
      end)
    end
  end

  # Convert source cursor position to display cursor position
  # When lines wrap, we need to find which display line the cursor is on
  # and what column within that display line
  defp source_to_display_cursor(%State{wrap_mode: :none}, {source_line, source_col}) do
    # No wrapping - simple 1:1 mapping
    {source_line, source_col}
  end

  defp source_to_display_cursor(%State{lines: lines} = state, {source_line, source_col}) do
    max_width = content_area_width(state)

    # Count how many display lines exist before the source line containing the cursor
    display_lines_before = Enum.take(lines, source_line - 1)
                           |> Enum.map(fn line -> wrap_line(line, max_width, state) end)
                           |> Enum.map(&length/1)
                           |> Enum.sum()

    # Get the source line containing the cursor and wrap it
    source_line_text = Enum.at(lines, source_line - 1, "")
    wrapped_lines = wrap_line(source_line_text, max_width, state)

    # Find which wrapped segment contains the cursor
    {display_line_offset, display_col} = find_cursor_in_wrapped_lines(wrapped_lines, source_col)

    display_line = display_lines_before + display_line_offset
    {display_line, display_col}
  end

  # Find which wrapped line segment contains the cursor and what column within it
  # Note: Word wrap consumes spaces at wrap boundaries, so we need to track that
  defp find_cursor_in_wrapped_lines(wrapped_lines, source_col) do
    # Walk through wrapped lines, tracking cumulative SOURCE character position
    # When word wrapping, a space is consumed between wrapped lines
    find_cursor_in_wrapped_lines(wrapped_lines, source_col, 1, 0, false)
  end

  defp find_cursor_in_wrapped_lines([], source_col, line_num, chars_consumed, _) do
    # Cursor is past all content - place at end of last line
    {max(1, line_num - 1), max(1, source_col - chars_consumed)}
  end

  defp find_cursor_in_wrapped_lines([line | rest], source_col, line_num, chars_consumed, had_previous_line) do
    line_length = String.length(line)

    # Account for the space that was consumed at wrap boundary
    # (when transitioning from a previous line to this one via word wrap)
    space_adjustment = if had_previous_line, do: 1, else: 0

    # Total source characters consumed after this wrapped line
    source_chars_after = chars_consumed + space_adjustment + line_length

    # Source position where this display line starts
    source_start = chars_consumed + space_adjustment

    cond do
      # Cursor is within this line
      source_col >= source_start + 1 and source_col <= source_chars_after + 1 ->
        display_col = source_col - source_start
        {line_num, display_col}

      # Cursor is after this line - continue to next
      source_col > source_chars_after ->
        find_cursor_in_wrapped_lines(rest, source_col, line_num + 1, source_chars_after, true)

      # Cursor is before this line (shouldn't happen normally)
      true ->
        {line_num, 1}
    end
  end

  # Word-based line wrapping using FontMetrics when available
  defp wrap_line(line, max_width, %State{} = state) do
    line_width = State.string_width(state, line)

    if line_width <= max_width do
      [line]
    else
      wrap_line_by_words(line, max_width, state)
    end
  end

  defp wrap_line_by_words(line, max_width, %State{} = state) do
    words = String.split(line, " ")

    words
    |> Enum.reduce({[], ""}, fn word, {wrapped_lines, current_line} ->
      test_line = if current_line == "", do: word, else: current_line <> " " <> word
      test_width = State.string_width(state, test_line)

      if test_width <= max_width do
        {wrapped_lines, test_line}
      else
        if current_line == "" do
          # Word is too long, must include it anyway (could split further if needed)
          {wrapped_lines ++ [word], ""}
        else
          {wrapped_lines ++ [current_line], word}
        end
      end
    end)
    |> then(fn {wrapped_lines, current_line} ->
      if current_line == "", do: wrapped_lines, else: wrapped_lines ++ [current_line]
    end)
  end

  # Character-based line wrapping using FontMetrics when available
  defp wrap_line_by_chars(line, max_width, %State{} = state) do
    line_width = State.string_width(state, line)

    if line_width <= max_width do
      [line]
    else
      # Use character width to estimate chunk size, then verify with actual measurement
      char_width = State.char_width(state)
      estimated_chars = max(1, trunc(max_width / char_width))

      wrap_line_by_chars_measured(line, max_width, estimated_chars, state)
    end
  end

  # Wrap line by characters, using actual string width measurement
  defp wrap_line_by_chars_measured(line, max_width, estimated_chars, state) do
    graphemes = String.graphemes(line)

    if length(graphemes) <= estimated_chars do
      [line]
    else
      # Build chunks that actually fit within max_width
      {chunks, current_chunk} = Enum.reduce(graphemes, {[], ""}, fn char, {chunks, current} ->
        test = current <> char
        if State.string_width(state, test) <= max_width do
          {chunks, test}
        else
          if current == "" do
            # Single char exceeds width, include it anyway
            {chunks ++ [char], ""}
          else
            {chunks ++ [current], char}
          end
        end
      end)

      if current_chunk == "" do
        chunks
      else
        chunks ++ [current_chunk]
      end
    end
  end
end
