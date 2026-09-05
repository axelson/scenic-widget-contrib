defmodule ScenicWidgets.TextField.ReducerTest do
  use ExUnit.Case, async: true

  alias ScenicWidgets.TextField.{Reducer, State}

  # These tests stay off the render/font stack on purpose: any clause that moves the
  # cursor or edits text funnels through State.ensure_cursor_visible/1 and
  # update_scroll_content_size/1, which require loaded FontMetrics and a real frame.
  # So the emacs motions (Ctrl+A/E/B/F/P/N) and the editing kills (Ctrl+D/Ctrl+K) are
  # exercised by hand in the running app, not here. What we CAN assert purely is the
  # macOS modifier remap: that the app shortcuts now fire on Cmd (:meta) rather than
  # Ctrl, since Ctrl is reserved for the emacs motions.

  describe "app shortcuts on Cmd (:meta)" do
    test "Cmd+A selects all" do
      state = %State{focused: true, lines: ["hello", "world"], cursor: {1, 1}}

      assert {:noop, new_state} =
               Reducer.process_input(state, {:key, {:key_a, 1, [:meta]}})

      assert new_state.selection == {{1, 1}, {2, 6}}
    end

    test "Cmd+S emits a save request" do
      state = %State{focused: true, id: :ed, lines: ["hello"], cursor: {1, 1}}

      assert {:event, {:save_requested, :ed, "hello"}, ^state} =
               Reducer.process_input(state, {:key, {:key_s, 1, [:meta]}})
    end

    test "Cmd+V requests a paste" do
      state = %State{focused: true, id: :ed, lines: ["hello"], cursor: {1, 1}}

      assert {:event, {:clipboard_paste_requested, :ed}, ^state} =
               Reducer.process_input(state, {:key, {:key_v, 1, [:meta]}})
    end

    test "Cmd+C copies the current selection" do
      state = %State{
        focused: true,
        id: :ed,
        lines: ["hello"],
        cursor: {1, 3},
        selection: {{1, 1}, {1, 3}}
      }

      assert {:event, {:clipboard_copy, :ed, "he"}, ^state} =
               Reducer.process_input(state, {:key, {:key_c, 1, [:meta]}})
    end

    test "Cmd+C with no selection is a no-op" do
      state = %State{focused: true, id: :ed, lines: ["hello"], cursor: {1, 1}, selection: nil}

      assert {:noop, ^state} =
               Reducer.process_input(state, {:key, {:key_c, 1, [:meta]}})
    end

    test "Cmd+F emits a find request" do
      state = %State{focused: true, id: :ed, lines: ["hello"], cursor: {1, 1}}

      assert {:event, {:find_requested, :ed}, ^state} =
               Reducer.process_input(state, {:key, {:key_f, 1, [:meta]}})
    end

    test "Cmd+Z routes to undo (no-op on an empty undo stack)" do
      state = %State{focused: true, lines: ["hello"], cursor: {1, 1}, undo_stack: [], redo_stack: []}

      assert {:noop, ^state} =
               Reducer.process_input(state, {:key, {:key_z, 1, [:meta]}})
    end

    test "Cmd+Shift+Z routes to redo (no-op on an empty redo stack), order-independent mods" do
      state = %State{focused: true, lines: ["hello"], cursor: {1, 1}, undo_stack: [], redo_stack: []}

      assert {:noop, ^state} =
               Reducer.process_input(state, {:key, {:key_z, 1, [:shift, :meta]}})
    end
  end

  describe "direct-mode codepoint guard" do
    test "command-modified codepoints are dropped, never inserted" do
      state = %State{focused: true, lines: ["hi"], cursor: {1, 3}}

      for modifier <- [[:ctrl], [:meta], [:super], [:ctrl, :shift]] do
        assert {:noop, ^state} =
                 Reducer.process_input(state, {:codepoint, {"a", modifier}})
      end
    end

    test "an unmodified codepoint is not dropped by the command-mod guard" do
      # It falls through to the insert path rather than short-circuiting to
      # {:noop, state}. (The full insert is exercised by the running app; here
      # we only assert the guard does not swallow a plain character, keeping the
      # test off the render stack that insert_char/2 pulls in.)
      state = %State{focused: true, lines: ["hi"], cursor: {1, 3}}

      refute match?({:noop, ^state}, safe_process(state, {:codepoint, {"a", []}}))
    end
  end

  # Runs process_input but tolerates the render-path RuntimeError that a bare
  # (frame-less) test State triggers once insertion proceeds — we only care that
  # the guard let the input through rather than returning {:noop, state}.
  defp safe_process(state, input) do
    Reducer.process_input(state, input)
  rescue
    _ -> :proceeded_to_insert
  end
end
