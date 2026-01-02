defmodule ScenicWidgets.TextField.State do
  @moduledoc """
  State management for the TextField component.

  Supports both single-line and multi-line text editing with configurable
  wrapping, scrolling, line numbers, and interaction modes.
  """

  use Widgex.Scrollable

  defstruct [
    # Core
    :frame,                    # Widgex.Frame for positioning/sizing
    :lines,                    # List of strings: ["line 1", "line 2", ...]
    :cursor,                   # {line, col} tuple (1-indexed)
    :id,                       # Component ID (for events)

    # Display
    :focused,                  # Boolean, whether component has focus
    :focus_time,               # System.monotonic_time when focus was gained (for debouncing)
    :cursor_visible,           # Boolean, for blink animation
    :cursor_timer,             # Erlang timer reference
    :cursor_mode,              # :cursor (thin line) | :block (full char) | :hidden

    # Configuration
    :mode,                     # :single_line | :multi_line

    # Input Mode - CRITICAL for correct input routing!
    # :direct        - TextField requests and handles all keyboard input directly.
    #                  ⚠️ Will intercept global shortcuts! Use only when TextField
    #                  is the sole input handler (forms, simple editors).
    # :external      - TextField does NOT handle input. Parent app routes input
    #                  through its own system (Fluxus/Redux) and updates buffer.
    #                  Use for apps with global shortcuts (Flamelex, Vim-mode).
    # :buffer_backed - TextField handles input but syncs state with Buffer.Process.
    #                  Use when you want direct input but external state management.
    :input_mode,
    :show_line_numbers,        # Boolean
    :line_number_width,        # Pixels (default 40)
    :tab_width,                # Number of spaces per tab (default 4)
    :font,                     # %{name: atom, size: int, metrics: FontMetrics | nil}
    :colors,                   # %{text:, background:, cursor:, line_numbers:, border:, focused_border:}

    # Buffer-backed mode (when input_mode == :buffer_backed)
    :buffer_controller,        # PID of Buffer.Process (for buffer_backed mode)
    :buffer_topic,             # PubSub topic for buffer updates (e.g., {:buffers, uuid})

    # Interaction
    :editable,                 # Boolean (allow editing)
    :selectable,               # Boolean (allow text selection)

    # Text Wrapping & Scrolling
    :wrap_mode,                # :none | :word | :char
    :scroll,                   # Widgex.Scroll.ScrollState (replaces manual scroll offsets)
    :height_mode,              # :auto | {:fixed_lines, n} | {:fixed_pixels, n}
    :max_visible_lines,        # Calculated from frame height and height_mode
    :viewport_buffer_lines,    # Number of lines to render outside viewport (default 5)

    # Legacy scroll fields (deprecated - use :scroll instead)
    :scroll_mode,              # :none | :vertical | :horizontal | :both (for backwards compat)
    :vertical_scroll_offset,   # Vertical scroll in pixels (for backwards compat)
    :horizontal_scroll_offset, # Horizontal scroll in pixels (for backwards compat)

    # Advanced (future)
    :selection,                # {start, end} for text selection
    :max_lines,                # Limit lines (nil = unlimited)
    :cursor_blink_rate,        # Milliseconds
    :show_scrollbars,          # Boolean
    :scrollbar_width,          # Pixels

    # Scrollbar drag state
    :scrollbar_drag,           # Which scrollbar is being dragged: :x | :y | nil
    :scrollbar_drag_start,     # {x, y} mouse position when drag started
    :scrollbar_drag_offset,    # Starting scroll offset when drag started

    # Search state
    :search_query,             # Current search string (nil = not searching)
    :search_matches,           # List of {line, col, match_text} tuples
    :search_current_index,     # Index into search_matches (0-based)

    # Undo/Redo state
    :undo_stack,               # List of {lines, cursor} snapshots (most recent first)
    :redo_stack,               # List of {lines, cursor} snapshots (most recent first)
    :undo_max_size             # Maximum undo stack size (default 100)
  ]

  @type t :: %__MODULE__{}

  @doc """
  Create new state from Frame or config map.

  ## Examples

      # Minimal - just a frame
      State.new(%{frame: frame})

      # With configuration
      State.new(%{
        frame: frame,
        initial_text: "Hello\\nWorld",
        mode: :multi_line,
        show_line_numbers: true
      })
  """
  def new(%{frame: %Widgex.Frame{} = frame} = data) do
    alias Widgex.Structs.Dimensions

    font = Map.get(data, :font) || default_font()
    lines = parse_initial_text(data)
    wrap_mode = Map.get(data, :wrap_mode, :word)
    show_line_numbers = Map.get(data, :show_line_numbers, false)

    # Calculate dynamic gutter width based on line count
    line_number_width = if show_line_numbers do
      line_count = length(lines)
      digit_count = if line_count == 0, do: 1, else: trunc(:math.log10(max(1, line_count))) + 1
      digits_to_show = max(2, digit_count)
      # Use font size approximation since we don't have full state yet
      digit_width = trunc(font.size * 0.6)
      width = trunc(digits_to_show * digit_width) + 20
      IO.puts("📐 Gutter: #{line_count} lines, #{digit_count} digits, digit_width=#{digit_width}, total_width=#{width}")
      width
    else
      0
    end

    # Calculate the content frame (excluding line numbers if shown)
    # IMPORTANT: Must create a proper Dimensions struct so .box is correct
    content_frame = if show_line_numbers do
      content_width = frame.size.width - line_number_width
      %{frame |
        size: Dimensions.new({content_width, frame.size.height})
      }
    else
      frame
    end

    # Determine scroll direction based on wrap mode:
    # - :word or :char wrap → vertical only (content wraps horizontally)
    # - :none → both directions (no wrapping)
    scroll_direction = case wrap_mode do
      :none -> :both
      _ -> :vertical  # :word or :char
    end

    # Calculate initial content size
    content_height = calculate_content_height(lines, font)
    content_width = calculate_content_width(lines, font, content_frame, wrap_mode)

    # Debug: show scroll initialization values
    viewport_w = content_frame.size.width
    viewport_h = content_frame.size.height
    max_scroll_x = max(0, content_width - viewport_w)
    IO.puts("🔧 ScrollInit: viewport=#{viewport_w}x#{viewport_h}, content=#{content_width}x#{content_height}, max_scroll_x=#{max_scroll_x}")

    %__MODULE__{
      frame: frame,
      lines: lines,
      cursor: Map.get(data, :initial_cursor, {1, 1}),
      id: Map.get(data, :id),

      # Display
      focused: Map.get(data, :focused, false),
      focus_time: if(Map.get(data, :focused, false), do: System.monotonic_time(:millisecond), else: nil),
      cursor_visible: true,
      cursor_timer: nil,
      cursor_mode: Map.get(data, :cursor_mode, :cursor),

      # Configuration
      mode: Map.get(data, :mode, :multi_line),
      input_mode: Map.get(data, :input_mode, :direct),
      show_line_numbers: show_line_numbers,
      line_number_width: line_number_width,
      tab_width: Map.get(data, :tab_width, 4),
      font: font,
      colors: Map.get(data, :colors) || default_colors(),

      # Buffer-backed mode
      buffer_controller: Map.get(data, :buffer_controller),
      buffer_topic: Map.get(data, :buffer_topic),

      # Interaction
      editable: Map.get(data, :editable, true),
      selectable: Map.get(data, :selectable, true),

      # Text Wrapping & Scrolling
      wrap_mode: wrap_mode,
      scroll: init_scroll(content_frame,
        direction: scroll_direction,
        content_height: content_height,
        content_width: content_width,
        initially_visible: Map.get(data, :show_scrollbars, true)
      ),
      height_mode: Map.get(data, :height_mode, :auto),
      max_visible_lines: calculate_max_lines(frame, font),
      viewport_buffer_lines: Map.get(data, :viewport_buffer_lines, 5),

      # Legacy fields (for backwards compatibility during transition)
      scroll_mode: Map.get(data, :scroll_mode, :both),
      vertical_scroll_offset: 0,
      horizontal_scroll_offset: 0,

      # Advanced
      selection: nil,
      max_lines: Map.get(data, :max_lines),
      cursor_blink_rate: Map.get(data, :cursor_blink_rate, 500),
      show_scrollbars: Map.get(data, :show_scrollbars, true),
      scrollbar_width: Map.get(data, :scrollbar_width, 12),

      # Scrollbar drag state
      scrollbar_drag: nil,
      scrollbar_drag_start: nil,
      scrollbar_drag_offset: nil,

      # Search state
      search_query: nil,
      search_matches: [],
      search_current_index: 0,

      # Undo/Redo state
      undo_stack: [],
      redo_stack: [],
      undo_max_size: Map.get(data, :undo_max_size, 100)
    }
  end

  defp calculate_content_height(lines, font) do
    line_height = font.size
    # Add half line height of bottom padding so last line isn't jammed against frame edge
    bottom_padding = div(line_height, 2)
    length(lines) * line_height + bottom_padding
  end

  defp calculate_content_width(lines, font, frame, wrap_mode) do
    case wrap_mode do
      :none ->
        # Measure actual longest line using FontMetrics if available
        {max_line_width, longest_line_num, longest_line_chars} = lines
          |> Enum.with_index(1)
          |> Enum.map(fn {line, idx} ->
            width = case font do
              %{metrics: %FontMetrics{} = metrics, size: size} ->
                FontMetrics.width(line, size, metrics)
              %{size: size} ->
                # Fallback to monospace approximation
                String.length(line) * trunc(size * 0.6)
            end
            {width, idx, String.length(line)}
          end)
          |> Enum.max_by(fn {w, _, _} -> w end, fn -> {0, 0, 0} end)

        content_w = max(frame.size.width, max_line_width + 40)

        # Get the actual line content for debug
        longest_line_text = Enum.at(lines, longest_line_num - 1, "") |> String.slice(0, 60)
        IO.puts("📏 Initial content_width: line #{longest_line_num} (#{longest_line_chars} chars)=#{max_line_width}px, frame=#{frame.size.width}, content_w=#{content_w}")
        IO.puts("   └─ \"#{longest_line_text}...\" ")

        content_w
      _ ->
        # Wrapped content fits within frame
        frame.size.width
    end
  end

  defp parse_initial_text(%{initial_text: text}) when is_bitstring(text) do
    String.split(text, "\n")
  end
  defp parse_initial_text(_) do
    # Default to empty
    [""]
  end

  defp default_font do
    %{name: :ibm_plex_mono, size: 20, metrics: nil}
  end

  defp default_colors do
    %{
      text: :white,
      background: {30, 30, 30},
      cursor: :white,
      line_numbers: {100, 100, 100},
      border: {60, 60, 60},
      focused_border: {100, 150, 200}
    }
  end

  defp calculate_max_lines(frame, font) do
    line_height = font.size
    trunc(frame.size.height / line_height)
  end

  # ===== QUERY FUNCTIONS (PURE) =====

  @doc """
  Check if point is inside TextField bounds.
  Coordinates are in component-local space (Scenic transforms them).
  """
  def point_inside?(%__MODULE__{frame: frame}, {x, y}) do
    # When component is added with translate, Scenic transforms input coords to local space
    # So we check against (0,0) origin, not frame.pin
    x >= 0 and x <= frame.size.width and
    y >= 0 and y <= frame.size.height
  end

  @doc """
  Get full text as single string with newlines.
  """
  def get_text(%__MODULE__{lines: lines}) do
    Enum.join(lines, "\n")
  end

  @doc """
  Get cursor position as {line, col} tuple (1-indexed).
  """
  def get_cursor(%__MODULE__{cursor: cursor}), do: cursor

  @doc """
  Get line at index (1-indexed). Returns empty string if out of bounds.
  """
  def get_line(%__MODULE__{lines: lines}, line_num) do
    Enum.at(lines, line_num - 1, "")
  end

  @doc """
  Count total lines in the text.
  """
  def line_count(%__MODULE__{lines: lines}), do: length(lines)

  @doc """
  Get the X offset where text starts (accounting for line numbers).
  """
  def text_x_offset(%__MODULE__{show_line_numbers: false}), do: 10
  def text_x_offset(%__MODULE__{show_line_numbers: true, line_number_width: width}), do: width + 10

  @doc """
  Calculate the required gutter width for the current number of lines.
  Returns width in pixels that fits the largest line number plus padding.
  """
  def calculate_gutter_width(%__MODULE__{show_line_numbers: false}), do: 0
  def calculate_gutter_width(%__MODULE__{show_line_numbers: true, lines: lines} = state) do
    line_count = length(lines)
    digit_count = if line_count == 0, do: 1, else: trunc(:math.log10(max(1, line_count))) + 1
    # Minimum 2 digits, plus padding on each side
    digits_to_show = max(2, digit_count)
    digit_width = char_width(state, "0")
    # Width = digits + padding (10px on left, 10px on right)
    trunc(digits_to_show * digit_width) + 20
  end

  @doc """
  Update the gutter width if needed based on line count.
  Returns updated state if width changed, original state otherwise.
  """
  def maybe_update_gutter_width(%__MODULE__{show_line_numbers: false} = state), do: state
  def maybe_update_gutter_width(%__MODULE__{show_line_numbers: true} = state) do
    required_width = calculate_gutter_width(state)
    if required_width != state.line_number_width do
      %{state | line_number_width: required_width}
    else
      state
    end
  end

  @doc """
  Calculate character width using FontMetrics if available, otherwise use approximation.
  """
  def char_width(%__MODULE__{font: %{metrics: %FontMetrics{} = metrics, size: size}}, char \\ "W") do
    FontMetrics.width(char, size, metrics)
  end
  def char_width(%__MODULE__{font: %{size: size}}, _char) do
    # Fallback to monospace approximation if FontMetrics not available
    trunc(size * 0.6)
  end

  @doc """
  Calculate the width of a string using FontMetrics if available.
  Handles tab characters by expanding them based on tab_width.
  """
  def string_width(%__MODULE__{} = state, string) do
    # First expand tabs, then measure
    expanded = expand_tabs(state, string)
    string_width_raw(state, expanded)
  end

  # Raw string width without tab expansion (for internal use after tabs are expanded)
  defp string_width_raw(%__MODULE__{font: %{metrics: %FontMetrics{} = metrics, size: size}}, string) do
    FontMetrics.width(string, size, metrics)
  end
  defp string_width_raw(%__MODULE__{font: %{size: size}}, string) do
    # Fallback to monospace approximation
    String.length(string) * trunc(size * 0.6)
  end

  @doc """
  Expand tab characters to spaces based on tab_width setting.
  Uses proper tab stops (columns that are multiples of tab_width).
  """
  def expand_tabs(%__MODULE__{tab_width: tab_width}, string) when is_integer(tab_width) and tab_width > 0 do
    expand_tabs_at_column(string, 0, tab_width, [])
  end
  # Fallback if tab_width is nil or invalid - use default of 4
  def expand_tabs(%__MODULE__{}, string) do
    expand_tabs_at_column(string, 0, 4, [])
  end

  defp expand_tabs_at_column("", _col, _tab_width, acc) do
    acc |> Enum.reverse() |> IO.iodata_to_binary()
  end
  defp expand_tabs_at_column(<<"\t", rest::binary>>, col, tab_width, acc) do
    # Calculate spaces to next tab stop
    spaces_needed = tab_width - rem(col, tab_width)
    # Use regular spaces - the renderer will handle positioning
    spaces = String.duplicate(" ", spaces_needed)
    expand_tabs_at_column(rest, col + spaces_needed, tab_width, [spaces | acc])
  end
  defp expand_tabs_at_column(<<char::utf8, rest::binary>>, col, tab_width, acc) do
    expand_tabs_at_column(rest, col + 1, tab_width, [<<char::utf8>> | acc])
  end

  @doc """
  Expand tabs and return {leading_space_count, content} tuple.
  This is used by the renderer to position text with explicit x-offset
  since Scenic renders leading spaces as zero-width.
  """
  def expand_tabs_with_indent(%__MODULE__{} = state, string) do
    expanded = expand_tabs(state, string)
    # Count leading spaces and split
    {leading, content} = split_leading_spaces(expanded)
    indent_width = String.length(leading) * char_width(state)
    {indent_width, content}
  end

  defp split_leading_spaces(string) do
    case Regex.run(~r/^(\s*)(.*)$/s, string) do
      [_, leading, content] -> {leading, content}
      _ -> {"", string}
    end
  end

  @doc """
  Calculate line height from font size and metrics.
  """
  def line_height(%__MODULE__{font: %{size: size}}) do
    # Use font size as line height
    # Could be enhanced with FontMetrics.ascent + descent if needed
    size
  end

  @doc """
  Convert a click position (x, y) relative to the component frame to cursor position (line, col).
  Accounts for scroll offset, gutter, and text padding.
  Returns {line, col} tuple (1-indexed).
  """
  def click_to_cursor(%__MODULE__{scroll: scroll, lines: lines} = state, {click_x, click_y}) do
    line_height = line_height(state)
    text_padding = 10  # Same as in renderer
    gutter_width = if state.show_line_numbers, do: state.line_number_width, else: 0

    # Convert click to content coordinates (accounting for scroll and gutter)
    content_x = click_x - gutter_width - text_padding + scroll.offset_x
    content_y = click_y + scroll.offset_y

    # Calculate line number from Y coordinate
    line = max(1, min(length(lines), div(trunc(content_y), line_height) + 1))

    # Get the text of the clicked line
    line_text = Enum.at(lines, line - 1, "")

    # Calculate column from X coordinate using FontMetrics
    col = x_to_column(state, line_text, content_x)

    {line, col}
  end

  # Convert an X coordinate to a column position within a line of text
  # Uses binary search-like approach for efficiency with FontMetrics
  defp x_to_column(state, line_text, x) when x <= 0, do: 1
  defp x_to_column(state, "", _x), do: 1
  defp x_to_column(state, line_text, x) do
    # Walk through characters and find where the click falls
    chars = String.graphemes(line_text)
    find_column(state, chars, x, 0, 1)
  end

  defp find_column(_state, [], _x, _current_x, col), do: col
  defp find_column(state, [char | rest], x, current_x, col) do
    char_w = string_width(state, char)
    next_x = current_x + char_w

    # Click is within this character - check if closer to left or right edge
    if x < next_x do
      mid = current_x + char_w / 2
      if x < mid, do: col, else: col + 1
    else
      find_column(state, rest, x, next_x, col + 1)
    end
  end

  @doc """
  Get the word at or near the cursor position.
  Returns the word as a string, or nil if cursor is not on a word.
  """
  def word_at_cursor(%__MODULE__{lines: lines, cursor: {line_num, col}}) do
    line = Enum.at(lines, line_num - 1, "")
    extract_word_at(line, col - 1)  # Convert to 0-indexed
  end

  # Extract word at a given 0-indexed position in a string
  defp extract_word_at("", _pos), do: nil
  defp extract_word_at(line, pos) do
    graphemes = String.graphemes(line)
    pos = max(0, min(pos, length(graphemes) - 1))

    # Check if position is on a word character
    char_at_pos = Enum.at(graphemes, pos, "")
    unless word_char?(char_at_pos) do
      # Try one position to the left (cursor might be after word)
      if pos > 0 do
        char_before = Enum.at(graphemes, pos - 1, "")
        if word_char?(char_before), do: extract_word_at(line, pos - 1), else: nil
      else
        nil
      end
    else
      # Find word boundaries
      start_pos = find_word_start(graphemes, pos)
      end_pos = find_word_end(graphemes, pos)
      graphemes |> Enum.slice(start_pos..end_pos) |> Enum.join()
    end
  end

  defp find_word_start(graphemes, pos) when pos <= 0, do: 0
  defp find_word_start(graphemes, pos) do
    char = Enum.at(graphemes, pos - 1, "")
    if word_char?(char), do: find_word_start(graphemes, pos - 1), else: pos
  end

  defp find_word_end(graphemes, pos) when pos >= length(graphemes) - 1, do: length(graphemes) - 1
  defp find_word_end(graphemes, pos) do
    char = Enum.at(graphemes, pos + 1, "")
    if word_char?(char), do: find_word_end(graphemes, pos + 1), else: pos
  end

  defp word_char?(char), do: Regex.match?(~r/[\w]/, char)

  @doc """
  Get font ascent using FontMetrics if available.
  """
  def font_ascent(%__MODULE__{font: %{metrics: %FontMetrics{} = metrics, size: size}}) do
    FontMetrics.ascent(size, metrics)
  end
  def font_ascent(%__MODULE__{font: %{size: size}}) do
    # Approximation: ~80% of font size
    trunc(size * 0.8)
  end

  @doc """
  Calculate which lines should be rendered based on viewport and scroll position.
  Returns {render_start, render_end} tuple (1-indexed, inclusive).
  """
  def visible_line_range(%__MODULE__{
    lines: lines,
    frame: frame,
    vertical_scroll_offset: scroll_y,
    viewport_buffer_lines: buffer_lines
  } = state) do
    line_height = line_height(state)
    viewport_height = frame.size.height
    total_lines = length(lines)

    # Calculate visible range
    visible_start = max(1, div(-scroll_y, line_height) + 1)
    visible_end = min(total_lines, div((-scroll_y + viewport_height), line_height) + 2)

    # Add buffer for smooth scrolling
    render_start = max(1, visible_start - buffer_lines)
    render_end = min(total_lines, visible_end + buffer_lines)

    {render_start, render_end}
  end

  @doc """
  Check if a line number should be rendered based on viewport.
  """
  def should_render_line?(%__MODULE__{} = state, line_num) do
    {render_start, render_end} = visible_line_range(state)
    line_num >= render_start and line_num <= render_end
  end

  @doc """
  Ensure the cursor is visible within the viewport.
  Automatically adjusts scroll offsets if the cursor is outside the visible area.
  Returns updated state with adjusted scroll offsets.
  """
  def ensure_cursor_visible(%__MODULE__{
    cursor: {line, col},
    frame: frame,
    vertical_scroll_offset: scroll_y,
    horizontal_scroll_offset: scroll_x
  } = state) do
    line_height = line_height(state)
    viewport_height = frame.size.height
    viewport_width = frame.size.width

    # Calculate cursor pixel position
    cursor_y = (line - 1) * line_height

    # Get text before cursor for horizontal position
    current_line = get_line(state, line)
    text_before_cursor = String.slice(current_line, 0, col - 1)
    cursor_x = string_width(state, text_before_cursor)

    # Check vertical scrolling
    new_scroll_y = cond do
      # Cursor is above viewport - scroll up
      cursor_y + scroll_y < 0 ->
        -cursor_y

      # Cursor is below viewport - scroll down
      cursor_y + scroll_y > viewport_height - line_height ->
        -(cursor_y - viewport_height + line_height)

      # Cursor is visible vertically
      true ->
        scroll_y
    end

    # Check horizontal scrolling
    text_offset = text_x_offset(state)
    new_scroll_x = cond do
      # Cursor is left of viewport - scroll left
      cursor_x + scroll_x < 0 ->
        -cursor_x

      # Cursor is right of viewport - scroll right
      cursor_x + scroll_x + text_offset > viewport_width - 10 ->
        -(cursor_x - viewport_width + text_offset + 10)

      # Cursor is visible horizontally
      true ->
        scroll_x
    end

    %{state | vertical_scroll_offset: new_scroll_y, horizontal_scroll_offset: new_scroll_x}
  end

  @doc """
  Scroll the view by a delta amount.
  Positive values scroll down/right, negative values scroll up/left.
  """
  def scroll(%__MODULE__{
    vertical_scroll_offset: scroll_y,
    horizontal_scroll_offset: scroll_x
  } = state, {delta_x, delta_y}) do
    %{state |
      vertical_scroll_offset: scroll_y + delta_y,
      horizontal_scroll_offset: scroll_x + delta_x
    }
  end

  @doc """
  Scroll vertically by a number of lines.
  Positive values scroll down, negative values scroll up.
  """
  def scroll_lines(%__MODULE__{} = state, line_count) do
    line_height = line_height(state)
    delta_y = line_count * line_height
    scroll(state, {0, delta_y})
  end

  @doc """
  Scroll horizontally by a number of characters.
  Positive values scroll right, negative values scroll left.
  """
  def scroll_chars(%__MODULE__{} = state, char_count) do
    char_width = char_width(state)
    delta_x = char_count * char_width
    scroll(state, {delta_x, 0})
  end

  # ===== SCROLLBAR HIT TESTING =====

  @scrollbar_width 10
  @scrollbar_padding 2

  @doc """
  Check if a point is on a scrollbar thumb.
  Returns :x, :y, or nil.
  Coordinates are in component-local space.
  """
  def scrollbar_hit_test(%__MODULE__{} = state, {x, y}) do
    alias Widgex.Scroll.ScrollState

    scroll = state.scroll
    frame = state.frame
    gutter_offset = if state.show_line_numbers, do: state.line_number_width, else: 0
    content_width = frame.size.width - gutter_offset
    frame_height = frame.size.height

    # Check horizontal scrollbar first (it's at the bottom)
    if ScrollState.scrollable_x?(scroll) do
      h_hit = check_h_scrollbar_hit(state, {x, y}, gutter_offset, content_width, frame_height)
      if h_hit, do: h_hit, else: check_v_scrollbar_hit(state, {x, y}, gutter_offset, content_width, frame_height)
    else
      check_v_scrollbar_hit(state, {x, y}, gutter_offset, content_width, frame_height)
    end
  end

  defp check_h_scrollbar_hit(state, {x, y}, gutter_offset, content_width, frame_height) do
    alias Widgex.Scroll.ScrollState

    scroll = state.scroll
    track_x = gutter_offset + @scrollbar_padding
    track_y = frame_height - @scrollbar_width - @scrollbar_padding
    track_width = content_width - @scrollbar_padding * 2

    # Account for vertical scrollbar
    track_width = if ScrollState.scrollable_y?(scroll) do
      track_width - @scrollbar_width - @scrollbar_padding
    else
      track_width
    end

    {thumb_x_ratio, thumb_width_ratio} = ScrollState.scrollbar_thumb(scroll, :x)
    scale = track_width / scroll.viewport_width
    thumb_width = max(thumb_width_ratio * scale, 20)
    thumb_x = track_x + thumb_x_ratio * scale

    # Check if click is on thumb
    if x >= thumb_x and x <= thumb_x + thumb_width and
       y >= track_y and y <= track_y + @scrollbar_width do
      :x
    else
      nil
    end
  end

  defp check_v_scrollbar_hit(state, {x, y}, gutter_offset, content_width, frame_height) do
    alias Widgex.Scroll.ScrollState

    scroll = state.scroll

    if ScrollState.scrollable_y?(scroll) do
      track_x = gutter_offset + content_width - @scrollbar_width - @scrollbar_padding
      track_y = @scrollbar_padding
      track_height = frame_height - @scrollbar_padding * 2

      # Account for horizontal scrollbar
      track_height = if ScrollState.scrollable_x?(scroll) do
        track_height - @scrollbar_width - @scrollbar_padding
      else
        track_height
      end

      {thumb_y_ratio, thumb_height_ratio} = ScrollState.scrollbar_thumb(scroll, :y)
      scale = track_height / scroll.viewport_height
      thumb_height = max(thumb_height_ratio * scale, 20)
      thumb_y = track_y + thumb_y_ratio * scale

      # Check if click is on thumb
      if x >= track_x and x <= track_x + @scrollbar_width and
         y >= thumb_y and y <= thumb_y + thumb_height do
        :y
      else
        nil
      end
    else
      nil
    end
  end

  @doc """
  Get scrollbar track dimensions for drag calculations.
  Returns {track_start, track_length, content_size, viewport_size}.
  """
  def scrollbar_track_info(%__MODULE__{} = state, :x) do
    alias Widgex.Scroll.ScrollState

    scroll = state.scroll
    gutter_offset = if state.show_line_numbers, do: state.line_number_width, else: 0
    content_width = state.frame.size.width - gutter_offset
    track_width = content_width - @scrollbar_padding * 2

    track_width = if ScrollState.scrollable_y?(scroll) do
      track_width - @scrollbar_width - @scrollbar_padding
    else
      track_width
    end

    {gutter_offset + @scrollbar_padding, track_width, scroll.content_width, scroll.viewport_width}
  end

  def scrollbar_track_info(%__MODULE__{} = state, :y) do
    alias Widgex.Scroll.ScrollState

    scroll = state.scroll
    frame_height = state.frame.size.height
    track_height = frame_height - @scrollbar_padding * 2

    track_height = if ScrollState.scrollable_x?(scroll) do
      track_height - @scrollbar_width - @scrollbar_padding
    else
      track_height
    end

    {@scrollbar_padding, track_height, scroll.content_height, scroll.viewport_height}
  end

  # ===========================================================================
  # Undo/Redo Operations
  # ===========================================================================

  @doc """
  Push current state onto undo stack before making a change.
  Call this BEFORE modifying lines/cursor, not after.
  Clears the redo stack (new changes invalidate redo history).
  """
  def push_undo(%__MODULE__{lines: lines, cursor: cursor, undo_stack: stack, undo_max_size: max_size} = state) do
    snapshot = {lines, cursor}
    new_stack = [snapshot | stack] |> Enum.take(max_size)
    %{state | undo_stack: new_stack, redo_stack: []}
  end

  @doc """
  Undo the last change. Returns {:ok, new_state} or {:noop, state} if nothing to undo.
  """
  def undo(%__MODULE__{undo_stack: []} = state), do: {:noop, state}
  def undo(%__MODULE__{undo_stack: [{prev_lines, prev_cursor} | rest], lines: curr_lines, cursor: curr_cursor, redo_stack: redo} = state) do
    # Push current state onto redo stack before restoring
    redo_snapshot = {curr_lines, curr_cursor}
    new_state = %{state |
      lines: prev_lines,
      cursor: prev_cursor,
      undo_stack: rest,
      redo_stack: [redo_snapshot | redo]
    }
    {:ok, ensure_cursor_visible(new_state)}
  end

  @doc """
  Redo the last undone change. Returns {:ok, new_state} or {:noop, state} if nothing to redo.
  """
  def redo(%__MODULE__{redo_stack: []} = state), do: {:noop, state}
  def redo(%__MODULE__{redo_stack: [{next_lines, next_cursor} | rest], lines: curr_lines, cursor: curr_cursor, undo_stack: undo} = state) do
    # Push current state onto undo stack before restoring
    undo_snapshot = {curr_lines, curr_cursor}
    new_state = %{state |
      lines: next_lines,
      cursor: next_cursor,
      redo_stack: rest,
      undo_stack: [undo_snapshot | undo]
    }
    {:ok, ensure_cursor_visible(new_state)}
  end

  @doc """
  Check if undo is available.
  """
  def can_undo?(%__MODULE__{undo_stack: stack}), do: stack != []

  @doc """
  Check if redo is available.
  """
  def can_redo?(%__MODULE__{redo_stack: stack}), do: stack != []
end
