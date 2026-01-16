defmodule ScenicWidgets.SearchBar.Renderer do
  @moduledoc """
  Renderer for the SearchBar component.

  Renders a horizontal search bar with:
  - Text input field with cursor
  - Previous/Next navigation buttons (< >)
  - Match count display (e.g., "3 of 10")
  - Close button (X)

  Layout:
  [Close X] [    Search input field    ] [< Prev] [3/10] [Next >]
  """

  alias ScenicWidgets.SearchBar.State
  alias Scenic.Graph
  alias Scenic.Primitives

  # Layout constants
  @bar_height 36
  @button_width 32
  @input_padding 8
  @text_padding 10
  @match_count_width 60

  @doc """
  Renders the complete search bar.
  """
  def render(%State{} = state) do
    %{frame: frame, theme: theme, query: query, current_match: current, total_matches: total, font: font, focused: focused, cursor_pos: cursor_pos} = state
    # Handle both tuple and Dimensions struct for size
    width = case frame.size do
      %{width: w} -> w
      {w, _h} -> w
    end

    # Component renders at {0, 0} - Scenic positions the component at frame.pin
    # All coordinates are relative to component origin

    # Calculate component positions (relative to {0, 0})
    close_x = 0
    input_x = @button_width + @input_padding
    nav_start_x = width - (@button_width * 2) - @match_count_width
    input_width = nav_start_x - input_x - @input_padding

    # Match count text
    match_text = if total > 0, do: "#{current}/#{total}", else: "0/0"
    match_color = if total > 0, do: theme.match_highlight, else: theme.placeholder

    # Query text to display
    query_text = if query == "", do: "Search...", else: query
    query_color = if query == "", do: theme.placeholder, else: theme.text

    # Cursor position
    cursor_x = if cursor_pos == 0, do: 0, else: cursor_pos * font.size * 0.6

    Graph.build()
    # Background bar
    |> Primitives.rect({width, @bar_height},
      id: :search_bar_bg,
      fill: theme.background,
      stroke: {1, theme.border},
      translate: {0, 0}
    )
    # Close button background
    |> Primitives.rect({@button_width, @bar_height},
      fill: theme.button_bg,
      translate: {close_x, 0}
    )
    # Close button X lines
    |> Primitives.line({{close_x + 8, 10}, {close_x + 24, 26}},
      stroke: {2, theme.text},
      cap: :round
    )
    |> Primitives.line({{close_x + 24, 10}, {close_x + 8, 26}},
      stroke: {2, theme.text},
      cap: :round
    )
    # Input field background
    |> Primitives.rounded_rectangle({input_width, @bar_height - 8, 4},
      fill: theme.input_background,
      stroke: {1, if(focused, do: {100, 150, 255}, else: theme.border)},
      translate: {input_x, 4}
    )
    # Query text
    |> Primitives.text(query_text,
      id: :query_text,
      font: font.name,
      font_size: font.size,
      fill: query_color,
      translate: {input_x + 28, @bar_height / 2 + 5}
    )
    # Cursor line (if focused)
    |> maybe_add_cursor(focused, input_x + 28 + cursor_x, 0, theme)
    # Prev button
    |> Primitives.rect({@button_width, @bar_height},
      fill: theme.button_bg,
      translate: {nav_start_x, 0}
    )
    |> Primitives.text("<",
      font: :roboto_mono,
      font_size: 18,
      fill: theme.text,
      translate: {nav_start_x + @button_width / 2 - 5, @bar_height / 2 + 6}
    )
    # Match count
    |> Primitives.text(match_text,
      id: :match_count,
      font: :roboto_mono,
      font_size: 14,
      fill: match_color,
      translate: {nav_start_x + @button_width + @match_count_width / 2 - 10, @bar_height / 2 + 5}
    )
    # Next button
    |> Primitives.rect({@button_width, @bar_height},
      fill: theme.button_bg,
      translate: {nav_start_x + @button_width + @match_count_width, 0}
    )
    |> Primitives.text(">",
      font: :roboto_mono,
      font_size: 18,
      fill: theme.text,
      translate: {nav_start_x + @button_width + @match_count_width + @button_width / 2 - 5, @bar_height / 2 + 6}
    )
  end

  defp maybe_add_cursor(graph, false, _x, _y, _theme), do: graph
  defp maybe_add_cursor(graph, true, x, _y, theme) do
    graph
    |> Primitives.line({{x, 8}, {x, @bar_height - 8}},
      id: :cursor,
      stroke: {2, theme.text}
    )
  end

  # Render the close button
  defp render_close_button(graph, x, theme) do
    center_y = @bar_height / 2

    graph
    |> Primitives.group(
      fn g ->
        g
        |> Primitives.rect({@button_width, @bar_height},
          fill: theme.button_bg,
          id: :close_bg
        )
        # X icon using lines
        |> Primitives.line({{8, 10}, {24, 26}},
          stroke: {2, theme.text},
          cap: :round
        )
        |> Primitives.line({{24, 10}, {8, 26}},
          stroke: {2, theme.text},
          cap: :round
        )
      end,
      id: :close_button,
      translate: {x, 0}
    )
  end

  # Render the search input field
  defp render_input_field(graph, %State{} = state, x, width) do
    %{query: query, cursor_pos: cursor_pos, focused: focused, theme: theme, font: font} = state

    # Calculate cursor x position
    cursor_x = calculate_cursor_x(query, cursor_pos, font)

    graph
    |> Primitives.group(
      fn g ->
        g
        # Input background
        |> Primitives.rounded_rectangle({width, @bar_height - 8, 4},
          fill: theme.input_background,
          stroke: {1, if(focused, do: {100, 150, 255}, else: theme.border)},
          translate: {0, 4}
        )
        # Search icon (magnifying glass)
        |> Primitives.circle(5,
          stroke: {2, theme.placeholder},
          translate: {14, @bar_height / 2}
        )
        |> Primitives.line({{18, @bar_height / 2 + 4}, {22, @bar_height / 2 + 8}},
          stroke: {2, theme.placeholder},
          cap: :round
        )
        # Query text or placeholder
        |> render_query_text(state, width)
        # Cursor (blinking line)
        |> render_cursor(cursor_x, focused, theme)
      end,
      id: :input_field,
      translate: {x, 0}
    )
  end

  # Render query text or placeholder
  defp render_query_text(graph, %State{query: "", theme: theme, font: font}, _width) do
    graph
    |> Primitives.text("Search...",
      id: :query_text,
      font: font.name,
      font_size: font.size,
      fill: theme.placeholder,
      translate: {28, @bar_height / 2 + 5}
    )
  end

  defp render_query_text(graph, %State{query: query, theme: theme, font: font}, _width) do
    graph
    |> Primitives.text(query,
      id: :query_text,
      font: font.name,
      font_size: font.size,
      fill: theme.text,
      translate: {28, @bar_height / 2 + 5}
    )
  end

  # Render cursor
  defp render_cursor(graph, cursor_x, true = _focused, theme) do
    graph
    |> Primitives.line({{cursor_x + 28, 8}, {cursor_x + 28, @bar_height - 8}},
      id: :cursor,
      stroke: {2, theme.text}
    )
  end

  defp render_cursor(graph, _cursor_x, false, _theme), do: graph

  # Render navigation button
  defp render_nav_button(graph, direction, x, theme) do
    {arrow_char, id} = case direction do
      :prev -> {"<", :prev_button}
      :next -> {">", :next_button}
    end

    graph
    |> Primitives.group(
      fn g ->
        g
        |> Primitives.rect({@button_width, @bar_height},
          fill: theme.button_bg,
          id: :"#{id}_bg"
        )
        |> Primitives.text(arrow_char,
          font: :roboto_mono,
          font_size: 18,
          fill: theme.text,
          text_align: :center,
          translate: {@button_width / 2, @bar_height / 2 + 6}
        )
      end,
      id: id,
      translate: {x, 0}
    )
  end

  # Render match count display
  defp render_match_count(graph, %State{current_match: current, total_matches: total, theme: theme}, x) do
    display_text = if total > 0 do
      "#{current}/#{total}"
    else
      "0/0"
    end

    text_color = if total > 0, do: theme.match_highlight, else: theme.placeholder

    graph
    |> Primitives.group(
      fn g ->
        g
        |> Primitives.rect({@match_count_width, @bar_height},
          fill: theme.background
        )
        |> Primitives.text(display_text,
          id: :match_count,
          font: :roboto_mono,
          font_size: 14,
          fill: text_color,
          text_align: :center,
          translate: {@match_count_width / 2, @bar_height / 2 + 5}
        )
      end,
      id: :match_count_group,
      translate: {x, 0}
    )
  end

  # Calculate cursor x position based on text width
  defp calculate_cursor_x(query, cursor_pos, font) do
    if cursor_pos == 0 do
      0
    else
      text_before_cursor = String.slice(query, 0, cursor_pos)
      # Approximate width calculation (monospace font)
      char_width = font.size * 0.6
      String.length(text_before_cursor) * char_width
    end
  end

  @doc """
  Updates the graph with new query text.
  """
  def update_query(graph, %State{} = state) do
    %{query: query, cursor_pos: cursor_pos, focused: focused, theme: theme, font: font} = state
    cursor_x = calculate_cursor_x(query, cursor_pos, font)

    graph
    |> Graph.modify(:query_text, fn primitive ->
      if query == "" do
        Primitives.text(primitive, "Search...",
          fill: theme.placeholder
        )
      else
        Primitives.text(primitive, query,
          fill: theme.text
        )
      end
    end)
    |> update_cursor(cursor_x, focused, theme)
  end

  defp update_cursor(graph, cursor_x, true, theme) do
    Graph.modify(graph, :cursor, fn primitive ->
      Primitives.line(primitive, {{cursor_x + 28, 8}, {cursor_x + 28, @bar_height - 8}},
        stroke: {2, theme.text}
      )
    end)
  end

  defp update_cursor(graph, _cursor_x, false, _theme), do: graph

  @doc """
  Updates the match count display.
  """
  def update_match_count(graph, %State{current_match: current, total_matches: total, theme: theme}) do
    display_text = if total > 0 do
      "#{current}/#{total}"
    else
      "0/0"
    end

    text_color = if total > 0, do: theme.match_highlight, else: theme.placeholder

    Graph.modify(graph, :match_count, fn primitive ->
      Primitives.text(primitive, display_text, fill: text_color)
    end)
  end
end
