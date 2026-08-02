defmodule ScenicWidgets.TabBarOverflowTest do
  use ExUnit.Case, async: true

  alias ScenicWidgets.TabBar.{Reducer, State}

  test "driver scroll shape moves overflowing tabs horizontally" do
    state = state_with_tabs()
    assert {:noop, moved} = Reducer.process_input(state, {:cursor_scroll, {{0, -1}, {50, 10}}})
    assert moved.scroll_offset > 0
  end

  test "selecting an offscreen tab reveals it" do
    state = state_with_tabs()
    assert {:tab_selected, :c, selected} = Reducer.select_tab(state, :c)
    {x, _y, width, _height} = State.get_tab_bounds(selected, :c)
    assert x >= 0
    assert x + width <= selected.frame.size.width
  end

  defp state_with_tabs do
    frame = Widgex.Frame.new(pin: {0, 0}, size: {150, 35})

    State.new(%{
      frame: frame,
      tabs: [
        %{id: :a, label: "alpha", closeable: true},
        %{id: :b, label: "beta", closeable: true},
        %{id: :c, label: "gamma", closeable: true}
      ],
      selected_id: :a
    })
  end
end
