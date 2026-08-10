defmodule ScenicWidgets.SideNav.StateTest do
  use ExUnit.Case, async: true

  alias ScenicWidgets.SideNav.{Item, State}
  alias Widgex.Frame

  test "reserves bottom clearance only when horizontal scrolling is present" do
    item = %Item{id: "wide", title: String.duplicate("wide ", 20), type: :page}

    narrow_state = State.new(%{frame: Frame.new(pin: {0, 0}, size: {100, 100}), tree: [item]})
    wide_state = State.new(%{frame: Frame.new(pin: {0, 0}, size: {1_000, 100}), tree: [item]})

    assert narrow_state.scroll.content_width > narrow_state.scroll.viewport_width
    assert narrow_state.scroll.content_height == 48

    assert wide_state.scroll.content_width <= wide_state.scroll.viewport_width
    assert wide_state.scroll.content_height == 28
  end
end
