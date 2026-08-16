defmodule ScenicWidgets.IconMenu.LayoutTest do
  use ExUnit.Case, async: true

  alias ScenicWidgets.IconMenu.State
  alias ScenicWidgets.IconMenu.Renderer
  alias ScenicWidgets.Menu.Model.Item
  alias Scenic.{Graph, Primitive}
  alias Widgex.Frame

  defp state(items, theme \\ %{}) do
    State.new(%{
      frame: Frame.new(pin: {0, 0}, size: {800, 35}),
      align: :left,
      menus: [%{id: :file, icon: :file, items: items}],
      theme: theme
    })
  end

  test "dropdown width grows to fit independent label and shortcut columns" do
    short = state([%Item{id: :save, label: "Save", shortcut: "Ctrl+S"}])

    long =
      state([
        %Item{
          id: :save_as,
          label: "Save a Copy in Another Location",
          shortcut: "Ctrl+Shift+Alt+S"
        }
      ])

    assert long.dropdown_bounds.file.width > short.dropdown_bounds.file.width
    assert short.dropdown_bounds.file.width >= short.theme.dropdown_width
  end

  test "content sizing is capped by dropdown_max_width" do
    state =
      state(
        [
          %Item{
            id: :long,
            label: String.duplicate("very long label ", 20),
            shortcut: "Ctrl+Shift+S"
          }
        ],
        %{dropdown_max_width: 240}
      )

    assert state.dropdown_bounds.file.width == 240
  end

  test "shortcut remains separate from the display label" do
    item = %Item{id: :save, label: "Save As…", shortcut: "Ctrl+Shift+S"}

    assert State.display_label(item) == "Save As…"
    assert State.item_shortcut(item) == "Ctrl+Shift+S"
  end

  test "renderer right-aligns every shortcut on the same column" do
    state =
      state([
        %Item{id: :save, label: "Save", shortcut: "Ctrl+S"},
        %Item{id: :save_as, label: "Save As…", shortcut: "Ctrl+Shift+S"}
      ])

    graph = Renderer.initial_render(Graph.build(), %{state | active_menu: :file})
    first = Graph.get!(graph, {:item_shortcut, :save})
    second = Graph.get!(graph, {:item_shortcut, :save_as})

    assert Primitive.get_style(first, :text_align) == :right
    assert Primitive.get_style(second, :text_align) == :right

    assert Primitive.get_transform(first, :translate) ==
             Primitive.get_transform(second, :translate)
  end

  test "renderer truncates an extreme shortcut at the configured width cap" do
    shortcut = String.duplicate("Ctrl+Shift+", 12) <> "S"

    state =
      state(
        [%Item{id: :extreme, label: "Run", shortcut: shortcut}],
        %{dropdown_max_width: 220}
      )

    graph = Renderer.initial_render(Graph.build(), %{state | active_menu: :file})
    primitive = Graph.get!(graph, {:item_shortcut, :extreme})

    assert primitive.data != shortcut
    assert String.ends_with?(primitive.data, "…")
    assert Primitive.get_style(primitive, :text_align) == :right
  end
end
