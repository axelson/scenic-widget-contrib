defmodule ScenicWidgets.TextField.ReducerTest do
  use ExUnit.Case, async: true

  alias ScenicWidgets.TextField.{Reducer, State}

  describe "normalize_command_key/2 (macOS Cmd -> Ctrl)" do
    test "on macOS, :meta is rewritten to :ctrl for key events" do
      assert {:key, {:key_a, 1, [:ctrl]}} =
               Reducer.normalize_command_key({:key, {:key_a, 1, [:meta]}}, true)
    end

    test "on macOS, other modifiers are preserved (Cmd+Shift+Z -> Ctrl+Shift+Z)" do
      assert {:key, {:key_z, 1, [:ctrl, :shift]}} =
               Reducer.normalize_command_key({:key, {:key_z, 1, [:meta, :shift]}}, true)
    end

    test "a genuine Ctrl chord is never altered" do
      input = {:key, {:key_a, 1, [:ctrl]}}
      assert ^input = Reducer.normalize_command_key(input, true)
    end

    test "off macOS, :meta is left alone so the Super/Windows key stays inert" do
      input = {:key, {:key_a, 1, [:meta]}}
      assert ^input = Reducer.normalize_command_key(input, false)
    end

    test "non-key events pass through untouched on either platform" do
      input = {:codepoint, {"a", []}}
      assert ^input = Reducer.normalize_command_key(input, true)
      assert ^input = Reducer.normalize_command_key(input, false)
    end

    test "a normalized Cmd+A drives direct-mode select-all" do
      state = %State{focused: true, lines: ["hello", "world"], cursor: {1, 1}}

      input = Reducer.normalize_command_key({:key, {:key_a, 1, [:meta]}}, true)
      assert {:noop, new_state} = Reducer.process_input(state, input)
      assert new_state.selection == {{1, 1}, {2, 6}}
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
