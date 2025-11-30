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
    :cursor_visible,           # Boolean, for blink animation
    :cursor_timer,             # Erlang timer reference
    :cursor_mode,              # :cursor (thin line) | :block (full char) | :hidden

    # Configuration
    :mode,                     # :single_line | :multi_line
    :input_mode,               # :direct | :external
    :show_line_numbers,        # Boolean
    :line_number_width,        # Pixels (default 40)
    :font,                     # %{name: atom, size: int, metrics: FontMetrics | nil}
    :colors,                   # %{text:, background:, cursor:, line_numbers:, border:, focused_border:}

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
    :scrollbar_width           # Pixels
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
    font = Map.get(data, :font) || default_font()
    lines = parse_initial_text(data)
    wrap_mode = Map.get(data, :wrap_mode, :word)
    show_line_numbers = Map.get(data, :show_line_numbers, false)
    line_number_width = Map.get(data, :line_number_width, 40)

    # Calculate the content frame (excluding line numbers if shown)
    content_frame = if show_line_numbers do
      %{frame |
        size: %{frame.size | width: frame.size.width - line_number_width}
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

    %__MODULE__{
      frame: frame,
      lines: lines,
      cursor: Map.get(data, :initial_cursor, {1, 1}),
      id: Map.get(data, :id),

      # Display
      focused: Map.get(data, :focused, false),
      cursor_visible: true,
      cursor_timer: nil,
      cursor_mode: Map.get(data, :cursor_mode, :cursor),

      # Configuration
      mode: Map.get(data, :mode, :multi_line),
      input_mode: Map.get(data, :input_mode, :direct),
      show_line_numbers: Map.get(data, :show_line_numbers, false),
      line_number_width: Map.get(data, :line_number_width, 40),
      font: font,
      colors: Map.get(data, :colors) || default_colors(),

      # Interaction
      editable: Map.get(data, :editable, true),
      selectable: Map.get(data, :selectable, true),

      # Text Wrapping & Scrolling
      wrap_mode: wrap_mode,
      scroll: init_scroll(content_frame,
        direction: scroll_direction,
        content_height: content_height,
        content_width: content_width
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
      scrollbar_width: Map.get(data, :scrollbar_width, 12)
    }
  end

  defp calculate_content_height(lines, font) do
    line_height = font.size
    length(lines) * line_height
  end

  defp calculate_content_width(lines, font, frame, wrap_mode) do
    case wrap_mode do
      :none ->
        # Find the longest line
        char_width = trunc(font.size * 0.6)  # Monospace approximation
        max_line_length = lines |> Enum.map(&String.length/1) |> Enum.max(fn -> 0 end)
        max_line_length * char_width
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
    %{name: :roboto_mono, size: 20, metrics: nil}
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
  """
  def string_width(%__MODULE__{font: %{metrics: %FontMetrics{} = metrics, size: size}}, string) do
    FontMetrics.width(string, size, metrics)
  end
  def string_width(%__MODULE__{font: %{size: size}}, string) do
    # Fallback to monospace approximation
    String.length(string) * trunc(size * 0.6)
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
end
