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

  test "shows scrollbars as soon as expansion makes the tree overflow" do
    children =
      for index <- 1..10 do
        %Item{id: "file-#{index}", title: "file-#{index}", type: :page}
      end

    directory = %Item{id: "dir", title: "dir", type: :group, children: children}
    state = State.new(%{frame: Frame.new(pin: {0, 0}, size: {200, 100}), tree: [directory]})

    refute state.scroll.scrollbar_visible
    assert state.scroll.scrollbar_opacity == 0

    expanded = State.toggle_expanded(state, "dir")

    assert expanded.scroll.content_height > expanded.scroll.viewport_height
    assert expanded.scroll.scrollbar_visible
    assert expanded.scroll.scrollbar_opacity == 255
  end

  test "plain, ctrl, and shift selection remain separate from the active item" do
    tree =
      for index <- 1..5 do
        %Item{id: "file-#{index}", title: "file-#{index}", type: :page}
      end

    state =
      State.new(%{
        frame: Frame.new(pin: {0, 0}, size: {200, 200}),
        tree: tree,
        active_id: "file-5"
      })

    one = State.select(state, "file-1")
    assert one.selected_ids == MapSet.new(["file-1"])
    assert one.active_id == "file-5"

    toggled = State.select(one, "file-3", [:ctrl])
    assert toggled.selected_ids == MapSet.new(["file-1", "file-3"])

    untoggled = State.select(toggled, "file-3", [:ctrl])
    assert untoggled.selected_ids == MapSet.new(["file-1"])

    anchored = State.select(one, "file-2")
    ranged = State.select(anchored, "file-4", [:shift])
    assert ranged.selected_ids == MapSet.new(["file-2", "file-3", "file-4"])
    assert ranged.active_id == "file-5"
  end

  test "active id may arrive before a refreshed tree contains it" do
    state =
      State.new(%{
        frame: Frame.new(pin: {0, 0}, size: {200, 200}),
        tree: [%Item{id: "old.txt", title: "old.txt", type: :page}]
      })

    updated = State.set_active(state, "renamed.txt")

    assert updated.active_id == "renamed.txt"
    assert updated.expanded == state.expanded
  end
end
