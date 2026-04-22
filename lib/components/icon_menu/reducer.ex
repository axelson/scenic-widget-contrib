defmodule ScenicWidgets.IconMenu.Reducer do
  @moduledoc """
  Pure state transition functions for IconMenu.

  Handles cursor movements, clicks, and keyboard input.
  """

  alias ScenicWidgets.IconMenu.State

  @doc """
  Process user input and return state transitions.

  Returns:
  - `{:noop, state}` - State unchanged or only visual state changed
  - `{:menu_item_clicked, item_id, state}` - Menu item was clicked
  """
  def process_input(%State{} = state, {:cursor_pos, coords}) do
    handle_cursor_pos(state, coords)
  end

  def process_input(%State{} = state, {:cursor_button, {:btn_left, 1, [], coords}}) do
    handle_click(state, coords)
  end

  def process_input(%State{} = state, {:key, {:key_esc, key_state, _mods}})
      when key_state > 0 do
    handle_escape(state)
  end

  def process_input(state, _input) do
    {:noop, state}
  end

  @doc """
  Handle cursor position for hover effects.
  """
  def handle_cursor_pos(%State{} = state, coords) do
    cond do
      # Check if cursor is over icon buttons
      State.point_in_icon_bar?(state, coords) ->
        hovered_icon = State.find_hovered_icon(state, coords)

        new_state = %{state | hovered_menu: hovered_icon, hovered_item: nil}

        # If a dropdown is open and we hover a different icon, switch to it
        new_state = if state.active_menu && hovered_icon && state.active_menu != hovered_icon do
          %{new_state | active_menu: hovered_icon}
        else
          new_state
        end

        {:noop, new_state}

      # Check if cursor is in dropdown
      state.active_menu != nil ->
        case State.point_in_dropdown?(state, coords) do
          {true, item_id} ->
            # Inside dropdown, possibly over an item
            {:noop, %{state | hovered_item: item_id, hovered_menu: state.active_menu}}

          {false, _} ->
            # Outside dropdown - check if should close
            if State.point_outside_menu_area?(state, coords) do
              {:noop, %{state | active_menu: nil, hovered_menu: nil, hovered_item: nil}}
            else
              {:noop, %{state | hovered_item: nil}}
            end
        end

      # Cursor outside menu area
      true ->
        if state.hovered_menu do
          {:noop, %{state | hovered_menu: nil, hovered_item: nil}}
        else
          {:noop, state}
        end
    end
  end

  @doc """
  Handle click events.
  """
  def handle_click(%State{} = state, coords) do
    cond do
      # Click on icon button
      State.point_in_icon_bar?(state, coords) ->
        case State.find_hovered_icon(state, coords) do
          nil ->
            {:noop, state}

          menu_id ->
            if state.active_menu == menu_id do
              # Click on active menu - close it
              {:noop, %{state | active_menu: nil, hovered_menu: nil, hovered_item: nil}}
            else
              # Open this menu
              {:noop, %{state | active_menu: menu_id, hovered_item: nil}}
            end
        end

      # Click in dropdown
      state.active_menu != nil ->
        case State.point_in_dropdown?(state, coords) do
          {true, nil} ->
            # Click in dropdown but not on an item
            {:noop, state}

          {true, item_id} ->
            # Click on menu item
            # Execute action callback if present
            action = State.get_item_action(state, item_id)
            if is_function(action, 0), do: action.()

            # Close menu and notify parent
            new_state = %{state | active_menu: nil, hovered_menu: nil, hovered_item: nil}
            {:menu_item_clicked, item_id, new_state}

          {false, _} ->
            # Click outside dropdown - close menu
            {:noop, %{state | active_menu: nil, hovered_menu: nil, hovered_item: nil}}
        end

      # Click outside menu area
      true ->
        {:noop, state}
    end
  end

  @doc """
  Handle escape key to close menus.
  """
  def handle_escape(%State{active_menu: nil} = state) do
    {:noop, state}
  end

  def handle_escape(%State{} = state) do
    {:noop, %{state | active_menu: nil, hovered_menu: nil, hovered_item: nil}}
  end
end
