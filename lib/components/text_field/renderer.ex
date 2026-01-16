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
  Scrollbars are rendered inside content_group to ensure proper z-order.
  """
  def initial_render(graph, %State{} = state) do
    graph
    |> render_background(state)
    |> render_border(state)
    |> render_gutter_and_content(state)
  end

  @doc """
  Update render - intelligently updates only what changed.
  """
  def update_render(graph, old_state, new_state) do
    # If gutter width changed, need full rebuild of gutter and content areas
    if old_state.line_number_width != new_state.line_number_width do
      rebuild_gutter_and_content(graph, new_state)
    else
      graph
      |> update_border_if_changed(old_state, new_state)
      |> update_gutter_scroll(old_state, new_state)
      |> update_content_scroll(old_state, new_state)
      |> update_lines_if_changed(old_state, new_state)
      |> update_semantic_if_changed(old_state, new_state)
      |> update_line_numbers_if_changed(old_state, new_state)
      |> update_selection_if_changed(old_state, new_state)
      |> update_search_matches_if_changed(old_state, new_state)
      |> update_cursor_if_changed(old_state, new_state)
      |> update_scrollbars_if_changed(old_state, new_state)
    end
  end

  # Rebuild both gutter and content when gutter width changes
  defp rebuild_gutter_and_content(graph, %State{show_line_numbers: true} = state) do
    graph
    |> rebuild_gutter(state)
    |> rebuild_content_area(state)
  end

  defp rebuild_gutter_and_content(graph, %State{show_line_numbers: false} = state) do
    rebuild_content_area(graph, state)
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

  defp render_gutter_and_content(graph, %State{show_line_numbers: true, line_number_width: gutter_width, lines: lines} = state) do
    content_width = state.frame.size.width - gutter_width
    IO.puts("🎨 Rendering gutter: width=#{gutter_width}, lines=#{length(lines)}, content_width=#{content_width}")

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

    # text_y_offset no longer used - single-line mode uses text_base: :middle
    text_y_offset = 0

    Primitives.group(graph, fn outer_g ->
      outer_g
      # Inner group that scrolls both directions
      |> Primitives.group(fn inner_g ->
        inner_g
        |> render_semantic_content(state)
        |> render_selection(state)
        |> render_search_matches(state)
        |> render_text_lines(state, display_lines, text_padding, line_height, text_y_offset)
        |> render_cursor(state, text_padding, line_height, text_y_offset)
      end,
        id: :text_content,
        translate: {-scroll.offset_x, -scroll.offset_y}
      )
      # Render scrollbars INSIDE content_group, after text, so they're on top
      |> render_scrollbars_in_content(state, content_width, frame_height)
    end,
      id: :content_group,
      translate: {x_offset, 0},
      scissor: {content_width, frame_height}
    )
  end

  # Render scrollbars inside content_group (positioned relative to content area)
  defp render_scrollbars_in_content(graph, %State{scroll: scroll}, content_width, frame_height) do
    scrollbar_width = 10
    scrollbar_padding = 2

    graph
    |> render_v_scrollbar_in_content(scroll, content_width, frame_height, scrollbar_width, scrollbar_padding)
    |> render_h_scrollbar_in_content(scroll, content_width, frame_height, scrollbar_width, scrollbar_padding)
  end

  defp render_v_scrollbar_in_content(graph, scroll, content_width, frame_height, scrollbar_width, scrollbar_padding) do
    if Widgex.Scroll.ScrollState.scrollable_y?(scroll) do
      # Position at right edge of content area
      track_x = content_width - scrollbar_width - scrollbar_padding
      track_height = frame_height - scrollbar_padding * 2

      # Reduce height if horizontal scrollbar exists
      track_height = if Widgex.Scroll.ScrollState.scrollable_x?(scroll) do
        track_height - scrollbar_width - scrollbar_padding
      else
        track_height
      end

      {thumb_y_ratio, thumb_height_ratio} = Widgex.Scroll.ScrollState.scrollbar_thumb(scroll, :y)
      scale = track_height / scroll.viewport_height
      thumb_height = max(thumb_height_ratio * scale, 20)
      thumb_y = thumb_y_ratio * scale

      # IO.puts("📜 V-scrollbar: track_x=#{track_x}, track_height=#{track_height}, frame_height=#{frame_height}")

      graph
      |> Primitives.rrect({scrollbar_width, track_height, 4},
        id: :scrollbar_y_track,
        fill: {80, 80, 80, 200},
        translate: {track_x, scrollbar_padding}
      )
      |> Primitives.rrect({scrollbar_width, thumb_height, 4},
        id: :scrollbar_y_thumb,
        fill: {160, 160, 160, 255},
        translate: {track_x, scrollbar_padding + thumb_y}
      )
    else
      graph
    end
  end

  defp render_h_scrollbar_in_content(graph, scroll, content_width, frame_height, scrollbar_width, scrollbar_padding) do
    if Widgex.Scroll.ScrollState.scrollable_x?(scroll) do
      # Position at bottom of content area
      track_x = scrollbar_padding
      track_y = frame_height - scrollbar_width - scrollbar_padding
      track_width = content_width - scrollbar_padding * 2

      # Reduce width if vertical scrollbar exists
      track_width = if Widgex.Scroll.ScrollState.scrollable_y?(scroll) do
        track_width - scrollbar_width - scrollbar_padding
      else
        track_width
      end

      {thumb_x_ratio, thumb_width_ratio} = Widgex.Scroll.ScrollState.scrollbar_thumb(scroll, :x)
      scale = track_width / scroll.viewport_width
      thumb_width = max(thumb_width_ratio * scale, 20)
      thumb_x = thumb_x_ratio * scale

      # IO.puts("📜 H-scrollbar: track_y=#{track_y} (frame_height=#{frame_height}), track_width=#{track_width}")

      graph
      |> Primitives.rrect({track_width, scrollbar_width, 4},
        id: :scrollbar_x_track,
        fill: {80, 80, 80, 200},
        translate: {track_x, track_y}
      )
      |> Primitives.rrect({thumb_width, scrollbar_width, 4},
        id: :scrollbar_x_thumb,
        fill: {160, 160, 160, 255},
        translate: {track_x + thumb_x, track_y}
      )
    else
      graph
    end
  end

  # Render all text lines
  # Uses explicit x-positioning for indentation because Scenic renders
  # leading spaces as zero-width
  # For single-line mode, uses text_base: :middle for perfect vertical centering
  defp render_text_lines(graph, %State{mode: mode, frame: frame} = state, display_lines, x_offset, line_height, _text_y_offset \\ 0) do
    Enum.reduce(Enum.with_index(display_lines, 1), graph, fn {line_text, line_num}, g ->
      # Expand tabs and get indent width + trimmed content
      # Scenic renders leading spaces as zero-width, so we position explicitly
      {indent_width, content} = State.expand_tabs_with_indent(state, line_text)
      line_x = x_offset + indent_width

      # For single-line mode, use text_base: :middle and center in frame
      # For multi-line, use standard baseline positioning
      # Small +2 adjustment accounts for visual centering vs typographic middle
      {y_pos, text_opts} = case mode do
        :single_line ->
          {frame.size.height / 2 + 2, [text_base: :middle]}
        _ ->
          {(line_num - 1) * line_height + line_height, []}
      end

      g
      |> Primitives.text(
        content,
        [{:translate, {line_x, y_pos}},
         {:fill, state.colors.text},
         {:font_size, state.font.size},
         {:font, state.font.name},
         {:id, {:text_line, line_num}}
         | text_opts]
      )
    end)
  end

  # Render the cursor
  # text_y_offset is used for vertical centering in single-line mode
  defp render_cursor(graph, %State{
    cursor: {line, col},
    cursor_visible: visible,
    focused: focused,
    cursor_mode: cursor_mode,
    colors: colors,
    frame: frame,
    mode: mode
  } = state, x_offset, line_height, _text_y_offset \\ 0) do
    # Get cursor position in display line coordinates
    {display_line, display_col} = source_to_display_cursor(state, {line, col})

    # Get the text before cursor to calculate accurate position
    display_lines = wrap_lines(state)
    current_line = Enum.at(display_lines, display_line - 1, "")
    text_before_cursor = String.slice(current_line, 0, max(0, display_col - 1))

    # Calculate cursor X position
    cursor_x = x_offset + State.string_width(state, text_before_cursor)

    # For single-line mode, center cursor vertically (text uses text_base: :middle)
    # For multi-line, use standard line-based positioning
    cursor_y = case mode do
      :single_line ->
        # Text is centered at frame_height/2 + 2 with text_base: :middle
        # Cursor needs no extra adjustment
        frame.size.height / 2 - line_height / 2
      _ ->
        # Standard multi-line: position at line top + small offset
        (display_line - 1) * line_height + 4
    end

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
  defp render_semantic_content(graph, %State{} = state) do
    graph
    |> Primitives.text(
      State.get_text(state),
      id: :semantic_content,
      hidden: true,
      semantic: semantic_metadata(state)
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
    # Selection highlight - steel blue with good visibility on dark backgrounds
    selection_color = {:color_rgba, {70, 130, 180, 180}}

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
      selection_width = max(1, State.string_width(state, selected_text))

      acc_graph
      |> Primitives.rect(
        {selection_width, line_height},
        fill: selection_color,
        translate: {x_offset + start_x_offset, y_position},
        id: {:selection_highlight, line_num}
      )
    end)
  end

  # Render search match highlighting
  defp render_search_matches(graph, %State{search_matches: nil}), do: graph
  defp render_search_matches(graph, %State{search_matches: []}), do: graph

  defp render_search_matches(graph, %State{search_matches: matches, search_current_index: current_idx, lines: state_lines} = state) do
    x_offset = 10
    line_height = State.line_height(state)
    # Yellow highlight for search matches, orange for current match
    match_color = {:color_rgba, {255, 255, 0, 120}}
    current_match_color = {:color_rgba, {255, 165, 0, 180}}

    # Small vertical adjustment to center highlight behind text
    # Text baseline is at (line_num * line_height), text appears above baseline
    # Highlight should cover the visual text area
    y_adjust = 4  # pixels to shift down for better centering

    # Build mapping from source line number to first display line index
    # This accounts for word wrap where one source line becomes multiple display lines
    source_to_display = build_source_to_display_map(state_lines, state)

    matches
    |> Enum.with_index()
    |> Enum.reduce(graph, fn {{line_num, col_num, match_text}, idx}, acc_graph ->
      # Get the display line index for this source line (accounting for word wrap)
      display_line_idx = Map.get(source_to_display, line_num, line_num)

      # Position highlight at correct display line position
      y_position = (display_line_idx - 1) * line_height + y_adjust

      # Get line text for x positioning
      # Use state_lines (actual lines) for consistency with search
      line_text = Enum.at(state_lines, line_num - 1, "")

      # For wrapped lines, we need to handle x position differently
      # The match might be on a wrapped portion of the line
      # Calculate which wrapped segment the match is in and its x offset within that segment
      {wrapped_y_offset, wrapped_x_offset} =
        calculate_wrapped_position(state, line_text, col_num - 1)

      # Adjust y for wrapped segments
      final_y = y_position + (wrapped_y_offset * line_height)
      final_x = x_offset + wrapped_x_offset

      match_width = max(1, State.string_width(state, match_text))

      # Use different color for current match
      color = if idx == current_idx, do: current_match_color, else: match_color

      acc_graph
      |> Primitives.rect(
        {match_width, line_height},
        fill: color,
        translate: {final_x, final_y},
        id: {:search_match, idx}
      )
    end)
  end

  # Build a map from source line number (1-indexed) to first display line index (1-indexed)
  # This accounts for word wrap where one source line might span multiple display lines
  defp build_source_to_display_map(source_lines, %State{} = state) do
    max_width = content_area_width(state)

    {map, _display_idx} =
      Enum.with_index(source_lines, 1)
      |> Enum.reduce({%{}, 1}, fn {source_line, source_num}, {acc_map, current_display_idx} ->
        # Record that this source line starts at this display line
        new_map = Map.put(acc_map, source_num, current_display_idx)

        # Count how many display lines this source line produces
        display_line_count = case state.wrap_mode do
          :word -> length(wrap_line(source_line, max_width, state))
          :char -> length(wrap_line_by_chars(source_line, max_width, state))
          :none -> 1
        end

        {new_map, current_display_idx + display_line_count}
      end)

    map
  end

  # Calculate the y-offset (in line counts) and x-offset (in pixels) for a character position
  # within a potentially wrapped line
  defp calculate_wrapped_position(%State{wrap_mode: :none} = state, line_text, char_idx) do
    # No wrapping - simple x offset calculation
    text_before = String.slice(line_text, 0, char_idx)
    {0, State.string_width(state, text_before)}
  end

  defp calculate_wrapped_position(%State{} = state, line_text, char_idx) do
    max_width = content_area_width(state)

    # Wrap the line to see how it breaks
    wrapped = case state.wrap_mode do
      :word -> wrap_line(line_text, max_width, state)
      :char -> wrap_line_by_chars(line_text, max_width, state)
      :none -> [line_text]
    end

    # Find which wrapped segment contains char_idx
    find_char_in_wrapped_segments(wrapped, char_idx, 0, state)
  end

  defp find_char_in_wrapped_segments([], _char_idx, segment_num, _state) do
    # Character beyond end of line - use last segment
    {segment_num, 0}
  end

  defp find_char_in_wrapped_segments([segment | rest], char_idx, segment_num, state) do
    segment_len = String.length(segment)

    if char_idx < segment_len do
      # Found it in this segment - calculate x offset within this segment
      text_before = String.slice(segment, 0, char_idx)
      {segment_num, State.string_width(state, text_before)}
    else
      # Not in this segment - check next one
      # Note: subtract segment length, but wrapped segments might not have clean character boundaries
      # For word wrap, there may be a space that's elided
      find_char_in_wrapped_segments(rest, char_idx - segment_len, segment_num + 1, state)
    end
  end

  # Render scrollbars inside the main group (for z-order)
  defp render_scrollbars_inner(graph, %State{scroll: scroll, frame: frame, show_line_numbers: show_ln, line_number_width: ln_width} = _state) do
    alias Widgex.Structs.Dimensions

    gutter_offset = if show_ln, do: ln_width, else: 0
    content_width = frame.size.width - gutter_offset
    {frame_height} = {frame.size.height}

    {frame_width, _} = frame.size.box
    IO.puts("📜 TextField.render_scrollbars_inner: gutter=#{gutter_offset}, content_width=#{content_width}, frame_width=#{frame_width}, frame_height=#{frame_height}")

    # Render scrollbars directly (not via ScrollRenderer) for debugging
    # Vertical scrollbar on the right edge of content area
    if Widgex.Scroll.ScrollState.scrollable_y?(scroll) do
      scrollbar_width = 12
      scrollbar_padding = 4

      # Position at right edge of FULL frame (not content area)
      track_x = frame_width - scrollbar_width - scrollbar_padding
      track_height = frame_height - scrollbar_padding * 2

      # Calculate thumb position and size
      {thumb_y_ratio, thumb_height_ratio} = Widgex.Scroll.ScrollState.scrollbar_thumb(scroll, :y)
      scale = track_height / scroll.viewport_height
      thumb_height = max(thumb_height_ratio * scale, 20)  # Minimum thumb size
      thumb_y = thumb_y_ratio * scale

      IO.puts("📜 Vertical scrollbar: track_x=#{track_x}, track_height=#{track_height}, thumb_height=#{thumb_height}")

      # DEBUG: Try hardcoded position at bottom-right corner
      # If this appears at top-left, there's a coordinate transform issue
      test_x = 500  # Should be 500px from left
      test_y = 500  # Should be 500px from top

      graph
      # Track - put at hardcoded position to debug
      |> Primitives.rrect({scrollbar_width, 200, 4},
        id: :scrollbar_y_track,
        fill: {255, 0, 0, 128},
        translate: {test_x, test_y}
      )
      # Thumb
      |> Primitives.rrect({scrollbar_width, thumb_height, 4},
        id: :scrollbar_y_thumb,
        fill: {255, 0, 0, 255},
        translate: {test_x, test_y + 10}
      )
      # Add horizontal scrollbar if needed
      |> maybe_render_horizontal_scrollbar(scroll, frame_width, frame_height, gutter_offset, scrollbar_width, scrollbar_padding)
    else
      graph
      |> maybe_render_horizontal_scrollbar(scroll, frame_width, frame_height, gutter_offset, 12, 4)
    end
  end

  defp maybe_render_horizontal_scrollbar(graph, scroll, frame_width, frame_height, gutter_offset, scrollbar_width, scrollbar_padding) do
    if Widgex.Scroll.ScrollState.scrollable_x?(scroll) do
      # Horizontal scrollbar at bottom, starting after gutter
      track_width = frame_width - gutter_offset - scrollbar_padding * 2
      # If vertical scrollbar exists, reduce width
      track_width = if Widgex.Scroll.ScrollState.scrollable_y?(scroll) do
        track_width - scrollbar_width - scrollbar_padding
      else
        track_width
      end
      track_y = frame_height - scrollbar_width - scrollbar_padding
      track_x = gutter_offset + scrollbar_padding

      # Calculate thumb
      {thumb_x_ratio, thumb_width_ratio} = Widgex.Scroll.ScrollState.scrollbar_thumb(scroll, :x)
      scale = track_width / scroll.viewport_width
      thumb_width = max(thumb_width_ratio * scale, 20)
      thumb_x = thumb_x_ratio * scale

      IO.puts("📜 Horizontal scrollbar: track_x=#{track_x}, track_y=#{track_y}, track_width=#{track_width}, thumb_width=#{thumb_width}")

      graph
      # Track
      |> Primitives.rrect({track_width, scrollbar_width, 4},
        id: :scrollbar_x_track,
        fill: {0, 0, 255, 128},  # Blue for horizontal
        translate: {track_x, track_y}
      )
      # Thumb
      |> Primitives.rrect({thumb_width, scrollbar_width, 4},
        id: :scrollbar_x_thumb,
        fill: {0, 0, 255, 255},
        translate: {track_x + thumb_x, track_y}
      )
    else
      graph
    end
  end

  # Render scrollbars using ScrollRenderer (original, kept for reference)
  defp render_scrollbars(graph, %State{scroll: scroll, frame: frame, show_line_numbers: show_ln, line_number_width: ln_width} = _state) do
    alias Widgex.Scroll.ScrollRenderer
    alias Widgex.Structs.Dimensions

    # Calculate content frame (text area only, excluding gutter)
    # IMPORTANT: Must create a proper Dimensions struct so .box is correct
    gutter_offset = if show_ln, do: ln_width, else: 0
    content_width = frame.size.width - gutter_offset
    content_frame = %{frame |
      size: Dimensions.new({content_width, frame.size.height})
    }

    IO.puts("📜 TextField.render_scrollbars: gutter_offset=#{gutter_offset}, content_width=#{content_width}, frame=#{frame.size.width}x#{frame.size.height}")

    # Render scrollbars in a group translated by gutter offset
    graph
    |> Scenic.Primitives.group(fn g ->
      ScrollRenderer.render_scrollbars(g, scroll, content_frame)
    end,
      id: :scrollbars_group,
      translate: {gutter_offset, 0}
    )
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
  # Must update both text content AND x-position due to explicit indent positioning
  defp update_lines_if_changed(graph, %State{lines: old_lines}, %State{lines: new_lines} = new_state)
      when old_lines != new_lines do
    old_display_lines = wrap_lines_from(old_lines, new_state)
    new_display_lines = wrap_lines(new_state)

    old_count = length(old_display_lines)
    new_count = length(new_display_lines)

    x_offset = 10  # text_padding
    line_height = State.line_height(new_state)
    frame_height = new_state.frame.size.height

    # If line count increased, we need to rebuild the content area
    if new_count > old_count do
      rebuild_content_area(graph, new_state)
    else
      # Update existing lines - both content AND position for indentation
      graph = Enum.reduce(Enum.with_index(new_display_lines, 1), graph, fn {line_text, line_num}, g ->
        # Get indent width and trimmed content
        {indent_width, content} = State.expand_tabs_with_indent(new_state, line_text)
        line_x = x_offset + indent_width

        # For single-line mode, use frame center (text_base: :middle is already set)
        # For multi-line, use standard baseline positioning
        # +2 adjustment matches initial render
        y_pos = case new_state.mode do
          :single_line -> frame_height / 2 + 2
          _ -> (line_num - 1) * line_height + line_height
        end

        try do
          Graph.modify(g, {:text_line, line_num}, fn primitive ->
            primitive
            |> Scenic.Primitive.put(content)
            |> Scenic.Primitive.put_style(:translate, {line_x, y_pos})
          end)
        rescue
          _ -> g
        end
      end)

      # Clear any extra old lines (reset position to base x_offset)
      if old_count > new_count do
        Enum.reduce((new_count + 1)..old_count, graph, fn line_num, g ->
          y_pos = case new_state.mode do
            :single_line -> frame_height / 2 + 2
            _ -> (line_num - 1) * line_height + line_height
          end
          try do
            Graph.modify(g, {:text_line, line_num}, fn primitive ->
              primitive
              |> Scenic.Primitive.put("")
              |> Scenic.Primitive.put_style(:translate, {x_offset, y_pos})
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

  defp update_semantic_if_changed(graph, old_state, new_state) do
    if semantic_changed?(old_state, new_state) do
      semantic = semantic_metadata(new_state)
      text = State.get_text(new_state)

      try do
        Graph.modify(graph, :semantic_content, fn primitive ->
          primitive
          |> Scenic.Primitive.put(text)
          |> Scenic.Primitive.put_style(:semantic, semantic)
        end)
      rescue
        _ -> graph
      end
    else
      graph
    end
  end

  defp semantic_changed?(old_state, new_state) do
    old_state.lines != new_state.lines or
    old_state.cursor != new_state.cursor or
    old_state.selection != new_state.selection or
    old_state.editable != new_state.editable or
    old_state.mode != new_state.mode or
    scroll_changed?(old_state.scroll, new_state.scroll)
  end

  defp scroll_changed?(nil, nil), do: false
  defp scroll_changed?(nil, _), do: true
  defp scroll_changed?(_, nil), do: true
  defp scroll_changed?(old, new) do
    old.offset_x != new.offset_x or old.offset_y != new.offset_y
  end

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

  # Update selection highlight when selection changes
  # Selection changes require rebuilding the content area since we can't
  # dynamically add/remove primitives from nested groups
  defp update_selection_if_changed(graph, %State{selection: old_sel}, %State{selection: new_sel} = new_state)
      when old_sel != new_sel do
    rebuild_content_area(graph, new_state)
  end

  defp update_selection_if_changed(graph, _old_state, _new_state), do: graph

  # Update search match highlighting when matches or current index changes
  defp update_search_matches_if_changed(graph,
      %State{search_matches: old_matches, search_current_index: old_idx},
      %State{search_matches: new_matches, search_current_index: new_idx} = new_state)
      when old_matches != new_matches or old_idx != new_idx do
    rebuild_content_area(graph, new_state)
  end

  defp update_search_matches_if_changed(graph, _old_state, _new_state), do: graph

  defp update_cursor_if_changed(graph, %State{cursor: old_cursor}, %State{cursor: new_cursor} = new_state)
      when old_cursor != new_cursor do
    x_offset = 10
    line_height = State.line_height(new_state)
    frame_height = new_state.frame.size.height

    # Get cursor position in display line coordinates
    {display_line, display_col} = source_to_display_cursor(new_state, new_cursor)

    display_lines = wrap_lines(new_state)
    current_line = Enum.at(display_lines, display_line - 1, "")
    text_before_cursor = String.slice(current_line, 0, max(0, display_col - 1))

    cursor_x = x_offset + State.string_width(new_state, text_before_cursor)

    # For single-line mode, center cursor vertically (text uses text_base: :middle)
    # For multi-line, use standard line-based positioning
    cursor_y = case new_state.mode do
      :single_line ->
        # Text is centered at frame_height/2 + 2 with text_base: :middle
        # Cursor needs no extra adjustment
        frame_height / 2 - line_height / 2
      _ ->
        # Standard multi-line: position at line top + small offset
        (display_line - 1) * line_height + 4
    end

    should_show_cursor = new_state.focused and new_state.cursor_visible

    graph
    |> Graph.modify(:cursor, fn primitive ->
      Primitives.update_opts(primitive, translate: {cursor_x, cursor_y}, hidden: !should_show_cursor)
    end)
  end

  defp update_cursor_if_changed(graph, _old_state, _new_state), do: graph

  defp update_scrollbars_if_changed(graph, %State{scroll: old_scroll} = old_state, %State{scroll: new_scroll} = new_state) do
    alias Widgex.Scroll.ScrollState

    # Check if scrollability changed (primitives may not exist)
    old_scrollable_x = ScrollState.scrollable_x?(old_scroll)
    new_scrollable_x = ScrollState.scrollable_x?(new_scroll)
    old_scrollable_y = ScrollState.scrollable_y?(old_scroll)
    new_scrollable_y = ScrollState.scrollable_y?(new_scroll)

    scrollability_changed = old_scrollable_x != new_scrollable_x or
                            old_scrollable_y != new_scrollable_y

    if scrollability_changed do
      # Scrollability changed - need to rebuild content area to create/remove scrollbar primitives
      rebuild_content_area(graph, new_state)
    else
      # Update existing scrollbar thumb positions (keeping them at correct Y position)
      update_scrollbar_thumbs(graph, old_scroll, new_scroll, new_state)
    end
  end

  defp semantic_metadata(%State{id: id, editable: editable, mode: mode, cursor: cursor, selection: selection, scroll: scroll}) do
    %{
      type: if(mode == :multi_line, do: :text_buffer, else: :text_field),
      field_id: id,
      editable: editable,
      multiline: mode == :multi_line,
      role: if(mode == :multi_line, do: :textbox, else: :textfield)
    }
    |> maybe_put(:cursor_position, cursor)
    |> maybe_put(:selection, selection_to_map(selection))
    |> maybe_put(:scroll, scroll_to_map(scroll))
  end

  defp scroll_to_map(nil), do: nil
  defp scroll_to_map(%{offset_x: ox, offset_y: oy, viewport_width: vw, viewport_height: vh, content_width: cw, content_height: ch}) do
    %{
      offset_x: ox,
      offset_y: oy,
      viewport_width: vw,
      viewport_height: vh,
      content_width: cw,
      content_height: ch
    }
  end
  defp scroll_to_map(_), do: nil

  defp selection_to_map(nil), do: nil
  defp selection_to_map({start_pos, end_pos}), do: %{start: start_pos, end: end_pos}

  defp maybe_put(metadata, _key, nil), do: metadata
  defp maybe_put(metadata, key, value), do: Map.put(metadata, key, value)

  # Update scrollbar thumb positions without moving them to wrong Y coordinate
  defp update_scrollbar_thumbs(graph, old_scroll, new_scroll, state) do
    alias Widgex.Scroll.ScrollState

    frame = state.frame
    show_ln = state.show_line_numbers
    ln_width = state.line_number_width
    scrollbar_width = 10
    scrollbar_padding = 2

    gutter_offset = if show_ln, do: ln_width, else: 0
    content_width = frame.size.width - gutter_offset
    frame_height = frame.size.height

    graph
    |> update_h_scrollbar_thumb(old_scroll, new_scroll, content_width, frame_height, scrollbar_width, scrollbar_padding)
    |> update_v_scrollbar_thumb(old_scroll, new_scroll, content_width, frame_height, scrollbar_width, scrollbar_padding)
  end

  defp update_h_scrollbar_thumb(graph, old_scroll, new_scroll, content_width, frame_height, scrollbar_width, scrollbar_padding) do
    alias Widgex.Scroll.ScrollState

    if ScrollState.scrollable_x?(new_scroll) do
      track_x = scrollbar_padding
      track_y = frame_height - scrollbar_width - scrollbar_padding
      track_width = content_width - scrollbar_padding * 2

      track_width = if ScrollState.scrollable_y?(new_scroll) do
        track_width - scrollbar_width - scrollbar_padding
      else
        track_width
      end

      {new_thumb_x_ratio, _} = ScrollState.scrollbar_thumb(new_scroll, :x)
      scale = track_width / new_scroll.viewport_width
      new_thumb_x = new_thumb_x_ratio * scale

      try do
        Graph.modify(graph, :scrollbar_x_thumb, fn primitive ->
          Scenic.Primitive.put_style(primitive, :translate, {track_x + new_thumb_x, track_y})
        end)
      rescue
        _ -> graph
      end
    else
      graph
    end
  end

  defp update_v_scrollbar_thumb(graph, old_scroll, new_scroll, content_width, frame_height, scrollbar_width, scrollbar_padding) do
    alias Widgex.Scroll.ScrollState

    if ScrollState.scrollable_y?(new_scroll) do
      track_x = content_width - scrollbar_width - scrollbar_padding
      track_height = frame_height - scrollbar_padding * 2

      track_height = if ScrollState.scrollable_x?(new_scroll) do
        track_height - scrollbar_width - scrollbar_padding
      else
        track_height
      end

      {new_thumb_y_ratio, _} = ScrollState.scrollbar_thumb(new_scroll, :y)
      scale = track_height / new_scroll.viewport_height
      new_thumb_y = new_thumb_y_ratio * scale

      try do
        Graph.modify(graph, :scrollbar_y_thumb, fn primitive ->
          Scenic.Primitive.put_style(primitive, :translate, {track_x, scrollbar_padding + new_thumb_y})
        end)
      rescue
        _ -> graph
      end
    else
      graph
    end
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
  # Note: scroll.viewport_width already excludes gutter (set from content_frame in State.new)
  # Subtract 40 for: text padding (20) + scrollbar (12) + buffer (8)
  # This must match the calculation in State.new and Reducer for consistent wrapping
  defp content_area_width(%State{scroll: scroll}) do
    scroll.viewport_width - 40
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
