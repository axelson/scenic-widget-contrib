defmodule ScenicWidgets.SideNav.State do
  @moduledoc """
  State management for the SideNav component.

  Follows the HexDocs sidebar pattern with:
  - Hierarchical tree structure
  - Expand/collapse state per node
  - Active item tracking
  - Focused item for keyboard navigation
  - Scroll state via Widgex.Scrollable
  """

  use Widgex.Scrollable, direction: :vertical

  alias ScenicWidgets.SideNav.Item

  defstruct [
    :frame,              # Component frame
    :tree,               # Hierarchical tree of Sidebar.Item structs
    :active_id,          # Currently active/selected item ID
    :focused_id,         # Currently focused item (for keyboard nav)
    :hovered_id,         # Currently hovered item (for hover effects)
    :expanded,           # MapSet of expanded node IDs
    :scroll,             # Widgex.Scroll.ScrollState for scrolling
    :theme,              # Visual theme configuration
    :item_bounds         # Pre-calculated bounds for hit-testing
  ]

  @default_theme %{
    # Colors - HexDocs light theme (with visible background)
    background: :white,                    # Solid white background
    text: {34, 34, 34},                    # #222222
    active_bg: {229, 242, 255},            # #E5F2FF
    active_bar: {76, 86, 106},             # Darker slate blue for active bar
    hover_bg: {240, 240, 240},             # Slightly darker hover
    chevron: {80, 80, 80},                 # Dark gray for chevrons
    focus_ring: {0, 112, 214},             # #0070D6
    border: {200, 200, 200},               # Visible border

    # Dimensions
    item_height: 28,                        # Slightly smaller item height
    indent: 16,                            # Indentation per level
    font: :roboto,                         # Use Roboto (standard Scenic font)
    font_size: 14,                         # Font size
    line_height: 20,

    # Spacing
    padding_left: 12,                      # Left padding for top-level items
    padding_right: 12,                     # Right padding
    item_spacing: 0,                       # No spacing between items

    # Chevron - LARGER for visibility
    chevron_size: 16,                      # Larger chevron
    chevron_margin: 6                      # Space between chevron and text
  }

  @doc """
  Create a new SideNav state from initialization data.
  """
  def new(data) do
    theme = Map.merge(@default_theme, Map.get(data, :theme, %{}))
    tree = Map.get(data, :tree, [])

    # Build expanded set from data or from items marked as expanded
    initial_expanded = Map.get(data, :expanded, build_initial_expanded_set(tree))

    # Calculate item bounds to determine content height
    item_bounds = calculate_item_bounds(tree, theme, initial_expanded)
    content_height = calculate_content_height(item_bounds)

    %__MODULE__{
      frame: data.frame,
      tree: tree,
      active_id: Map.get(data, :active_id),
      focused_id: Map.get(data, :focused_id),
      expanded: initial_expanded,
      scroll: init_scroll(data.frame, content_height: content_height),
      theme: theme,
      item_bounds: item_bounds
    }
  end

  @doc """
  Calculate total content height from item bounds.
  """
  def calculate_content_height(item_bounds) when map_size(item_bounds) == 0, do: 0
  def calculate_content_height(item_bounds) do
    item_bounds
    |> Map.values()
    |> Enum.map(fn bounds -> bounds.y + bounds.height end)
    |> Enum.max()
  end

  # Build expanded set from items that have expanded: true
  defp build_initial_expanded_set(tree) do
    collect_expanded_items(tree, MapSet.new())
  end

  defp collect_expanded_items([], acc), do: acc
  defp collect_expanded_items([item | rest], acc) do
    item_id = Item.get_id(item)

    # Add this item to expanded set if it's marked as expanded
    acc = if Item.is_expanded?(item) do
      MapSet.put(acc, item_id)
    else
      acc
    end

    # Recursively check children
    acc = if Item.has_children?(item) do
      collect_expanded_items(Item.get_children(item), acc)
    else
      acc
    end

    collect_expanded_items(rest, acc)
  end

  @doc """
  Calculate bounds for all visible items in the tree.
  This enables fast hit-testing for mouse clicks.

  Only visible items (not hidden by collapsed parents) get bounds.
  """
  def calculate_item_bounds(tree, theme, expanded_set) do
    item_height = theme.item_height
    indent = theme.indent

    {bounds, _final_y} = do_calculate_bounds(tree, 0, 0, item_height, indent, expanded_set, %{})
    bounds
  end

  # Recursive bounds calculation
  defp do_calculate_bounds([], _depth, y_offset, _item_height, _indent, _expanded, acc) do
    {acc, y_offset}
  end

  defp do_calculate_bounds([item | rest], depth, y_offset, item_height, indent, expanded, acc) do
    item_id = Item.get_id(item)

    # Calculate bounds for this item
    # Note: x is the INDENT position, not including padding_left
    # The full row starts at 0, but content starts at padding_left + indent
    x = depth * indent
    bounds = %{
      x: x,
      y: y_offset,
      width: 280 - x,  # Sidebar width minus indent
      height: item_height,
      depth: depth,
      has_children: Item.has_children?(item),
      expanded: MapSet.member?(expanded, item_id)
    }

    new_acc = Map.put(acc, item_id, bounds)
    next_y = y_offset + item_height

    # If this item has children and is expanded, process them
    {final_acc, final_y} = if Item.has_children?(item) and MapSet.member?(expanded, item_id) do
      children = Item.get_children(item)
      do_calculate_bounds(children, depth + 1, next_y, item_height, indent, expanded, new_acc)
    else
      {new_acc, next_y}
    end

    # Process remaining siblings
    do_calculate_bounds(rest, depth, final_y, item_height, indent, expanded, final_acc)
  end

  @doc """
  Toggle expansion state of a node.
  """
  def toggle_expanded(%__MODULE__{} = state, item_id) do
    new_expanded = if MapSet.member?(state.expanded, item_id) do
      MapSet.delete(state.expanded, item_id)
    else
      MapSet.put(state.expanded, item_id)
    end

    # Recalculate bounds with new expansion state
    new_bounds = calculate_item_bounds(state.tree, state.theme, new_expanded)
    content_height = calculate_content_height(new_bounds)
    new_scroll = update_content_size(state.scroll, state.frame.size.width, content_height)

    %{state | expanded: new_expanded, item_bounds: new_bounds, scroll: new_scroll}
  end

  @doc """
  Set a node as expanded.
  """
  def expand(%__MODULE__{} = state, item_id) do
    if MapSet.member?(state.expanded, item_id) do
      state
    else
      new_expanded = MapSet.put(state.expanded, item_id)
      new_bounds = calculate_item_bounds(state.tree, state.theme, new_expanded)
      content_height = calculate_content_height(new_bounds)
      new_scroll = update_content_size(state.scroll, state.frame.size.width, content_height)
      %{state | expanded: new_expanded, item_bounds: new_bounds, scroll: new_scroll}
    end
  end

  @doc """
  Set a node as collapsed.
  """
  def collapse(%__MODULE__{} = state, item_id) do
    if MapSet.member?(state.expanded, item_id) do
      new_expanded = MapSet.delete(state.expanded, item_id)
      new_bounds = calculate_item_bounds(state.tree, state.theme, new_expanded)
      content_height = calculate_content_height(new_bounds)
      new_scroll = update_content_size(state.scroll, state.frame.size.width, content_height)
      %{state | expanded: new_expanded, item_bounds: new_bounds, scroll: new_scroll}
    else
      state
    end
  end

  @doc """
  Set the active (selected) item.
  Automatically expands ancestors to make it visible.
  """
  def set_active(%__MODULE__{} = state, item_id) do
    # Find all ancestors and expand them
    ancestors = find_ancestors(state.tree, item_id, [])
    new_expanded = Enum.reduce(ancestors, state.expanded, fn ancestor_id, acc ->
      MapSet.put(acc, ancestor_id)
    end)

    new_bounds = calculate_item_bounds(state.tree, state.theme, new_expanded)
    content_height = calculate_content_height(new_bounds)
    new_scroll = update_content_size(state.scroll, state.frame.size.width, content_height)

    %{state | active_id: item_id, expanded: new_expanded, item_bounds: new_bounds, scroll: new_scroll}
  end

  @doc """
  Set the focused item (for keyboard navigation).
  """
  def set_focused(%__MODULE__{} = state, item_id) do
    %{state | focused_id: item_id}
  end

  @doc """
  Find which item (if any) is at the given coordinates.
  Returns {item_id, :chevron | :text} if hit, nil otherwise.
  """
  def hit_test(%__MODULE__{} = state, {x, y}) do
    # Adjust y for scroll offset
    adjusted_y = y + state.scroll.offset_y
    theme = state.theme

    Enum.find_value(state.item_bounds, fn {item_id, bounds} ->
      # Row spans full width, starting at x=0
      # Content starts at padding_left + depth * indent
      row_left = 0
      row_right = state.frame.size.width

      if x >= row_left && x <= row_right &&
         adjusted_y >= bounds.y && adjusted_y <= bounds.y + bounds.height do

        # Calculate content positions (matching render_item)
        indent_x = theme.padding_left + (bounds.depth * theme.indent)
        chevron_area_width = theme.chevron_size + theme.chevron_margin

        # Determine if click is on chevron or text
        hit_region = if bounds.has_children do
          chevron_right = indent_x + chevron_area_width
          if x >= indent_x && x <= chevron_right do
            :chevron
          else
            :text
          end
        else
          :text
        end

        {item_id, hit_region}
      else
        nil
      end
    end)
  end

  @doc """
  Get list of all visible item IDs (respecting collapsed parents).
  Used for keyboard navigation.
  """
  def visible_items(%__MODULE__{} = state) do
    state.item_bounds
    |> Map.keys()
    |> Enum.sort_by(fn id ->
      bounds = Map.get(state.item_bounds, id)
      bounds.y
    end)
  end

  @doc """
  Get the next visible item after the given ID.
  """
  def next_item(%__MODULE__{} = state, current_id) do
    visible = visible_items(state)
    current_index = Enum.find_index(visible, &(&1 == current_id))

    if current_index && current_index < length(visible) - 1 do
      Enum.at(visible, current_index + 1)
    else
      nil
    end
  end

  @doc """
  Get the previous visible item before the given ID.
  """
  def prev_item(%__MODULE__{} = state, current_id) do
    visible = visible_items(state)
    current_index = Enum.find_index(visible, &(&1 == current_id))

    if current_index && current_index > 0 do
      Enum.at(visible, current_index - 1)
    else
      nil
    end
  end

  # Helper: Find all ancestor IDs of an item
  defp find_ancestors(tree, target_id, path) do
    do_find_ancestors(tree, target_id, path, [])
  end

  defp do_find_ancestors([], _target_id, _path, _ancestors), do: nil

  defp do_find_ancestors([item | rest], target_id, path, ancestors) do
    item_id = Item.get_id(item)

    cond do
      item_id == target_id ->
        # Found it! Return the path
        ancestors

      Item.has_children?(item) ->
        # Search in children, adding this item to the path
        children = Item.get_children(item)
        case do_find_ancestors(children, target_id, [item_id | path], [item_id | ancestors]) do
          nil -> do_find_ancestors(rest, target_id, path, ancestors)
          result -> result
        end

      true ->
        # Not this item, try siblings
        do_find_ancestors(rest, target_id, path, ancestors)
    end
  end
end
