defmodule ScenicWidgets.TextField.WordMotionsTest do
  use ExUnit.Case, async: true

  alias ScenicWidgets.TextField.{Reducer, State}

  # State.word_motion_target/2 is the pure core of the emacs word motions (Alt-F/B/D):
  # given the cursor and buffer it returns the target {line, col}. It never touches the
  # font/render stack, so — unlike the reducer motions, which funnel through
  # ensure_cursor_visible/1 — it can be asserted directly and exhaustively here.
  describe "State.word_motion_target/2 (default word chars)" do
    # "foo.bar baz" — '.' and ' ' are separators, so there are three words.
    defp line_state(text, cursor), do: %State{lines: [text], cursor: cursor}

    test "forward-word stops just after each word" do
      s = "foo.bar baz"
      assert State.word_motion_target(line_state(s, {1, 1}), :word_right) == {1, 4}
      assert State.word_motion_target(line_state(s, {1, 4}), :word_right) == {1, 8}
      assert State.word_motion_target(line_state(s, {1, 8}), :word_right) == {1, 12}
    end

    test "backward-word stops at the start of each word" do
      s = "foo.bar baz"
      assert State.word_motion_target(line_state(s, {1, 12}), :word_left) == {1, 9}
      assert State.word_motion_target(line_state(s, {1, 9}), :word_left) == {1, 5}
      assert State.word_motion_target(line_state(s, {1, 5}), :word_left) == {1, 1}
    end

    test "forward from mid-word finishes the current word" do
      assert State.word_motion_target(line_state("hello world", {1, 3}), :word_right) == {1, 6}
    end

    test "backward from mid-word lands at the word start" do
      assert State.word_motion_target(line_state("hello world", {1, 3}), :word_left) == {1, 1}
    end

    test "forward is a no-op at end of document" do
      assert State.word_motion_target(line_state("foo", {1, 4}), :word_right) == {1, 4}
    end

    test "backward is a no-op at start of document" do
      assert State.word_motion_target(line_state("foo", {1, 1}), :word_left) == {1, 1}
    end

    test "underscore counts as a word char by default (foo_bar is one word)" do
      assert State.word_motion_target(line_state("foo_bar", {1, 1}), :word_right) == {1, 8}
    end
  end

  describe "State.word_motion_target/2 across lines" do
    test "forward crosses the newline into the next line's word" do
      state = %State{lines: ["foo", "bar"], cursor: {1, 4}}
      assert State.word_motion_target(state, :word_right) == {2, 4}
    end

    test "backward crosses the newline into the previous line's word" do
      state = %State{lines: ["foo", "bar"], cursor: {2, 1}}
      assert State.word_motion_target(state, :word_left) == {1, 1}
    end
  end

  describe "State.word_motion_target/2 with a custom :word_char_fun (the seam)" do
    test "an alphanumeric-only predicate splits on underscore" do
      # readline-style: '_' is NOT a word char, so foo_bar is two words.
      alnum = fn g -> g =~ ~r/[a-zA-Z0-9]/ end
      state = %State{lines: ["foo_bar"], cursor: {1, 1}, word_char_fun: alnum}

      assert State.word_motion_target(state, :word_right) == {1, 4}
    end
  end

  # Alt-D's path (push_undo -> delete_selection -> get_text) stays off the render stack,
  # so unlike the Alt-F/B motions it can be asserted end-to-end at the reducer level.
  describe "Alt+D kill-word" do
    test "deletes from the cursor through the next word, leaving the cursor put" do
      state = %State{focused: true, id: :ed, lines: ["foo bar baz"], cursor: {1, 1}, undo_stack: [], undo_max_size: 100}

      assert {:event, {:text_changed, :ed, " bar baz"}, new_state} =
               Reducer.process_input(state, {:key, {:key_d, 1, [:alt]}})

      assert new_state.cursor == {1, 1}
    end

    test "is undoable (pushes one undo snapshot)" do
      state = %State{focused: true, id: :ed, lines: ["foo bar"], cursor: {1, 1}, undo_stack: [], undo_max_size: 100}

      assert {:event, _, new_state} =
               Reducer.process_input(state, {:key, {:key_d, 1, [:alt]}})

      assert length(new_state.undo_stack) == 1
    end

    test "is a no-op at the end of the document (no undo entry)" do
      state = %State{focused: true, id: :ed, lines: ["foo"], cursor: {1, 4}, undo_stack: []}

      assert {:noop, ^state} =
               Reducer.process_input(state, {:key, {:key_d, 1, [:alt]}})
    end
  end

  # Alt-F/B route through move_cursor/2 -> State.ensure_cursor_visible/1, which needs a
  # real frame + loaded FontMetrics. So here we only assert dispatch: the clause matches
  # and drives a word motion (the resulting cursor math is covered exhaustively above).
  # The render-path error a frame-less test State triggers is tolerated, exactly like the
  # sibling ReducerTest does for the Ctrl motions.
  describe "Alt+F / Alt+B dispatch" do
    test "Alt+F and Alt+B are handled (not swallowed as a plain no-op)" do
      state = %State{focused: true, lines: ["foo bar"], cursor: {1, 1}}

      assert safe_process(state, {:key, {:key_f, 1, [:alt]}}) == :proceeded_to_motion
      assert safe_process(state, {:key, {:key_b, 1, [:alt]}}) == :proceeded_to_motion
    end
  end

  defp safe_process(state, input) do
    case Reducer.process_input(state, input) do
      {:noop, ^state} -> :unhandled
      other -> other
    end
  rescue
    _ -> :proceeded_to_motion
  end
end
