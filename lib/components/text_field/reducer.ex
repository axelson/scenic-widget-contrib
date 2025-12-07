defmodule ScenicWidgets.TextField.Reducer do
  @moduledoc """
  Pure state transition functions for TextField.

  Phase 2: Input handling (process_input/2)
  Phase 3: External actions (process_action/2)
  Phase 2: Input handling using ScenicEventsDefinitions
  Handles :key events and converts them to text using key2string/1

  Returns:
  - {:noop, state} - State changed, no parent notification needed
  - {:event, event_data, state} - State changed, notify parent
  """

  alias ScenicWidgets.TextField.State
  use ScenicWidgets.ScenicEventsDefinitions
  use Widgex.Scrollable

  # ===== DIRECT INPUT PROCESSING =====

  @doc """
  Process raw Scenic input events (for direct input mode).
  Uses ScenicEventsDefinitions for key matching and conversion.
  """

  # ===== TEXT INPUT - Codepoint events ONLY =====

  # Handle codepoint events (direct character input from driver)
  # Codepoint is a string (single UTF-8 character)
  # NOTE: We ONLY handle codepoint events for text input to avoid duplicate insertions.
  # When a user presses a letter key, Scenic sends BOTH :codepoint and :key events.
  # We use :codepoint for text input and :key only for non-character keys (arrows, backspace, etc.)
  def process_input(%State{focused: true} = state, {:codepoint, {char, _mods}}) when is_bitstring(char) do
    # Delete selection first if any, then insert
    state_after_delete = delete_selection(state)
    new_state = insert_char(state_after_delete, char)
    {:event, {:text_changed, state.id, State.get_text(new_state)}, new_state}
  end

  # ===== TEXT INPUT - Using key2string conversion =====
  # REMOVED: We no longer handle text input via :key events to avoid duplicate insertions
  # See codepoint handler above - that's the only way text gets inserted now

  # # Handle all valid text input characters (letters, numbers, punctuation, space, enter)
  # def process_input(%State{focused: true} = state, input) when input in @valid_text_input_characters do
  #   char = key2string(input)
  #   # IO.puts("🔍 TEXT INPUT: '#{char}', selection: #{inspect(state.selection)}")
  #   # Delete selection first if any, then insert
  #   state_after_delete = delete_selection(state)
  #   # IO.puts("🔍 After delete_selection: cursor #{inspect(state_after_delete.cursor)}, lines: #{inspect(state_after_delete.lines)}")
  #   new_state = insert_char(state_after_delete, char)
  #   {:event, {:text_changed, state.id, State.get_text(new_state)}, new_state}
  # end

  # ===== SPECIAL KEYS =====

  # Enter key - insert newline (doesn't send codepoint event, only key event)
  def process_input(%State{focused: true, mode: :multi_line} = state, {:key, {:key_enter, key_state, _mods}}) when key_state > 0 do
    # key_state > 0 matches both press (1) and repeat (2) events
    state_after_delete = delete_selection(state)
    new_state = insert_char(state_after_delete, "\n")
    {:event, {:text_changed, state.id, State.get_text(new_state)}, new_state}
  end

  # Backspace - delete selection or character before cursor
  # key_state > 0 matches both press (1) and repeat (2) for key-hold functionality
  def process_input(%State{focused: true, selection: selection} = state, {:key, {:key_backspace, key_state, _mods}}) when selection != nil and key_state > 0 do
    new_state = delete_selection(state)
    # IO.puts("🔍 Backspace with selection: focused before=#{state.focused}, after=#{new_state.focused}")
    {:event, {:text_changed, state.id, State.get_text(new_state)}, new_state}
  end

  def process_input(%State{focused: true} = state, {:key, {:key_backspace, key_state, _mods}}) when key_state > 0 do
    new_state = delete_before_cursor(state)
    {:event, {:text_changed, state.id, State.get_text(new_state)}, new_state}
  end

  # Delete - delete selection or character at cursor
  # key_state > 0 matches both press (1) and repeat (2) for key-hold functionality
  def process_input(%State{focused: true, selection: selection} = state, {:key, {:key_delete, key_state, _mods}}) when selection != nil and key_state > 0 do
    new_state = delete_selection(state)
    {:event, {:text_changed, state.id, State.get_text(new_state)}, new_state}
  end

  def process_input(%State{focused: true} = state, {:key, {:key_delete, key_state, _mods}}) when key_state > 0 do
    new_state = delete_at_cursor(state)
    {:event, {:text_changed, state.id, State.get_text(new_state)}, new_state}
  end

  # Arrow keys with Shift - text selection
  # key_state > 0 matches both press (1) and repeat (2) for key-hold functionality
  def process_input(%State{focused: true} = state, {:key, {:key_left, key_state, mods}}) when key_state > 0 do
    if :shift in mods do
      {:noop, move_cursor_with_selection(state, :left)}
    else
      {:noop, move_cursor(state, :left) |> clear_selection()}
    end
  end

  def process_input(%State{focused: true} = state, {:key, {:key_right, key_state, mods}}) when key_state > 0 do
    if :shift in mods do
      {:noop, move_cursor_with_selection(state, :right)}
    else
      {:noop, move_cursor(state, :right) |> clear_selection()}
    end
  end

  def process_input(%State{focused: true} = state, {:key, {:key_up, key_state, mods}}) when key_state > 0 do
    if :shift in mods do
      {:noop, move_cursor_with_selection(state, :up)}
    else
      {:noop, move_cursor(state, :up) |> clear_selection()}
    end
  end

  def process_input(%State{focused: true} = state, {:key, {:key_down, key_state, mods}}) when key_state > 0 do
    if :shift in mods do
      # IO.puts("🔍 Shift+Down pressed! Current cursor: #{inspect(state.cursor)}, selection: #{inspect(state.selection)}, lines: #{length(state.lines)}")
      # IO.puts("🔍 Lines content: #{inspect(state.lines)}")
      new_state = move_cursor_with_selection(state, :down)
      # IO.puts("🔍 After Shift+Down: cursor: #{inspect(new_state.cursor)}, selection: #{inspect(new_state.selection)}")
      {:noop, new_state}
    else
      {:noop, move_cursor(state, :down) |> clear_selection()}
    end
  end

  # Home/End keys
  def process_input(%State{focused: true} = state, @home_key) do
    {:noop, state |> move_cursor(:line_start) |> clear_selection()}
  end

  def process_input(%State{focused: true} = state, @end_key) do
    {:noop, state |> move_cursor(:line_end) |> clear_selection()}
  end

  # Escape - clear focus (optionally)
  def process_input(%State{focused: true} = state, @escape_key) do
    # IO.puts("🔍 Focus lost: Escape pressed")
    {:event, {:focus_lost, state.id}, %{state | focused: false}}
  end

  # ===== KEYBOARD SHORTCUTS =====

  # Ctrl+A - Select all
  def process_input(%State{focused: true} = state, @ctrl_a) do
    # IO.puts("🔍 Ctrl+A pressed! Focused: #{state.focused}")
    {:noop, select_all(state)}
  end

  # Ctrl+C - Copy selection to clipboard (works even when unfocused)
  def process_input(%State{selection: selection} = state, @ctrl_c) when selection != nil do
    text = get_selected_text(state)
    # IO.puts("🔍 Ctrl+C pressed! Selection: #{inspect(selection)}, Text: #{inspect(text)}, Focused: #{state.focused}")
    # Send clipboard event to parent (Scenic doesn't have system clipboard access)
    {:event, {:clipboard_copy, state.id, text}, state}
  end

  def process_input(%State{} = state, @ctrl_c) do
    # No selection - do nothing
    # IO.puts("🔍 Ctrl+C pressed but no selection (focused: #{state.focused})")
    {:noop, state}
  end

  # Ctrl+X - Cut selection to clipboard (works even when unfocused)
  def process_input(%State{selection: selection} = state, @ctrl_x) when selection != nil do
    text = get_selected_text(state)
    new_state = delete_selection(state)
    # IO.puts("🔍 Ctrl+X pressed! Focused: #{state.focused}")
    # Send clipboard event to parent
    {:event, {:clipboard_cut, state.id, text}, new_state}
  end

  def process_input(%State{} = state, @ctrl_x) do
    # No selection - do nothing
    {:noop, state}
  end

  # Ctrl+V - Paste from clipboard (works even when unfocused for testing)
  def process_input(%State{} = state, @ctrl_v) do
    # IO.puts("🔍 Ctrl+V pressed! Focused: #{state.focused}")
    # Emit event to request clipboard data from parent
    # Parent will call insert_text action with the clipboard content
    {:event, {:clipboard_paste_requested, state.id}, state}
  end

  # Ctrl+S - Save (emit event for parent to handle)
  def process_input(%State{focused: true} = state, @ctrl_s) do
    {:event, {:save_requested, state.id, State.get_text(state)}, state}
  end

  # ===== SHIFT KEY TRACKING (for Shift+scroll horizontal scrolling) =====
  # NOTE: These MUST come BEFORE the key release catch-all so shift release is tracked

  # Track Shift key press - both left and right shift
  def process_input(%State{scroll: scroll} = state, {:key, {:key_leftshift, 1, _}}) do
    IO.puts("🔑 SHIFT PRESSED (left)")
    {:noop, %{state | scroll: set_scroll_shift(scroll, true)}}
  end

  def process_input(%State{scroll: scroll} = state, {:key, {:key_rightshift, 1, _}}) do
    IO.puts("🔑 SHIFT PRESSED (right)")
    {:noop, %{state | scroll: set_scroll_shift(scroll, true)}}
  end

  # Track Shift key release
  def process_input(%State{scroll: scroll} = state, {:key, {:key_leftshift, 0, _}}) do
    IO.puts("🔑 SHIFT RELEASED (left)")
    {:noop, %{state | scroll: set_scroll_shift(scroll, false)}}
  end

  def process_input(%State{scroll: scroll} = state, {:key, {:key_rightshift, 0, _}}) do
    IO.puts("🔑 SHIFT RELEASED (right)")
    {:noop, %{state | scroll: set_scroll_shift(scroll, false)}}
  end

  # ===== KEY RELEASE EVENTS - Ignore all others =====

  # Ignore other key release events (state: 0)
  def process_input(state, {:key, {_key, @key_released, _mods}}) do
    {:noop, state}
  end

  # ===== UNFOCUSED - Ignore all other keyboard input =====

  def process_input(%State{focused: false} = state, {:key, _}) do
    {:noop, state}
  end

  # ===== SCROLL INPUT =====

  # Handle scroll input with smart Shift+scroll support
  def process_input(%State{} = state, {:cursor_scroll, {{dx, dy}, {_x, _y}}}) do
    handle_scroll_input_smart(state, dx, dy)
  end

  def process_input(%State{} = state, {:cursor_scroll, {dx, dy, _x, _y}}) do
    handle_scroll_input_smart(state, dx, dy)
  end

  # ===== CLICK TO FOCUS =====

  # Click inside -> gain focus
  def process_input(%State{focused: false} = state, {:cursor_button, {:btn_left, 1, _, pos}}) do
    inside = State.point_inside?(state, pos)
    # IO.puts("🔍 Click at #{inspect(pos)}, inside=#{inside}, frame=#{inspect(state.frame)}")
    if inside do
      # IO.puts("🔍 Focus gained: Click inside at #{inspect(pos)}")
      {:event, {:focus_gained, state.id}, %{state | focused: true}}
    else
      # IO.puts("🔍 Click missed TextField at #{inspect(pos)}")
      {:noop, state}
    end
  end

  # Click outside -> lose focus
  def process_input(%State{focused: true} = state, {:cursor_button, {:btn_left, 1, _, pos}}) do
    if State.point_inside?(state, pos) do
      # Click inside while focused - move cursor to click position (Phase 3)
      {:noop, state}
    else
      # IO.puts("🔍 Focus lost: Click outside at #{inspect(pos)}")
      {:event, {:focus_lost, state.id}, %{state | focused: false}}
    end
  end

  # ===== FALLBACK - Unhandled input =====

  def process_input(state, {:key, {:key_v, 1, [:ctrl]}} = _input) do
    # Fallback for Ctrl+V if not caught above
    {:noop, state}
  end

  # Catch-all for unhandled input
  def process_input(state, _input) do
    {:noop, state}
  end

  # ===== EXTERNAL ACTION PROCESSING (Phase 3) =====

  @doc """
  Process high-level actions (for external control mode).
  Phase 3 implementation.
  """
  def process_action(state, {:insert_text, text}) do
    # Delete selection if any, then insert text
    state_after_delete = delete_selection(state)
    new_state = insert_text_at_cursor(state_after_delete, text)
    {:event, {:text_changed, state.id, State.get_text(new_state)}, new_state}
  end

  def process_action(state, _action) do
    {:noop, state}
  end

  # ===== HELPER FUNCTIONS =====

  @doc """
  Insert character at cursor position.
  Handles newlines (\n) by splitting the current line.
  Automatically ensures cursor remains visible after insertion.
  """
  defp insert_char(%State{lines: lines, cursor: {line_num, col}} = state, "\n") do
    # Handle Enter key - split current line
    current_line = Enum.at(lines, line_num - 1, "")
    {before, after_cursor} = String.split_at(current_line, col - 1)

    new_lines =
      lines
      |> List.replace_at(line_num - 1, before)
      |> List.insert_at(line_num, after_cursor)

    new_state = %{state | lines: new_lines, cursor: {line_num + 1, 1}}
    new_state
    |> update_scroll_content_size()
    |> State.ensure_cursor_visible()
  end

  defp insert_char(%State{lines: lines, cursor: {line_num, col}} = state, char) when is_binary(char) do
    current_line = Enum.at(lines, line_num - 1, "")
    {before, after_cursor} = String.split_at(current_line, col - 1)
    new_line = before <> char <> after_cursor

    new_lines = List.replace_at(lines, line_num - 1, new_line)

    new_state = %{state | lines: new_lines, cursor: {line_num, col + 1}}
    new_state
    |> update_scroll_content_size()
    |> State.ensure_cursor_visible()
  end

  @doc """
  Delete character before cursor (Backspace).
  """
  defp delete_before_cursor(%State{cursor: {1, 1}} = state) do
    # At start of document - nothing to delete
    state
  end

  defp delete_before_cursor(%State{lines: lines, cursor: {line_num, 1}} = state) do
    # At start of line - join with previous line
    if line_num > 1 do
      prev_line = Enum.at(lines, line_num - 2)
      current_line = Enum.at(lines, line_num - 1)
      new_line = prev_line <> current_line

      new_lines =
        lines
        |> List.replace_at(line_num - 2, new_line)
        |> List.delete_at(line_num - 1)

      new_col = String.length(prev_line) + 1
      %{state | lines: new_lines, cursor: {line_num - 1, new_col}}
      |> update_scroll_content_size()
    else
      state
    end
  end

  defp delete_before_cursor(%State{lines: lines, cursor: {line_num, col}} = state) do
    # Delete character before cursor in current line
    current_line = Enum.at(lines, line_num - 1, "")
    {before, after_cursor} = String.split_at(current_line, col - 1)
    new_before = String.slice(before, 0..-2//1)
    new_line = new_before <> after_cursor

    new_lines = List.replace_at(lines, line_num - 1, new_line)

    %{state | lines: new_lines, cursor: {line_num, max(1, col - 1)}}
    |> update_scroll_content_size()
  end

  @doc """
  Delete character at cursor (Delete key).
  """
  defp delete_at_cursor(%State{lines: lines, cursor: {line_num, col}} = state) do
    current_line = Enum.at(lines, line_num - 1, "")

    if col > String.length(current_line) do
      # At end of line - join with next line
      if line_num < length(lines) do
        next_line = Enum.at(lines, line_num)
        new_line = current_line <> next_line

        new_lines =
          lines
          |> List.replace_at(line_num - 1, new_line)
          |> List.delete_at(line_num)

        %{state | lines: new_lines}
        |> update_scroll_content_size()
      else
        state
      end
    else
      # Delete character at cursor
      {before, after_cursor} = String.split_at(current_line, col - 1)
      new_after = String.slice(after_cursor, 1..-1//1)
      new_line = before <> new_after

      new_lines = List.replace_at(lines, line_num - 1, new_line)
      %{state | lines: new_lines}
      |> update_scroll_content_size()
    end
  end

  @doc """
  Move cursor in specified direction.
  Automatically ensures cursor remains visible after movement.
  """
  defp move_cursor(%State{cursor: {line, col}, lines: lines} = state, :left) do
    new_state = if col > 1 do
      %{state | cursor: {line, col - 1}}
    else
      # At start of line - move to end of previous line
      if line > 1 do
        prev_line = Enum.at(lines, line - 2)
        %{state | cursor: {line - 1, String.length(prev_line) + 1}}
      else
        state
      end
    end

    State.ensure_cursor_visible(new_state)
  end

  defp move_cursor(%State{cursor: {line, col}, lines: lines} = state, :right) do
    current_line = Enum.at(lines, line - 1, "")

    new_state = if col <= String.length(current_line) do
      %{state | cursor: {line, col + 1}}
    else
      # At end of line - move to start of next line
      if line < length(lines) do
        %{state | cursor: {line + 1, 1}}
      else
        state
      end
    end

    State.ensure_cursor_visible(new_state)
  end

  defp move_cursor(%State{cursor: {line, col}, lines: lines} = state, :up) do
    new_state = if line > 1 do
      prev_line = Enum.at(lines, line - 2)
      new_col = min(col, String.length(prev_line) + 1)
      %{state | cursor: {line - 1, new_col}}
    else
      state
    end

    State.ensure_cursor_visible(new_state)
  end

  defp move_cursor(%State{cursor: {line, col}, lines: lines} = state, :down) do
    new_state = if line < length(lines) do
      next_line = Enum.at(lines, line)
      new_col = min(col, String.length(next_line) + 1)
      %{state | cursor: {line + 1, new_col}}
    else
      state
    end

    State.ensure_cursor_visible(new_state)
  end

  defp move_cursor(%State{cursor: {line, _col}} = state, :line_start) do
    new_state = %{state | cursor: {line, 1}}
    State.ensure_cursor_visible(new_state)
  end

  defp move_cursor(%State{cursor: {line, _col}, lines: lines} = state, :line_end) do
    current_line = Enum.at(lines, line - 1, "")
    new_state = %{state | cursor: {line, String.length(current_line) + 1}}
    State.ensure_cursor_visible(new_state)
  end

  # ===== SELECTION HELPERS =====

  @doc """
  Move cursor with selection (Shift+Arrow).
  If no selection exists, start one at current cursor position.
  """
  defp move_cursor_with_selection(%State{selection: nil, cursor: cursor} = state, direction) do
    # Start selection at current cursor
    new_state = move_cursor(state, direction)
    %{new_state | selection: {cursor, new_state.cursor}}
  end

  defp move_cursor_with_selection(%State{selection: {anchor, _head}} = state, direction) do
    # Extend existing selection
    new_state = move_cursor(state, direction)
    %{new_state | selection: {anchor, new_state.cursor}}
  end

  @doc """
  Clear selection.
  """
  defp clear_selection(%State{} = state) do
    %{state | selection: nil}
  end

  @doc """
  Select all text in the document.
  """
  defp select_all(%State{lines: lines} = state) do
    last_line_num = length(lines)
    last_line = Enum.at(lines, last_line_num - 1, "")
    last_col = String.length(last_line) + 1

    %{state |
      selection: {{1, 1}, {last_line_num, last_col}},
      cursor: {last_line_num, last_col}
    }
  end

  @doc """
  Delete selected text if any.
  Returns state with selection deleted and cursor at selection start.
  """
  defp delete_selection(%State{selection: nil} = state), do: state

  defp delete_selection(%State{selection: {start_pos, end_pos}} = state) do
    # Ensure start comes before end
    {start_pos, end_pos} = normalize_selection(start_pos, end_pos)
    {start_line, start_col} = start_pos
    {end_line, end_col} = end_pos

    cond do
      # Same position - nothing to delete
      start_pos == end_pos ->
        %{state | selection: nil}

      # Selection within single line
      start_line == end_line ->
        current_line = Enum.at(state.lines, start_line - 1, "")
        {before, rest} = String.split_at(current_line, start_col - 1)
        {_selected, after_sel} = String.split_at(rest, end_col - start_col)
        new_line = before <> after_sel

        new_lines = List.replace_at(state.lines, start_line - 1, new_line)
        %{state | lines: new_lines, cursor: start_pos, selection: nil}

      # Multi-line selection
      true ->
        start_line_text = Enum.at(state.lines, start_line - 1, "")
        end_line_text = Enum.at(state.lines, end_line - 1, "")

        # Keep text before selection start and after selection end
        before = String.slice(start_line_text, 0, start_col - 1)
        after_sel = String.slice(end_line_text, end_col - 1, String.length(end_line_text))
        merged_line = before <> after_sel

        # Remove all lines in selection range and replace with merged line
        new_lines =
          state.lines
          |> Enum.with_index(1)
          |> Enum.reject(fn {_line, idx} -> idx > start_line and idx <= end_line end)
          |> Enum.map(fn {line, idx} ->
            if idx == start_line, do: merged_line, else: line
          end)

        %{state | lines: new_lines, cursor: start_pos, selection: nil}
    end
  end

  @doc """
  Normalize selection so start comes before end.
  """
  defp normalize_selection({line1, col1} = pos1, {line2, col2} = pos2) do
    cond do
      line1 < line2 -> {pos1, pos2}
      line1 > line2 -> {pos2, pos1}
      col1 <= col2 -> {pos1, pos2}
      true -> {pos2, pos1}
    end
  end

  @doc """
  Get the currently selected text as a string.
  """
  defp get_selected_text(%State{selection: nil}), do: ""

  defp get_selected_text(%State{selection: {start_pos, end_pos}, lines: lines}) do
    {start_pos, end_pos} = normalize_selection(start_pos, end_pos)
    {start_line, start_col} = start_pos
    {end_line, end_col} = end_pos

    cond do
      # Same position - empty selection
      start_pos == end_pos ->
        ""

      # Single line selection
      start_line == end_line ->
        line = Enum.at(lines, start_line - 1, "")
        String.slice(line, start_col - 1, end_col - start_col)

      # Multi-line selection
      true ->
        lines
        |> Enum.with_index(1)
        |> Enum.filter(fn {_line, idx} -> idx >= start_line and idx <= end_line end)
        |> Enum.map(fn {line, idx} ->
          cond do
            idx == start_line ->
              String.slice(line, start_col - 1, String.length(line))
            idx == end_line ->
              String.slice(line, 0, end_col - 1)
            true ->
              line
          end
        end)
        |> Enum.join("\n")
    end
  end

  @doc """
  Insert text at cursor position (used for paste).
  Unlike insert_char which handles single characters, this handles multi-line strings
  efficiently in a single operation.
  Returns the final cursor position after all text is inserted.
  """
  defp insert_text_at_cursor(%State{lines: lines, cursor: {line, col}} = state, text) when is_binary(text) do
    paste_lines = String.split(text, "\n")

    case paste_lines do
      # Single line - simple insertion
      [single_line] ->
        current_line = Enum.at(lines, line - 1, "")
        {left_text, right_text} = String.split_at(current_line, col - 1)
        updated_line = left_text <> single_line <> right_text
        new_lines = List.replace_at(lines, line - 1, updated_line)
        final_col = col + String.length(single_line)

        new_state = %{state | lines: new_lines, cursor: {line, final_col}}
        State.ensure_cursor_visible(new_state)

      # Multiple lines - efficient batch insertion
      [first_line | rest] ->
        current_line = Enum.at(lines, line - 1, "")
        {left_text, right_text} = String.split_at(current_line, col - 1)

        # First line: left_text + first_line
        first_updated = left_text <> first_line

        # Last line: last_line + right_text
        {middle_lines, [last_line]} = Enum.split(rest, -1)
        last_updated = last_line <> right_text

        # Build the new lines list
        {before_lines, after_lines} = Enum.split(lines, line - 1)
        [_current | remaining_after] = after_lines

        # Combine all parts
        new_lines = before_lines ++ [first_updated] ++ middle_lines ++ [last_updated] ++ remaining_after

        # Calculate final cursor position
        final_line = line + length(paste_lines) - 1
        final_col = String.length(last_line) + 1

        new_state = %{state | lines: new_lines, cursor: {final_line, final_col}}
        State.ensure_cursor_visible(new_state)
    end
  end

  # ===== SCROLL HELPERS =====

  @doc """
  Handle scroll input with smart Shift+scroll support using the Scrollable macro functions.
  When Shift is held, vertical scrolling is converted to horizontal scrolling.
  """
  defp handle_scroll_input_smart(%State{scroll: scroll} = state, delta_x, delta_y) do
    IO.puts("🖱️ Scroll: dx=#{delta_x}, dy=#{delta_y}, shift_held=#{scroll.shift_held}, direction=#{scroll.direction}")
    # Negate deltas for natural scrolling (scroll down = content moves up)
    new_scroll = handle_scroll_smart(scroll, -delta_x, -delta_y)

    if scroll_changed?(scroll, new_scroll) do
      {:noop, %{state | scroll: new_scroll}}
    else
      {:noop, state}
    end
  end

  @doc """
  Handle 2D scroll input using the Scrollable macro functions.
  Supports both vertical and horizontal scrolling based on scroll direction setting.
  """
  defp handle_scroll_input_2d(%State{scroll: scroll} = state, delta_x, delta_y) do
    # Negate deltas for natural scrolling (scroll down = content moves up)
    new_scroll = handle_scroll_2d(scroll, -delta_x, -delta_y)

    if scroll_changed?(scroll, new_scroll) do
      {:noop, %{state | scroll: new_scroll}}
    else
      {:noop, state}
    end
  end

  @doc """
  Update scroll content size based on current wrapped line count.
  Should be called after text changes that affect line count.
  """
  def update_scroll_content_size(%State{lines: lines, scroll: scroll, wrap_mode: wrap_mode, font: font} = state) do
    line_height = font.size

    # Calculate wrapped display line count
    display_line_count = case wrap_mode do
      :none ->
        length(lines)
      _wrap ->
        # Approximate wrapped line count using viewport width
        text_width = scroll.viewport_width - 20  # padding
        char_width = trunc(font.size * 0.6)
        max_chars = max(1, trunc(text_width / char_width))

        lines
        |> Enum.map(fn line ->
          line_len = String.length(line)
          if line_len <= max_chars, do: 1, else: ceil(line_len / max_chars)
        end)
        |> Enum.sum()
    end

    content_height = display_line_count * line_height
    new_scroll = Widgex.Scroll.ScrollState.update_content_size(scroll, scroll.content_width, content_height)
    %{state | scroll: new_scroll}
  end
end
