defmodule ScenicWidgets.TabBar.Reducer do
  @moduledoc """
  Pure state transition functions for TabBar.

  All functions are pure - they take state + input and return {:action, new_state}.
  No side effects or mutations.
  """

  alias ScenicWidgets.TabBar.State

  # Pixels to scroll per wheel tick
  @scroll_amount 50

  @doc """
  Process user input and return state transitions.

  Returns:
  - `{:noop, state}` - State unchanged or only internal state changed
  - `{:tab_selected, tab_id, state}` - Tab was selected
  - `{:tab_closed, tab_id, state}` - Tab was closed
  """
  def process_input(%State{} = state, {:cursor_pos, coords}) do
    handle_hover(state, coords)
  end

  def process_input(%State{} = state, {:cursor_button, {:btn_left, 1, [], coords}}) do
    handle_click(state, coords)
  end

  def process_input(%State{} = state, {:cursor_scroll, {_dx, dy, _x, _y}}) do
    handle_scroll(state, dy)
  end

  def process_input(%State{} = state, {:cursor_scroll, {{dx, dy}, _coords}}) do
    delta = if dx == 0, do: dy, else: dx
    handle_scroll(state, delta)
  end

  def process_input(%State{} = state, {:cursor_scroll, {_dx, dy}}) do
    handle_scroll(state, dy)
  end

  def process_input(state, _input) do
    {:noop, state}
  end

  @doc """
  Handle cursor position for hover effects.
  """
  def handle_hover(%State{} = state, coords) do
    if State.point_inside?(state, coords) do
      case State.hit_test(state, coords) do
        {:close, tab_id} ->
          new_state = %{state | hovered_tab_id: tab_id, hovered_close_id: tab_id}
          {:noop, new_state}

        {:tab, tab_id} ->
          new_state = %{state | hovered_tab_id: tab_id, hovered_close_id: nil}
          {:noop, new_state}

        :none ->
          new_state = %{state | hovered_tab_id: nil, hovered_close_id: nil}
          {:noop, new_state}
      end
    else
      # Mouse outside tab bar - clear hover
      if state.hovered_tab_id || state.hovered_close_id do
        {:noop, %{state | hovered_tab_id: nil, hovered_close_id: nil}}
      else
        {:noop, state}
      end
    end
  end

  @doc """
  Handle click events for tab selection and closing.
  """
  def handle_click(%State{} = state, coords) do
    if State.point_inside?(state, coords) do
      case State.hit_test(state, coords) do
        {:close, tab_id} ->
          close_tab(state, tab_id)

        {:tab, tab_id} ->
          select_tab(state, tab_id)

        :none ->
          {:noop, state}
      end
    else
      {:noop, state}
    end
  end

  @doc """
  Handle horizontal scrolling.
  """
  def handle_scroll(%State{} = state, delta_y) do
    # Negative delta = scroll right, positive = scroll left (natural scrolling)
    new_offset = state.scroll_offset - delta_y * @scroll_amount

    # Clamp to valid range
    max_offset = State.max_scroll_offset(state)
    clamped_offset = new_offset |> max(0) |> min(max_offset)

    if clamped_offset != state.scroll_offset do
      {:noop, %{state | scroll_offset: clamped_offset}}
    else
      {:noop, state}
    end
  end

  @doc """
  Select a tab by ID.
  """
  def select_tab(%State{selected_id: current_id} = state, tab_id) when current_id == tab_id do
    # Already selected, no change
    {:noop, state}
  end

  def select_tab(%State{} = state, tab_id) do
    new_state = State.ensure_selected_visible(%{state | selected_id: tab_id})
    {:tab_selected, tab_id, new_state}
  end

  @doc """
  Close a tab by ID.
  """
  def close_tab(%State{tabs: tabs} = state, tab_id) do
    tab = Enum.find(tabs, &(&1.id == tab_id))

    cond do
      # Tab not found or not closeable
      tab == nil or not tab.closeable ->
        {:noop, state}

      # Last tab - don't close
      length(tabs) == 1 ->
        {:noop, state}

      true ->
        # Remove the tab
        new_tabs = Enum.reject(tabs, &(&1.id == tab_id))

        # If we closed the selected tab, select an adjacent one
        new_selected =
          if state.selected_id == tab_id do
            select_adjacent_tab(tabs, tab_id)
          else
            state.selected_id
          end

        # Recalculate tab widths
        new_state = %{
          state
          | tabs: new_tabs,
            selected_id: new_selected,
            hovered_tab_id: nil,
            hovered_close_id: nil
        }

        new_state = %{new_state | tab_widths: State.calculate_tab_widths(new_state)}

        # Adjust scroll if needed
        max_offset = State.max_scroll_offset(new_state)
        new_state = %{new_state | scroll_offset: min(new_state.scroll_offset, max_offset)}

        {:tab_closed, tab_id, new_state}
    end
  end

  @doc """
  Add a new tab.
  """
  def add_tab(%State{tabs: tabs} = state, tab) do
    normalized = hd(State.normalize_tabs([tab]))
    new_tabs = tabs ++ [normalized]

    new_state = %{state | tabs: new_tabs}
    new_state = %{new_state | tab_widths: State.calculate_tab_widths(new_state)}

    {:tab_added, normalized.id, new_state}
  end

  # Find the tab to select when closing the current one
  defp select_adjacent_tab(tabs, closing_id) do
    index = Enum.find_index(tabs, &(&1.id == closing_id))

    cond do
      # Try to select the tab to the right
      index < length(tabs) - 1 ->
        Enum.at(tabs, index + 1).id

      # Otherwise select the tab to the left
      index > 0 ->
        Enum.at(tabs, index - 1).id

      # Shouldn't happen (single tab case handled above)
      true ->
        nil
    end
  end
end
