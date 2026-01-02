defmodule ScenicWidgets.SearchBar.State do
  @moduledoc """
  State struct for the SearchBar component.

  The SearchBar provides a text input for search queries with:
  - Search text input field
  - Previous/Next navigation buttons
  - Match count display (e.g., "3 of 10")
  - Close button

  ## Events Emitted

  - `{:search_query_changed, id, query}` - when user types in search field
  - `{:search_next, id}` - when clicking next or pressing Enter
  - `{:search_prev, id}` - when clicking previous or pressing Shift+Enter
  - `{:search_close, id}` - when clicking close or pressing Escape
  """

  alias Widgex.Frame

  defstruct [
    :id,                    # Component ID
    :frame,                 # Widgex.Frame for positioning
    :query,                 # Current search query string
    :current_match,         # Current match index (1-based for display)
    :total_matches,         # Total number of matches
    :focused,               # Whether the search input is focused
    :cursor_pos,            # Cursor position in query string
    :font,                  # Font settings
    :theme                  # Color theme
  ]

  @type t :: %__MODULE__{
    id: atom(),
    frame: Frame.t(),
    query: String.t(),
    current_match: non_neg_integer(),
    total_matches: non_neg_integer(),
    focused: boolean(),
    cursor_pos: non_neg_integer(),
    font: map(),
    theme: map()
  }

  @doc """
  Creates a new SearchBar state.

  ## Options
  - `:id` - Component ID (required)
  - `:frame` - Widgex.Frame for positioning (required)
  - `:query` - Initial search query (default: "")
  - `:font` - Font settings map with :name and :size
  - `:theme` - Color theme map
  """
  def new(opts) do
    id = opts[:id] || raise ArgumentError, "SearchBar requires :id"
    frame = opts[:frame] || raise ArgumentError, "SearchBar requires :frame"

    default_font = %{
      name: :roboto_mono,
      size: 16,
      metrics: nil
    }

    default_theme = %{
      background: {45, 45, 45},          # Dark gray background
      input_background: {60, 60, 60},    # Slightly lighter input area
      text: :white,
      placeholder: {128, 128, 128},      # Gray placeholder
      border: {80, 80, 80},              # Border color
      button_bg: {70, 70, 70},           # Button background
      button_hover: {90, 90, 90},        # Button hover
      match_highlight: {255, 200, 0}     # Yellow for match count
    }

    %__MODULE__{
      id: id,
      frame: frame,
      query: opts[:query] || "",
      current_match: 0,
      total_matches: 0,
      focused: true,
      cursor_pos: String.length(opts[:query] || ""),
      font: Map.merge(default_font, opts[:font] || %{}),
      theme: Map.merge(default_theme, opts[:theme] || %{})
    }
  end

  @doc """
  Updates the match count display.
  """
  def set_matches(%__MODULE__{} = state, current, total) do
    %{state | current_match: current, total_matches: total}
  end

  @doc """
  Sets the search query and resets cursor to end.
  """
  def set_query(%__MODULE__{} = state, query) when is_binary(query) do
    %{state | query: query, cursor_pos: String.length(query)}
  end

  @doc """
  Appends a character to the query at cursor position.
  """
  def insert_char(%__MODULE__{query: query, cursor_pos: pos} = state, char) when is_binary(char) do
    {before, after_cursor} = String.split_at(query, pos)
    new_query = before <> char <> after_cursor
    %{state | query: new_query, cursor_pos: pos + String.length(char)}
  end

  @doc """
  Deletes character before cursor (backspace).
  """
  def delete_before_cursor(%__MODULE__{query: query, cursor_pos: pos} = state) when pos > 0 do
    graphemes = String.graphemes(query)
    new_graphemes = List.delete_at(graphemes, pos - 1)
    new_query = Enum.join(new_graphemes)
    %{state | query: new_query, cursor_pos: pos - 1}
  end

  def delete_before_cursor(%__MODULE__{} = state), do: state

  @doc """
  Deletes character at cursor (delete key).
  """
  def delete_at_cursor(%__MODULE__{query: query, cursor_pos: pos} = state) do
    graphemes = String.graphemes(query)
    if pos < length(graphemes) do
      new_graphemes = List.delete_at(graphemes, pos)
      new_query = Enum.join(new_graphemes)
      %{state | query: new_query}
    else
      state
    end
  end

  @doc """
  Moves cursor left.
  """
  def cursor_left(%__MODULE__{cursor_pos: pos} = state) when pos > 0 do
    %{state | cursor_pos: pos - 1}
  end

  def cursor_left(%__MODULE__{} = state), do: state

  @doc """
  Moves cursor right.
  """
  def cursor_right(%__MODULE__{query: query, cursor_pos: pos} = state) do
    max_pos = String.length(query)
    if pos < max_pos do
      %{state | cursor_pos: pos + 1}
    else
      state
    end
  end

  @doc """
  Moves cursor to start of query.
  """
  def cursor_home(%__MODULE__{} = state) do
    %{state | cursor_pos: 0}
  end

  @doc """
  Moves cursor to end of query.
  """
  def cursor_end(%__MODULE__{query: query} = state) do
    %{state | cursor_pos: String.length(query)}
  end

  @doc """
  Clears the search query.
  """
  def clear(%__MODULE__{} = state) do
    %{state | query: "", cursor_pos: 0, current_match: 0, total_matches: 0}
  end
end
