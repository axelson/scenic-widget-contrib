defmodule ScenicWidgets.SearchBar do
  @moduledoc """
  A reusable search bar component for Scenic applications.

  Provides a horizontal search bar with:
  - Text input field for search query
  - Previous/Next navigation buttons
  - Match count display (e.g., "3/10")
  - Close button

  ## Usage

      ScenicWidgets.SearchBar.add_to_graph(graph,
        %{
          id: :search_bar,
          frame: %Widgex.Frame{pin: {0, 0}, size: {400, 36}},
          query: "initial search"  # optional
        },
        id: :search_bar
      )

  ## Events Emitted

  The component sends events to its parent via `cast_parent/2`:

  - `{:search_query_changed, id, query}` - when user types in search field
  - `{:search_next, id}` - when clicking next button or pressing Enter
  - `{:search_prev, id}` - when clicking previous button or pressing Shift+Enter
  - `{:search_close, id}` - when clicking close button or pressing Escape

  ## Updating Match Count

  To update the match count display, send a message to the component:

      Scenic.Scene.put_child(scene, :search_bar, {:set_matches, current, total})

  ## Keyboard Shortcuts

  - `Enter` - Navigate to next match
  - `Shift+Enter` - Navigate to previous match
  - `Escape` - Close the search bar
  - `Backspace` - Delete character before cursor
  - `Delete` - Delete character at cursor
  - `Left/Right` - Move cursor
  - `Home` - Move cursor to start
  - `End` - Move cursor to end
  """

  use Scenic.Component
  use ScenicWidgets.ScenicEventsDefinitions

  require Logger

  alias ScenicWidgets.SearchBar.State
  alias ScenicWidgets.SearchBar.Renderer
  alias Widgex.Frame

  # Key constants
  @key_pressed 1

  # Validate component data
  def validate(%{id: id, frame: %Frame{}} = data) when is_atom(id) do
    {:ok, data}
  end

  def validate(%{frame: %Frame{}} = data) do
    {:ok, Map.put(data, :id, :search_bar)}
  end

  def validate(data) do
    {:error, "SearchBar requires :id (atom) and :frame (Widgex.Frame), got: #{inspect(data)}"}
  end

  @doc """
  Add the SearchBar to a graph.
  """
  def add_to_graph(graph, data, opts \\ []) do
    # Use the default implementation provided by Scenic.Component
    super(graph, data, opts)
  end

  # Initialize the component
  def init(scene, data, opts) do
    id = opts[:id] || data[:id] || :search_bar

    state = State.new(%{
      id: id,
      frame: data.frame,
      query: data[:query] || "",
      font: data[:font],
      theme: data[:theme]
    })

    graph = Renderer.render(state)

    init_scene =
      scene
      |> assign(id: id)
      |> assign(state: state)
      |> assign(graph: graph)
      |> push_graph(graph)

    # Request keyboard and mouse input
    request_input(init_scene, [:key, :codepoint, :cursor_button, :cursor_pos])

    {:ok, init_scene}
  end

  # Handle external updates (e.g., set match count)
  def handle_put({:set_matches, current, total}, scene) do
    state = State.set_matches(scene.assigns.state, current, total)
    graph = Renderer.update_match_count(scene.assigns.graph, state)

    new_scene =
      scene
      |> assign(state: state)
      |> assign(graph: graph)
      |> push_graph(graph)

    {:noreply, new_scene}
  end

  def handle_put({:set_query, query}, scene) do
    state = State.set_query(scene.assigns.state, query)
    graph = Renderer.render(state)

    new_scene =
      scene
      |> assign(state: state)
      |> assign(graph: graph)
      |> push_graph(graph)

    {:noreply, new_scene}
  end

  def handle_put(:focus, scene) do
    state = %{scene.assigns.state | focused: true}
    graph = Renderer.render(state)

    new_scene =
      scene
      |> assign(state: state)
      |> assign(graph: graph)
      |> push_graph(graph)

    {:noreply, new_scene}
  end

  def handle_put(:clear, scene) do
    state = State.clear(scene.assigns.state)
    graph = Renderer.render(state)

    new_scene =
      scene
      |> assign(state: state)
      |> assign(graph: graph)
      |> push_graph(graph)

    {:noreply, new_scene}
  end

  # Handle text input (codepoints)
  def handle_input({:codepoint, {char, _}}, _context, scene) when char != "" do
    state = State.insert_char(scene.assigns.state, char)
    graph = Renderer.render(state)

    new_scene =
      scene
      |> assign(state: state)
      |> assign(graph: graph)
      |> push_graph(graph)

    # Emit query changed event
    cast_parent(new_scene, {:search_query_changed, state.id, state.query})

    {:noreply, new_scene}
  end

  # Handle Enter - next match
  def handle_input({:key, {:key_enter, @key_pressed, []}}, _context, scene) do
    cast_parent(scene, {:search_next, scene.assigns.state.id})
    {:noreply, scene}
  end

  # Handle Shift+Enter - previous match
  def handle_input({:key, {:key_enter, @key_pressed, [:shift]}}, _context, scene) do
    cast_parent(scene, {:search_prev, scene.assigns.state.id})
    {:noreply, scene}
  end

  # Handle Escape - close
  def handle_input({:key, {:key_escape, @key_pressed, _}}, _context, scene) do
    cast_parent(scene, {:search_close, scene.assigns.state.id})
    {:noreply, scene}
  end

  # Handle Backspace
  def handle_input({:key, {:key_backspace, @key_pressed, _}}, _context, scene) do
    state = State.delete_before_cursor(scene.assigns.state)
    graph = Renderer.render(state)

    new_scene =
      scene
      |> assign(state: state)
      |> assign(graph: graph)
      |> push_graph(graph)

    cast_parent(new_scene, {:search_query_changed, state.id, state.query})
    {:noreply, new_scene}
  end

  # Handle Delete
  def handle_input({:key, {:key_delete, @key_pressed, _}}, _context, scene) do
    state = State.delete_at_cursor(scene.assigns.state)
    graph = Renderer.render(state)

    new_scene =
      scene
      |> assign(state: state)
      |> assign(graph: graph)
      |> push_graph(graph)

    cast_parent(new_scene, {:search_query_changed, state.id, state.query})
    {:noreply, new_scene}
  end

  # Handle Left arrow
  def handle_input({:key, {:key_left, @key_pressed, _}}, _context, scene) do
    state = State.cursor_left(scene.assigns.state)
    graph = Renderer.render(state)

    new_scene =
      scene
      |> assign(state: state)
      |> assign(graph: graph)
      |> push_graph(graph)

    {:noreply, new_scene}
  end

  # Handle Right arrow
  def handle_input({:key, {:key_right, @key_pressed, _}}, _context, scene) do
    state = State.cursor_right(scene.assigns.state)
    graph = Renderer.render(state)

    new_scene =
      scene
      |> assign(state: state)
      |> assign(graph: graph)
      |> push_graph(graph)

    {:noreply, new_scene}
  end

  # Handle Home key
  def handle_input({:key, {:key_home, @key_pressed, _}}, _context, scene) do
    state = State.cursor_home(scene.assigns.state)
    graph = Renderer.render(state)

    new_scene =
      scene
      |> assign(state: state)
      |> assign(graph: graph)
      |> push_graph(graph)

    {:noreply, new_scene}
  end

  # Handle End key
  def handle_input({:key, {:key_end, @key_pressed, _}}, _context, scene) do
    state = State.cursor_end(scene.assigns.state)
    graph = Renderer.render(state)

    new_scene =
      scene
      |> assign(state: state)
      |> assign(graph: graph)
      |> push_graph(graph)

    {:noreply, new_scene}
  end

  # Handle mouse clicks on buttons
  def handle_input({:cursor_button, {:btn_left, 1, _, coords}}, _context, scene) do
    handle_click(scene, coords)
  end

  # Ignore other inputs
  def handle_input(_input, _context, scene) do
    {:noreply, scene}
  end

  # Handle clicks on different areas
  defp handle_click(scene, {click_x, _click_y}) do
    %{frame: frame} = scene.assigns.state
    {width, _height} = frame.size

    button_width = 32
    match_count_width = 60
    nav_start_x = width - (button_width * 2) - match_count_width

    cond do
      # Close button area (first 32px)
      click_x < button_width ->
        cast_parent(scene, {:search_close, scene.assigns.state.id})
        {:noreply, scene}

      # Previous button area
      click_x >= nav_start_x and click_x < nav_start_x + button_width ->
        cast_parent(scene, {:search_prev, scene.assigns.state.id})
        {:noreply, scene}

      # Next button area
      click_x >= nav_start_x + button_width + match_count_width ->
        cast_parent(scene, {:search_next, scene.assigns.state.id})
        {:noreply, scene}

      # Input field area - focus it
      true ->
        {:noreply, scene}
    end
  end

  # Handle button click events from child components
  def handle_event({:click, :close_button}, _from, scene) do
    cast_parent(scene, {:search_close, scene.assigns.state.id})
    {:noreply, scene}
  end

  def handle_event({:click, :prev_button}, _from, scene) do
    cast_parent(scene, {:search_prev, scene.assigns.state.id})
    {:noreply, scene}
  end

  def handle_event({:click, :next_button}, _from, scene) do
    cast_parent(scene, {:search_next, scene.assigns.state.id})
    {:noreply, scene}
  end

  def handle_event(_event, _from, scene) do
    {:noreply, scene}
  end
end
