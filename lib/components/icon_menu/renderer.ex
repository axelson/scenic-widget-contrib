defmodule ScenicWidgets.IconMenu.Renderer do
  @moduledoc """
  Rendering functions for IconMenu.

  Structure:
  - Background rect
  - Icon button groups (one per menu)
  - Dropdown group (shown when a menu is active)
  """

  alias Scenic.Graph
  alias Scenic.Primitives
  alias ScenicWidgets.IconMenu.State

  @doc """
  Initial render - create all UI elements.
  """
  def initial_render(graph, %State{} = state) do
    graph
    |> render_background(state)
    |> render_icon_buttons(state)
    |> render_dropdown(state)
  end

  @doc """
  Update render - only modify elements that changed.
  """
  def update_render(graph, %State{} = old_state, %State{} = new_state) do
    graph
    |> update_icon_buttons(old_state, new_state)
    |> update_dropdown(old_state, new_state)
  end

  # ===========================================================================
  # Initial Rendering
  # ===========================================================================

  defp render_background(graph, %State{frame: frame, theme: theme}) do
    # Draw background across the full frame width
    frame_width = get_frame_width(frame)

    graph
    |> Primitives.rect(
      {frame_width, theme.height},
      id: :icon_menu_background,
      fill: theme.background
    )
  end

  defp get_frame_width(%Widgex.Frame{size: %{width: w}}), do: w
  defp get_frame_width(%{size: {w, _h}}), do: w
  defp get_frame_width(%{size: %{width: w}}), do: w
  defp get_frame_width(_), do: 0

  defp render_icon_buttons(graph, %State{menus: menus} = state) do
    Enum.reduce(menus, graph, fn menu, acc ->
      build_icon_button(acc, state, menu)
    end)
  end

  defp build_icon_button(graph, %State{theme: theme} = state, menu) do
    {x, y, width, height} = State.get_icon_button_bounds(state, menu.id)

    is_active = state.active_menu == menu.id
    is_hovered = state.hovered_menu == menu.id

    bg_color = cond do
      is_active -> theme.icon_active_bg
      is_hovered -> theme.icon_hover_bg
      true -> theme.background
    end

    icon_color = cond do
      is_active -> theme.icon_active_color
      is_hovered -> theme.icon_hover_color
      true -> theme.icon_color
    end

    graph
    |> Primitives.group(
      fn g ->
        g
        # Button background
        |> Primitives.rect(
          {width, height},
          id: {:icon_bg, menu.id},
          fill: bg_color
        )
        # Icon text (centered)
        |> Primitives.text(
          menu.icon,
          id: {:icon_text, menu.id},
          fill: icon_color,
          font: theme.font,
          font_size: theme.icon_font_size,
          text_align: :center,
          translate: {width / 2, height / 2 + theme.icon_font_size / 3}
        )
      end,
      id: {:icon_button, menu.id},
      translate: {x, y}
    )
  end

  defp render_dropdown(graph, %State{active_menu: nil}), do: graph
  defp render_dropdown(graph, %State{active_menu: menu_id, menus: menus, theme: theme, dropdown_bounds: bounds} = state) do
    menu = Enum.find(menus, &(&1.id == menu_id))
    dropdown = Map.get(bounds, menu_id)

    if menu && dropdown do
      graph
      |> Primitives.group(
        fn g ->
          g
          # Dropdown background with border
          |> Primitives.rrect(
            {dropdown.width, dropdown.height, 4},
            id: :dropdown_bg,
            fill: theme.dropdown_bg,
            stroke: {1, theme.dropdown_border}
          )
          # Render menu items
          |> render_dropdown_items(menu.items, state)
        end,
        id: :dropdown_group,
        translate: {dropdown.x, dropdown.y}
      )
    else
      graph
    end
  end

  defp render_dropdown_items(graph, items, %State{theme: theme, active_menu: menu_id, dropdown_bounds: bounds, hovered_item: hovered_item}) do
    dropdown = Map.get(bounds, menu_id)
    padding = theme.dropdown_padding

    # Space reserved for checkmark on the left
    checkmark_width = 20

    items
    |> Enum.with_index()
    |> Enum.reduce(graph, fn {item, index}, acc ->
      item_id = State.get_item_id(item)
      label = State.get_item_label(item)
      is_toggle = State.is_toggle_item?(item)
      is_checked = State.is_item_checked?(item)

      _item_bounds = Map.get(dropdown.items, item_id)
      is_hovered = hovered_item == item_id

      # Position relative to dropdown origin
      item_x = padding
      item_y = padding + (index * theme.dropdown_item_height)

      bg_color = if is_hovered, do: theme.item_hover_bg, else: :clear
      text_color = if is_hovered, do: theme.item_hover_text_color, else: theme.item_text_color

      acc
      |> Primitives.group(
        fn g ->
          g = g
          # Item background (for hover)
          |> Primitives.rrect(
            {dropdown.width - (2 * padding), theme.dropdown_item_height, 3},
            id: {:item_bg, item_id},
            fill: bg_color
          )

          # Checkmark for toggle items (only if checked)
          g = if is_toggle and is_checked do
            g
            |> Primitives.text(
              "✓",
              id: {:item_check, item_id},
              fill: text_color,
              font: theme.font,
              font_size: theme.dropdown_font_size,
              translate: {6, theme.dropdown_item_height / 2 + theme.dropdown_font_size / 3}
            )
          else
            g
          end

          # Item text (offset if toggle items exist to align all labels)
          text_x = if has_any_toggle_items?(items), do: checkmark_width, else: 8

          g
          |> Primitives.text(
            label,
            id: {:item_text, item_id},
            fill: text_color,
            font: theme.font,
            font_size: theme.dropdown_font_size,
            translate: {text_x, theme.dropdown_item_height / 2 + theme.dropdown_font_size / 3}
          )
        end,
        id: {:dropdown_item, item_id},
        translate: {item_x, item_y}
      )
    end)
  end

  # Check if any item in the list is a toggle type (to align text consistently)
  defp has_any_toggle_items?(items) do
    Enum.any?(items, &State.is_toggle_item?/1)
  end

  # ===========================================================================
  # Update Rendering
  # ===========================================================================

  defp update_icon_buttons(graph, old_state, new_state) do
    # Check if hover or active state changed
    hover_changed = old_state.hovered_menu != new_state.hovered_menu
    active_changed = old_state.active_menu != new_state.active_menu

    if hover_changed or active_changed do
      theme = new_state.theme

      # Update old hovered button (if any)
      graph = if old_state.hovered_menu && old_state.hovered_menu != new_state.hovered_menu do
        is_active = old_state.hovered_menu == new_state.active_menu
        bg_color = if is_active, do: theme.icon_active_bg, else: theme.background
        icon_color = if is_active, do: theme.icon_active_color, else: theme.icon_color

        graph
        |> Graph.modify({:icon_bg, old_state.hovered_menu}, fn p ->
          Primitives.update_opts(p, fill: bg_color)
        end)
        |> Graph.modify({:icon_text, old_state.hovered_menu}, fn p ->
          Primitives.update_opts(p, fill: icon_color)
        end)
      else
        graph
      end

      # Update new hovered button (if any)
      graph = if new_state.hovered_menu && old_state.hovered_menu != new_state.hovered_menu do
        is_active = new_state.hovered_menu == new_state.active_menu
        bg_color = if is_active, do: theme.icon_active_bg, else: theme.icon_hover_bg
        icon_color = if is_active, do: theme.icon_active_color, else: theme.icon_hover_color

        graph
        |> Graph.modify({:icon_bg, new_state.hovered_menu}, fn p ->
          Primitives.update_opts(p, fill: bg_color)
        end)
        |> Graph.modify({:icon_text, new_state.hovered_menu}, fn p ->
          Primitives.update_opts(p, fill: icon_color)
        end)
      else
        graph
      end

      # Update active state changes
      graph = if active_changed do
        # Update old active (now inactive)
        graph = if old_state.active_menu && old_state.active_menu != new_state.active_menu do
          is_hovered = old_state.active_menu == new_state.hovered_menu
          bg_color = if is_hovered, do: theme.icon_hover_bg, else: theme.background
          icon_color = if is_hovered, do: theme.icon_hover_color, else: theme.icon_color

          graph
          |> Graph.modify({:icon_bg, old_state.active_menu}, fn p ->
            Primitives.update_opts(p, fill: bg_color)
          end)
          |> Graph.modify({:icon_text, old_state.active_menu}, fn p ->
            Primitives.update_opts(p, fill: icon_color)
          end)
        else
          graph
        end

        # Update new active
        if new_state.active_menu do
          graph
          |> Graph.modify({:icon_bg, new_state.active_menu}, fn p ->
            Primitives.update_opts(p, fill: theme.icon_active_bg)
          end)
          |> Graph.modify({:icon_text, new_state.active_menu}, fn p ->
            Primitives.update_opts(p, fill: theme.icon_active_color)
          end)
        else
          graph
        end
      else
        graph
      end

      graph
    else
      graph
    end
  end

  defp update_dropdown(graph, old_state, new_state) do
    cond do
      # Dropdown opened or changed
      old_state.active_menu != new_state.active_menu ->
        # Need to rebuild the dropdown - remove old and add new
        graph = if old_state.active_menu do
          Graph.delete(graph, :dropdown_group)
        else
          graph
        end

        if new_state.active_menu do
          render_dropdown(graph, new_state)
        else
          graph
        end

      # Same dropdown, but hover changed
      new_state.active_menu && old_state.hovered_item != new_state.hovered_item ->
        update_dropdown_hover(graph, old_state, new_state)

      true ->
        graph
    end
  end

  defp update_dropdown_hover(graph, old_state, new_state) do
    theme = new_state.theme

    # Un-hover old item
    graph = if old_state.hovered_item do
      graph
      |> Graph.modify({:item_bg, old_state.hovered_item}, fn p ->
        Primitives.update_opts(p, fill: :clear)
      end)
      |> Graph.modify({:item_text, old_state.hovered_item}, fn p ->
        Primitives.update_opts(p, fill: theme.item_text_color)
      end)
    else
      graph
    end

    # Hover new item
    if new_state.hovered_item do
      graph
      |> Graph.modify({:item_bg, new_state.hovered_item}, fn p ->
        Primitives.update_opts(p, fill: theme.item_hover_bg)
      end)
      |> Graph.modify({:item_text, new_state.hovered_item}, fn p ->
        Primitives.update_opts(p, fill: theme.item_hover_text_color)
      end)
    else
      graph
    end
  end
end
