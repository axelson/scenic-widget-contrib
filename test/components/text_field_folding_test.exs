defmodule ScenicWidgets.TextField.FoldingTest do
  use ExUnit.Case, async: true
  alias ScenicWidgets.TextField.Folding
  alias ScenicWidgets.TextField.{Reducer, Renderer, State}
  alias Widgex.{Frame}
  alias Widgex.Scroll.ScrollState

  @lines ["defmodule A do", "  def x do", "    :ok", "  end", "end", "tail"]

  test "indentation defines a fold and projection retains the header" do
    assert Folding.foldable?(@lines, 1)

    assert Folding.projection(@lines, MapSet.new([1])) == [
             {1, "defmodule A do", 3},
             {5, "end", 0},
             {6, "tail", 0}
           ]
  end

  test "toggle, unfold-all, and fold-to-level are deterministic" do
    assert Folding.toggle(@lines, MapSet.new(), 1) == MapSet.new([1])
    assert Folding.unfold_all() == MapSet.new()
    assert MapSet.member?(Folding.fold_to_level(@lines, 2), 1)
  end

  test "navigation expands containing folds and line-count edits clear them" do
    assert Folding.expand_to_line(@lines, MapSet.new([1]), 3) == MapSet.new()
    assert Folding.reconcile_after_edit(MapSet.new([1]), @lines, @lines) == MapSet.new([1])

    assert Folding.reconcile_after_edit(MapSet.new([1]), @lines, @lines ++ ["new"]) ==
             MapSet.new()
  end

  test "TextField actions and source/display mapping consume fold state" do
    frame = Frame.new(%{pin: {0, 0}, size: {500, 300}})

    state = %State{
      id: :editor,
      frame: frame,
      lines: @lines,
      folds: MapSet.new(),
      wrap_mode: :none,
      scroll: ScrollState.new(frame),
      font: %{size: 16}
    }

    assert {:event, {:folds_changed, :editor, [1]}, folded} =
             Reducer.process_action(state, {:toggle_fold, 1})

    assert Renderer.source_to_display_cursor(folded, {5, 1}) == {2, 1}
    assert Renderer.display_to_source_line(folded, 2) == 5

    assert {:event, {:folds_changed, :editor, []}, unfolded} =
             Reducer.process_action(folded, :unfold_all)

    assert unfolded.folds == MapSet.new()
  end
end
