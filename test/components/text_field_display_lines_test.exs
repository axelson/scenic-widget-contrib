defmodule ScenicWidgets.TextField.DisplayLinesTest do
  use ExUnit.Case, async: true

  alias ScenicWidgets.TextField.DisplayLines

  # A monospace stand-in: every grapheme is 10px wide. max_width 100 => 10 cols/row.
  # This keeps the wrapping math easy to reason about without loading font metrics.
  @max 100

  defp measure(s), do: String.length(s) * 10

  defp compute(lines, wrap_mode \\ :word),
    do: DisplayLines.compute(lines, &measure/1, @max, wrap_mode)

  describe "compute/4 wrapping" do
    test "a short line is a single row" do
      dl = compute(["hello"])
      assert dl.rows == ["hello"]
      assert [%{source_line: 1, first_of_source?: true, source_col_start: 1}] = dl.meta
    end

    test "an empty line is a single empty row" do
      dl = compute([""])
      assert dl.rows == [""]
    end

    test "a long line wraps into rows with correct source columns" do
      # "aaaa bbbb cccc" is 14 chars; cols: a=1..4, sp=5, b=6..9, sp=10, c=11..14.
      dl = compute(["aaaa bbbb cccc"])
      assert dl.rows == ["aaaa bbbb", "cccc"]

      assert [
               %{source_line: 1, first_of_source?: true, source_col_start: 1},
               %{source_line: 1, first_of_source?: false, source_col_start: 11}
             ] = dl.meta
    end

    test ":none never wraps" do
      long = String.duplicate("x", 50)
      dl = compute([long], :none)
      assert dl.rows == [long]
    end

    test ":char wrap splits at the width with no consumed characters" do
      dl = compute([String.duplicate("x", 25)], :char)
      assert dl.rows == [String.duplicate("x", 10), String.duplicate("x", 10), String.duplicate("x", 5)]
      # No space is consumed, so row starts advance by exactly the row length.
      assert Enum.map(dl.meta, & &1.source_col_start) == [1, 11, 21]
    end

    test "multiple source lines are numbered across wrapped rows" do
      dl = compute(["short", "aaaa bbbb cccc"])
      assert dl.rows == ["short", "aaaa bbbb", "cccc"]
      assert Enum.map(dl.meta, & &1.source_line) == [1, 2, 2]
    end
  end

  describe "source_to_display/2 and display_to_source/2 round-trip" do
    test "round-trips across a wrapped line at every column" do
      dl = compute(["aaaa bbbb cccc"])

      for col <- 1..15 do
        rt = dl |> DisplayLines.source_to_display({1, col}) |> then(&DisplayLines.display_to_source(dl, &1))
        assert rt == {1, col}, "column #{col} did not round-trip (got #{inspect(rt)})"
      end
    end

    test "a column at the wrap boundary lands at the end of the earlier row" do
      dl = compute(["aaaa bbbb cccc"])
      # col 10 is the consumed space between "bbbb" and "cccc": end of row 1.
      assert DisplayLines.source_to_display(dl, {1, 10}) == {1, 10}
    end

    test "start of the continuation row maps to its first source column" do
      dl = compute(["aaaa bbbb cccc"])
      assert DisplayLines.source_to_display(dl, {1, 11}) == {2, 1}
      assert DisplayLines.display_to_source(dl, {2, 1}) == {1, 11}
    end
  end

  describe "display_to_source/2 clamping" do
    test "a row past the end clamps to the last row" do
      dl = compute(["aaaa bbbb cccc"])
      assert {1, source_col} = DisplayLines.display_to_source(dl, {99, 1})
      assert source_col == 11
    end

    test "a column past the end of a row clamps to that row's end" do
      dl = compute(["aaaa bbbb cccc"])
      # row 2 "cccc" is 4 chars; col 99 clamps to end (source col 15 = after last char).
      assert DisplayLines.display_to_source(dl, {2, 99}) == {1, 15}
    end
  end

  describe "goal column helpers" do
    test "x_of measures the row text before the column" do
      dl = compute(["aaaa bbbb cccc"])
      # Row 2 is "cccc"; before col 3 is "cc" => 20px.
      assert DisplayLines.x_of(dl, {2, 3}) == 20
    end

    test "col_at_x lands on the nearest column, snapping within a character" do
      dl = compute(["aaaa bbbb cccc"])
      assert DisplayLines.col_at_x(dl, 2, 0) == 1
      # 24px is past the middle of the third char (20..30, mid 25? 24<25) => col 3.
      assert DisplayLines.col_at_x(dl, 2, 24) == 3
      # 26px is past the middle => col 4.
      assert DisplayLines.col_at_x(dl, 2, 26) == 4
      # Far right clamps to end of "cccc".
      assert DisplayLines.col_at_x(dl, 2, 999) == 5
    end

    test "vertical move preserves goal x through a shorter row" do
      # Row 0 long, row 1 short, row 2 long: moving down through the short row and
      # on should return to the original x.
      dl = compute(["xxxxxxxx", "ab", "yyyyyyyy"], :none)
      goal = DisplayLines.x_of(dl, {1, 6})
      assert goal == 50

      # Landing on the short middle row clamps to its end...
      mid_col = DisplayLines.col_at_x(dl, 2, goal)
      assert mid_col == 3

      # ...but landing on the third row from the same goal x returns to col 6.
      bottom_col = DisplayLines.col_at_x(dl, 3, goal)
      assert bottom_col == 6
    end
  end
end
