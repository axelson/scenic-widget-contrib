defmodule ScenicWidgets.IconMenu do
  @moduledoc """
  A compact icon-based menu bar with dropdown menus.

  Displays a row of icon buttons (single characters like letters or symbols).
  Clicking an icon opens a dropdown menu below it. Perfect for toolbars
  that sit next to a tab bar.

  ## Features
  - Compact icon buttons (letters, symbols, emoji as icons)
  - Dropdown menus on click
  - Hover highlighting
  - Menu item callbacks
  - Keyboard navigation (Escape to close)

  ## Usage

      menus = [
        %{id: :file, icon: "F", items: [
          {"new", "New File"},
          {"open", "Open..."},
          {"save", "Save"}
        ]},
        %{id: :edit, icon: "E", items: [
          {"undo", "Undo"},
          {"redo", "Redo"}
        ]}
      ]

      graph
      |> ScenicWidgets.IconMenu.add_to_graph(
        %{frame: frame, menus: menus},
        id: :my_icon_menu
      )

  ## Events

  IconMenu sends these events to the parent scene:
  - `{:menu_item_clicked, item_id}` - When a menu item is clicked

  Handle in your scene:

      def handle_event({:menu_item_clicked, "new"}, _from, scene) do
        # Handle "New File" action
        {:noreply, scene}
      end

  ## Theme Customization

  Pass a `:theme` map to override defaults:

      %{
        frame: frame,
        menus: menus,
        theme: %{
          icon_button_size: 40,
          dropdown_width: 200
        }
      }
  """

  use Scenic.Component, has_children: false
  require Logger

  alias ScenicWidgets.IconMenu.{State, Reducer, Renderer}
  alias Scenic.Graph

  @impl Scenic.Component
  def validate(%Widgex.Frame{} = frame) do
    {:ok, %{frame: frame, menus: State.demo_menus()}}
  end

  def validate(%{frame: %Widgex.Frame{}} = data) do
    {:ok, data}
  end

  def validate(%{frame: %{pin: _, size: _}} = data) do
    {:ok, data}
  end

  def validate(_) do
    {:error, "IconMenu requires :frame (Widgex.Frame) and optional :menus list"}
  end

  @impl Scenic.Scene
  def init(scene, data, _opts) do
    state = State.new(data)
    graph = Renderer.initial_render(Graph.build(), state)

    scene =
      scene
      |> assign(state: state, graph: graph)
      |> push_graph(graph)

    # Request input for mouse and keyboard interaction
    request_input(scene, [:cursor_pos, :cursor_button, :key])

    Logger.debug("IconMenu initialized with #{length(state.menus)} menus")

    {:ok, scene}
  end

  @impl Scenic.Scene
  def handle_input(input, _context, scene) do
    state = scene.assigns.state

    case Reducer.process_input(state, input) do
      {:noop, ^state} ->
        # No change
        {:noreply, scene}

      {:noop, new_state} ->
        # Internal state changed (hover, menu open/close)
        update_scene(scene, state, new_state)

      {:menu_item_clicked, item_id, new_state} ->
        send_parent_event(scene, {:menu_item_clicked, item_id})
        update_scene(scene, state, new_state)
    end
  end

  @impl Scenic.Scene
  def handle_put({:open_menu, menu_id}, scene) do
    state = scene.assigns.state
    new_state = %{state | active_menu: menu_id}
    update_scene_tuple(scene, state, new_state)
  end

  def handle_put({:close_menu}, scene) do
    state = scene.assigns.state
    new_state = %{state | active_menu: nil, hovered_item: nil}
    update_scene_tuple(scene, state, new_state)
  end

  # Update menus (e.g., to change toggle states)
  def handle_put({:update_menus, menus}, scene) do
    state = scene.assigns.state
    new_state = %{state | menus: menus}
    new_state = %{new_state | dropdown_bounds: State.calculate_dropdown_bounds(new_state)}

    # Re-render from scratch to reflect menu changes
    graph = Renderer.initial_render(Graph.build(), new_state)
    scene = scene
      |> assign(state: new_state, graph: graph)
      |> push_graph(graph)
    {:noreply, scene}
  end

  def handle_put(_msg, scene) do
    {:noreply, scene}
  end

  # ===========================================================================
  # Private Helpers
  # ===========================================================================

  defp update_scene(scene, old_state, new_state) do
    graph = Renderer.update_render(scene.assigns.graph, old_state, new_state)
    scene = scene
      |> assign(state: new_state, graph: graph)
      |> push_graph(graph)
    {:noreply, scene}
  end

  defp update_scene_tuple(scene, old_state, new_state) do
    graph = Renderer.update_render(scene.assigns.graph, old_state, new_state)
    scene = scene
      |> assign(state: new_state, graph: graph)
      |> push_graph(graph)
    {:noreply, scene}
  end
end
