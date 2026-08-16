defmodule ScenicWidgets.IconMenu.LayoutTest do
  use ExUnit.Case, async: true

  alias ScenicWidgets.IconMenu.State
  alias ScenicWidgets.IconMenu.Renderer
  alias ScenicWidgets.Menu.Model.{Item, Slider}
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

  test "slider rows are taller and render a label, value, track, and thumb" do
    slider = %Slider{id: :tab_width, label: "Tab Width", value: 4, min: 2, max: 12}
    state = state([slider, %Item{id: :after, label: "After"}])
    bounds = state.dropdown_bounds.file.items

    assert bounds.tab_width.height == state.theme.dropdown_slider_height
    assert bounds.after.y == bounds.tab_width.y + bounds.tab_width.height

    graph = Renderer.initial_render(Graph.build(), %{state | active_menu: :file})
    assert Graph.get!(graph, {:slider_label, :tab_width}).data == "Tab Width"
    assert Graph.get!(graph, {:slider_value, :tab_width}).data == "4"
    assert Graph.get!(graph, {:slider_track, :tab_width})
    assert Graph.get!(graph, {:slider_thumb, :tab_width})
  end
end
