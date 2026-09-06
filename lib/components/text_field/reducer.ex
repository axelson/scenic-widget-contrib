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

  # Debounce period (ms) to ignore keypresses right after gaining focus.
  # This prevents the key that triggered focus (e.g., "k" from space+k) from being inserted.
  @focus_debounce_ms 50

  # Double-click threshold in milliseconds
  @double_click_ms 400

  # Modifiers that mark a codepoint as belonging to a keyboard shortcut rather
  # than to document text, so it must never be inserted. :meta is macOS Command,
  # :super is the Linux/Windows key, :alt is the emacs Meta modifier (macOS Option).
  # macOS composes Option+letter into a codepoint (Option+F -> "ƒ"), so :alt must be
  # dropped here or the emacs word motions (Alt-F/B/D) would also type that glyph;
  # the tradeoff is that Option-as-compose-key text entry is disabled in this field.
  # Shift and lock keys are absent on purpose: they are text modifiers the driver has
  # already folded into the character.
  @command_mods [:ctrl, :meta, :super, :alt]

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

  # Debounce: Ignore codepoints that arrive immediately after focus (e.g., "k" from space+k shortcut)
  def process_input(%State{focused: true, focus_time: focus_time} = state, {:codepoint, _} = _input)
      when is_integer(focus_time) do
    now = System.monotonic_time(:millisecond)
    if now - focus_time < @focus_debounce_ms do
      # Input arrived too soon after focus - ignore it (likely the focus-triggering key)
      IO.puts("🔇 TextField: Ignoring codepoint within #{@focus_debounce_ms}ms of focus (focus_debounce)")
      {:noop, state}
    else
      # Past debounce window - process normally
      process_input_codepoint(state, _input)
    end
  end

  def process_input(%State{focused: true} = state, {:codepoint, {char, _mods}} = input) when is_bitstring(char) do
    process_input_codepoint(state, input)
  end

  # Command-modified codepoints (e.g. Cmd+A on macOS, which GLFW also reports as
  # a codepoint) belong to a shortcut, not to the document — drop them so the
  # letter is never inserted alongside the shortcut's action. Guarding here, the
  # chokepoint both codepoint clauses funnel through, also covers the debounce
  # path above.
  defp process_input_codepoint(state, {:codepoint, {char, mods}})
       when is_bitstring(char) and is_list(mods) do
    if Enum.any?(mods, &(&1 in @command_mods)) do
      {:noop, state}
    else
      # Push undo before making changes
      state_with_undo = State.push_undo(state)
      # Delete selection first if any, then insert
      state_after_delete = delete_selection(state_with_undo)
      new_state = insert_char(state_after_delete, char)
      {:event, {:text_changed, state.id, State.get_text(new_state)}, new_state}
    end
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

  # Enter key - insert newline in multi_line mode (doesn't send codepoint event, only key event)
  def process_input(%State{focused: true, mode: :multi_line} = state, {:key, {:key_enter, key_state, _mods}}) when key_state > 0 do
    # key_state > 0 matches both press (1) and repeat (2) events
    state_with_undo = State.push_undo(state)
    state_after_delete = delete_selection(state_with_undo)
    new_state = insert_char(state_after_delete, "\n")
    {:event, {:text_changed, state.id, State.get_text(new_state)}, new_state}
  end

  # Enter key - emit :enter_pressed event in single_line mode (for command bars, search fields, etc.)
  def process_input(%State{focused: true, mode: :single_line} = state, {:key, {:key_enter, key_state, _mods}}) when key_state > 0 do
    # Don't insert newline - emit event for parent to handle
    {:event, {:enter_pressed, state.id, State.get_text(state)}, state}
  end

  # Escape key - emit :escape_pressed event for parent to handle (close dialogs, etc.)
  # Note: Scenic uses :key_esc not :key_escape
  def process_input(%State{focused: true} = state, {:key, {:key_esc, key_state, _mods}}) when key_state > 0 do
    IO.puts("🔑 TextField.Reducer: Escape key pressed! id=#{inspect(state.id)}")
    {:event, {:escape_pressed, state.id}, state}
  end

  # Option+Backspace (⌥⌫) - delete word backward. Mirrors Alt+D (kill word forward):
  # a no-op with no undo entry when already at the document start. Must precede the
  # generic backspace clauses below, which match any modifiers.
  def process_input(%State{focused: true, cursor: cursor} = state, {:key, {:key_backspace, key_state, [:alt]}})
      when key_state > 0 do
    target = State.word_motion_target(state, :word_left)

    if target == cursor do
      {:noop, state}
    else
      state_with_undo = State.push_undo(state)
      new_state = kill_word_backward(state_with_undo, target)
      {:event, {:text_changed, state.id, State.get_text(new_state)}, new_state}
    end
  end

  # Cmd+Backspace (⌘⌫) - delete to line start. A no-op (no undo entry) at column 1.
  def process_input(%State{focused: true, cursor: {_line, col} = cursor} = state, {:key, {:key_backspace, key_state, [:meta]}})
      when key_state > 0 do
    if col == 1 do
      {:noop, state}
    else
      state_with_undo = State.push_undo(state)
      new_state = kill_to_line_start(state_with_undo, cursor)
      {:event, {:text_changed, state.id, State.get_text(new_state)}, new_state}
    end
  end

  # Backspace - delete selection or character before cursor
  # key_state > 0 matches both press (1) and repeat (2) for key-hold functionality
  def process_input(%State{focused: true, selection: selection} = state, {:key, {:key_backspace, key_state, _mods}}) when selection != nil and key_state > 0 do
    state_with_undo = State.push_undo(state)
    new_state = delete_selection(state_with_undo)
    {:event, {:text_changed, state.id, State.get_text(new_state)}, new_state}
  end

  def process_input(%State{focused: true} = state, {:key, {:key_backspace, key_state, _mods}}) when key_state > 0 do
    state_with_undo = State.push_undo(state)
    new_state = delete_before_cursor(state_with_undo)
    {:event, {:text_changed, state.id, State.get_text(new_state)}, new_state}
  end

  # Delete - delete selection or character at cursor
  # key_state > 0 matches both press (1) and repeat (2) for key-hold functionality
  def process_input(%State{focused: true, selection: selection} = state, {:key, {:key_delete, key_state, _mods}}) when selection != nil and key_state > 0 do
    state_with_undo = State.push_undo(state)
    new_state = delete_selection(state_with_undo)
    {:event, {:text_changed, state.id, State.get_text(new_state)}, new_state}
  end

  def process_input(%State{focused: true} = state, {:key, {:key_delete, key_state, _mods}}) when key_state > 0 do
    state_with_undo = State.push_undo(state)
    new_state = delete_at_cursor(state_with_undo)
    {:event, {:text_changed, state.id, State.get_text(new_state)}, new_state}
  end

  # Arrow keys - motion with optional selection. key_state > 0 matches both press (1)
  # and repeat (2) for key-hold functionality. The whole modifier set decides the
  # action: Shift extends a selection (else the motion collapses it), Option (:alt)
  # moves by word, Cmd (:meta) moves to the line boundary (horizontal) or document
  # boundary (vertical). horizontal_action/2 and vertical_action/2 turn the mods into
  # a {verb, direction}; apply_action/2 runs it. (Membership checks live in those
  # helpers' bodies, not a guard — `x in mods` is guard-legal only for a literal list.)
  def process_input(%State{focused: true} = state, {:key, {:key_left, key_state, mods}}) when key_state > 0 do
    {:noop, apply_action(state, horizontal_action(mods, :left))}
  end

  def process_input(%State{focused: true} = state, {:key, {:key_right, key_state, mods}}) when key_state > 0 do
    {:noop, apply_action(state, horizontal_action(mods, :right))}
  end

  def process_input(%State{focused: true} = state, {:key, {:key_up, key_state, mods}}) when key_state > 0 do
    {:noop, apply_action(state, vertical_action(mods, :up))}
  end

  def process_input(%State{focused: true} = state, {:key, {:key_down, key_state, mods}}) when key_state > 0 do
    {:noop, apply_action(state, vertical_action(mods, :down))}
  end

  # Home/End keys
  def process_input(%State{focused: true} = state, @home_key) do
    {:noop, state |> move_cursor(:line_start) |> clear_selection()}
  end

  def process_input(%State{focused: true} = state, @end_key) do
    {:noop, state |> move_cursor(:line_end) |> clear_selection()}
  end

  # Shift+Home / Shift+End - select to line start / end. Plain Home/End (empty mods,
  # above) still handle the no-modifier case; these add the selection variant.
  def process_input(%State{focused: true} = state, {:key, {:key_home, key_state, [:shift]}}) when key_state > 0 do
    {:noop, move_cursor_with_selection(state, :line_start)}
  end

  def process_input(%State{focused: true} = state, {:key, {:key_end, key_state, [:shift]}}) when key_state > 0 do
    {:noop, move_cursor_with_selection(state, :line_end)}
  end

  # Escape - clear focus (optionally)
  def process_input(%State{focused: true} = state, @escape_key) do
    # IO.puts("🔍 Focus lost: Escape pressed")
    {:event, {:focus_lost, state.id}, %{state | focused: false}}
  end

  # Tab - insert a tab character
  def process_input(%State{focused: true} = state, @tab_key) do
    state_with_undo = State.push_undo(state)
    new_state = delete_selection(state_with_undo) |> insert_text_at_cursor("\t")
    {:event, {:text_changed, state.id, State.get_text(new_state)}, new_state}
  end

  # ===== KEYBOARD SHORTCUTS =====

  # Cmd+A - Select all
  def process_input(%State{focused: true} = state, @meta_a) do
    # IO.puts("🔍 Ctrl+A pressed! Focused: #{state.focused}")
    {:noop, select_all(state)}
  end

  # Cmd+C - Copy selection to clipboard (works even when unfocused)
  def process_input(%State{selection: selection} = state, @meta_c) when selection != nil do
    text = get_selected_text(state)
    # IO.puts("🔍 Ctrl+C pressed! Selection: #{inspect(selection)}, Text: #{inspect(text)}, Focused: #{state.focused}")
    # Send clipboard event to parent (Scenic doesn't have system clipboard access)
    {:event, {:clipboard_copy, state.id, text}, state}
  end

  def process_input(%State{} = state, @meta_c) do
    # No selection - do nothing
    {:noop, state}
  end

  # Cmd+X - Cut selection to clipboard (works even when unfocused)
  def process_input(%State{selection: selection} = state, @meta_x) when selection != nil do
    text = get_selected_text(state)
    new_state = delete_selection(state)
    # IO.puts("🔍 Ctrl+X pressed! Focused: #{state.focused}")
    # Send clipboard event to parent
    {:event, {:clipboard_cut, state.id, text}, new_state}
  end

  def process_input(%State{} = state, @meta_x) do
    # No selection - do nothing
    {:noop, state}
  end

  # Cmd+V - Paste from clipboard (works even when unfocused for testing)
  def process_input(%State{} = state, @meta_v) do
    # IO.puts("🔍 Ctrl+V pressed! Focused: #{state.focused}")
    # Emit event to request clipboard data from parent
    # Parent will call insert_text action with the clipboard content
    {:event, {:clipboard_paste_requested, state.id}, state}
  end

  # Cmd+S - Save (emit event for parent to handle)
  def process_input(%State{focused: true} = state, @meta_s) do
    {:event, {:save_requested, state.id, State.get_text(state)}, state}
  end

  # Cmd+F - Find (emit event to open search dialog)
  def process_input(%State{focused: true} = state, @meta_f) do
    {:event, {:find_requested, state.id}, state}
  end

  # Cmd+G - Go to next match (if searching)
  def process_input(%State{focused: true, search_matches: matches, search_current_index: idx} = state, @meta_g)
      when length(matches) > 0 do
    # Cycle to next match
    next_idx = rem(idx + 1, length(matches))
    {line, col, _text} = Enum.at(matches, next_idx)
    new_state = %{state | search_current_index: next_idx, cursor: {line, col}}
      |> State.ensure_cursor_visible()
    {:event, {:search_navigated, state.id, next_idx, length(matches)}, new_state}
  end

  # Cmd+Z - Undo
  def process_input(%State{focused: true} = state, {:key, {:key_z, 1, [:meta]}}) do
    apply_history(state, State.undo(state))
  end

  # Cmd+Shift+Z - Redo. The driver does not guarantee modifier order, so accept
  # either ordering rather than a single literal list.
  def process_input(%State{focused: true} = state, {:key, {:key_z, 1, mods}})
      when mods == [:meta, :shift] or mods == [:shift, :meta] do
    apply_history(state, State.redo(state))
  end

  # ===== EMACS / READLINE MOTIONS (Ctrl, macOS) =====
  # Ctrl is distinct from Cmd here: Cmd drives the app shortcuts above, Ctrl drives
  # these emacs-style motions. key_state > 0 matches press + repeat so holding a key
  # repeats, like the arrow keys. Motions clear any active selection, like the arrows.

  # Ctrl+A - beginning of line
  def process_input(%State{focused: true} = state, {:key, {:key_a, key_state, [:ctrl]}}) when key_state > 0 do
    {:noop, move_cursor(state, :line_start) |> clear_selection()}
  end

  # Ctrl+E - end of line
  def process_input(%State{focused: true} = state, {:key, {:key_e, key_state, [:ctrl]}}) when key_state > 0 do
    {:noop, move_cursor(state, :line_end) |> clear_selection()}
  end

  # Ctrl+B - backward char
  def process_input(%State{focused: true} = state, {:key, {:key_b, key_state, [:ctrl]}}) when key_state > 0 do
    {:noop, move_cursor(state, :left) |> clear_selection()}
  end

  # Ctrl+F - forward char
  def process_input(%State{focused: true} = state, {:key, {:key_f, key_state, [:ctrl]}}) when key_state > 0 do
    {:noop, move_cursor(state, :right) |> clear_selection()}
  end

  # Ctrl+P - previous line
  def process_input(%State{focused: true} = state, {:key, {:key_p, key_state, [:ctrl]}}) when key_state > 0 do
    {:noop, move_cursor(state, :up) |> clear_selection()}
  end

  # Ctrl+N - next line
  def process_input(%State{focused: true} = state, {:key, {:key_n, key_state, [:ctrl]}}) when key_state > 0 do
    {:noop, move_cursor(state, :down) |> clear_selection()}
  end

  # Ctrl+D - delete char forward
  def process_input(%State{focused: true} = state, {:key, {:key_d, key_state, [:ctrl]}}) when key_state > 0 do
    state_with_undo = State.push_undo(state)
    new_state = delete_at_cursor(state_with_undo)
    {:event, {:text_changed, state.id, State.get_text(new_state)}, new_state}
  end

  # Ctrl+K - kill to end of line (plain delete; no kill-ring)
  def process_input(%State{focused: true} = state, {:key, {:key_k, key_state, [:ctrl]}}) when key_state > 0 do
    state_with_undo = State.push_undo(state)
    new_state = kill_to_line_end(state_with_undo)
    {:event, {:text_changed, state.id, State.get_text(new_state)}, new_state}
  end

  # ===== EMACS WORD MOTIONS (Alt / Option = Meta) =====
  # Alt is the emacs Meta modifier: Alt-F/B move by word, Alt-D kills the next word.
  # key_state > 0 matches press + repeat so holding a key repeats. On macOS these keys
  # also emit composed codepoints (ƒ/∫/∂); @command_mods drops those so nothing is typed.

  # Alt+F - forward word
  def process_input(%State{focused: true} = state, {:key, {:key_f, key_state, [:alt]}}) when key_state > 0 do
    {:noop, move_cursor(state, :word_right) |> clear_selection()}
  end

  # Alt+B - backward word
  def process_input(%State{focused: true} = state, {:key, {:key_b, key_state, [:alt]}}) when key_state > 0 do
    {:noop, move_cursor(state, :word_left) |> clear_selection()}
  end

  # Alt+Shift+F / Alt+Shift+B - select word forward / backward (the selection variants
  # of Alt+F/B above). Accept either modifier ordering, since the driver doesn't
  # guarantee it. The @command_mods codepoint guard already drops the composed glyph,
  # exactly as for Alt+F/B.
  def process_input(%State{focused: true} = state, {:key, {:key_f, key_state, mods}})
      when key_state > 0 and (mods == [:alt, :shift] or mods == [:shift, :alt]) do
    {:noop, move_cursor_with_selection(state, :word_right)}
  end

  def process_input(%State{focused: true} = state, {:key, {:key_b, key_state, mods}})
      when key_state > 0 and (mods == [:alt, :shift] or mods == [:shift, :alt]) do
    {:noop, move_cursor_with_selection(state, :word_left)}
  end

  # Alt+D - kill word forward (delete from cursor to the forward-word boundary; no kill-ring)
  def process_input(%State{focused: true, cursor: cursor} = state, {:key, {:key_d, key_state, [:alt]}})
      when key_state > 0 do
    target = State.word_motion_target(state, :word_right)

    if target == cursor do
      # Nothing to the right (end of document) - no-op, no undo entry.
      {:noop, state}
    else
      state_with_undo = State.push_undo(state)
      new_state = kill_word_forward(state_with_undo, target)
      {:event, {:text_changed, state.id, State.get_text(new_state)}, new_state}
    end
  end

  # ===== SHIFT KEY TRACKING (for Shift+scroll horizontal scrolling) =====
  # NOTE: These MUST come BEFORE the key release catch-all so shift release is tracked

  # Track Shift key press - both left and right shift
  def process_input(%State{scroll: scroll} = state, {:key, {:key_leftshift, 1, _}}) do
    {:noop, %{state | scroll: set_scroll_shift(scroll, true)}}
  end

  def process_input(%State{scroll: scroll} = state, {:key, {:key_rightshift, 1, _}}) do
    {:noop, %{state | scroll: set_scroll_shift(scroll, true)}}
  end

  # Track Shift key release
  def process_input(%State{scroll: scroll} = state, {:key, {:key_leftshift, 0, _}}) do
    {:noop, %{state | scroll: set_scroll_shift(scroll, false)}}
  end

  def process_input(%State{scroll: scroll} = state, {:key, {:key_rightshift, 0, _}}) do
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

  # ===== SCROLLBAR DRAG =====

  # Mouse button release - end scrollbar drag
  def process_input(%State{scrollbar_drag: drag} = state, {:cursor_button, {:btn_left, 0, _, _pos}}) when drag != nil do
    {:noop, %{state | scrollbar_drag: nil, scrollbar_drag_start: nil, scrollbar_drag_offset: nil}}
  end

  # Mouse move during scrollbar drag
  def process_input(%State{scrollbar_drag: :x, scrollbar_drag_start: {start_x, _}, scrollbar_drag_offset: start_offset, scroll: scroll} = state, {:cursor_pos, {x, _y}}) do
    # Calculate how far we've dragged in pixels
    drag_delta = x - start_x

    # Convert to scroll offset based on track/content ratio
    {_track_start, track_length, content_size, viewport_size} = State.scrollbar_track_info(state, :x)
    max_offset = content_size - viewport_size

    # The ratio of track movement to content movement
    # When thumb moves full track length, content scrolls full max_offset
    scroll_delta = (drag_delta / track_length) * max_offset

    new_offset_x = max(0, min(max_offset, start_offset + scroll_delta))
    new_scroll = %{scroll | offset_x: new_offset_x}

    {:noop, %{state | scroll: new_scroll}}
  end

  def process_input(%State{scrollbar_drag: :y, scrollbar_drag_start: {_, start_y}, scrollbar_drag_offset: start_offset, scroll: scroll} = state, {:cursor_pos, {_x, y}}) do
    drag_delta = y - start_y

    {_track_start, track_length, content_size, viewport_size} = State.scrollbar_track_info(state, :y)
    max_offset = content_size - viewport_size

    scroll_delta = (drag_delta / track_length) * max_offset

    new_offset_y = max(0, min(max_offset, start_offset + scroll_delta))
    new_scroll = %{scroll | offset_y: new_offset_y}

    {:noop, %{state | scroll: new_scroll}}
  end

  # ===== CLICK TO FOCUS =====

  # Click on scrollbar - start drag (check before focus handling)
  def process_input(%State{} = state, {:cursor_button, {:btn_left, 1, _, pos}}) do
    case State.scrollbar_hit_test(state, pos) do
      :x ->
        # Start horizontal scrollbar drag
        {:noop, %{state |
          scrollbar_drag: :x,
          scrollbar_drag_start: pos,
          scrollbar_drag_offset: state.scroll.offset_x
        }}

      :y ->
        # Start vertical scrollbar drag
        {:noop, %{state |
          scrollbar_drag: :y,
          scrollbar_drag_start: pos,
          scrollbar_drag_offset: state.scroll.offset_y
        }}

      nil ->
        # Not on scrollbar - handle focus
        handle_click_focus(state, pos)
    end
  end

  defp handle_click_focus(%State{focused: false} = state, pos) do
    inside = State.point_inside?(state, pos)
    # Only allow focus if editable - read-only TextFields should not gain focus
    if inside and state.editable do
      # Click to focus AND position cursor at click location
      {line, col} = State.click_to_cursor(state, pos)
      new_state = %{state |
        focused: true,
        focus_time: System.monotonic_time(:millisecond),
        cursor: {line, col},
        selection: nil
      }
      {:event, {:focus_gained, state.id}, new_state}
    else
      {:noop, state}
    end
  end

  defp handle_click_focus(%State{focused: true} = state, pos) do
    if State.point_inside?(state, pos) do
      # Click inside while focused - move cursor to click position
      {line, col} = State.click_to_cursor(state, pos)
      new_state = %{state | cursor: {line, col}, selection: nil}
      {:event, {:text_changed, state.id, State.get_text(new_state)}, new_state}
    else
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
    # Push undo before making changes
    state_with_undo = State.push_undo(state)
    # Delete selection if any, then insert text
    state_after_delete = delete_selection(state_with_undo)
    new_state = insert_text_at_cursor(state_after_delete, text)
    {:event, {:text_changed, state.id, State.get_text(new_state)}, new_state}
  end

  # Undo action (from menu)
  def process_action(state, :undo) do
    case State.undo(state) do
      {:ok, new_state} ->
        {:event, {:text_changed, state.id, State.get_text(new_state)}, new_state}
      {:noop, state} ->
        {:noop, state}
    end
  end

  # Redo action (from menu)
  def process_action(state, :redo) do
    case State.redo(state) do
      {:ok, new_state} ->
        {:event, {:text_changed, state.id, State.get_text(new_state)}, new_state}
      {:noop, state} ->
        {:noop, state}
    end
  end

  # Perform search across all lines
  def process_action(%State{lines: lines} = state, {:search, query}) when is_binary(query) and query != "" do
    # Simple search - find all occurrences of query in lines
    matches = find_all_matches(lines, query)
    match_count = length(matches)

    new_state = %{state |
      search_query: query,
      search_matches: matches,
      search_current_index: 0
    }

    # Jump to first match if any
    new_state = if match_count > 0 do
      {line, col, _text} = hd(matches)
      %{new_state | cursor: {line, col}}
      |> State.ensure_cursor_visible()
    else
      new_state
    end

    {:event, {:search_complete, state.id, query, match_count}, new_state}
  end

  # Clear search state
  def process_action(state, :clear_search) do
    new_state = %{state |
      search_query: nil,
      search_matches: [],
      search_current_index: 0
    }
    {:event, {:search_cleared, state.id}, new_state}
  end

  # Navigate to next search match
  def process_action(%State{search_matches: matches, search_current_index: idx} = state, :find_next)
      when length(matches) > 0 do
    next_idx = rem(idx + 1, length(matches))
    {line, col, _text} = Enum.at(matches, next_idx)
    new_state = %{state | search_current_index: next_idx, cursor: {line, col}}
      |> State.ensure_cursor_visible()
    {:event, {:search_navigated, state.id, next_idx, length(matches)}, new_state}
  end

  def process_action(state, :find_next) do
    # No matches to navigate
    {:noop, state}
  end

  # Navigate to previous search match
  def process_action(%State{search_matches: matches, search_current_index: idx} = state, :find_prev)
      when length(matches) > 0 do
    prev_idx = if idx == 0, do: length(matches) - 1, else: idx - 1
    {line, col, _text} = Enum.at(matches, prev_idx)
    new_state = %{state | search_current_index: prev_idx, cursor: {line, col}}
      |> State.ensure_cursor_visible()
    {:event, {:search_navigated, state.id, prev_idx, length(matches)}, new_state}
  end

  def process_action(state, :find_prev) do
    # No matches to navigate
    {:noop, state}
  end

  def process_action(state, _action) do
    {:noop, state}
  end

  # ===========================================================================
  # BUFFER-BACKED MODE: Input to Buffer Action Conversion
  # ===========================================================================

  @doc """
  Convert raw Scenic input events to buffer actions for buffer_backed mode.

  Returns:
  - nil - No action (unhandled input)
  - {:clipboard_copy, text} - Copy selected text (handled locally)
  - {:clipboard_cut, text} - Cut selected text (handled locally + buffer action)
  - {:clipboard_paste} - Paste from clipboard (fetches clipboard then sends to buffer)
  - {:local_update, new_state} - Local-only update (focus, scrollbar drag)
  - action - Buffer action tuple/atom to send to Buffer.Process
  """
  def input_to_buffer_action(%State{focused: true} = state, {:codepoint, {char, _mods}}) when is_bitstring(char) do
    # Insert character at cursor
    {:insert, char, :at_cursor}
  end

  # Enter key - insert newline
  def input_to_buffer_action(%State{focused: true, mode: :multi_line}, {:key, {:key_enter, key_state, _mods}}) when key_state > 0 do
    {:newline, :at_cursor}
  end

  # Tab key - insert tab character
  def input_to_buffer_action(%State{focused: true}, {:key, {:key_tab, key_state, _mods}}) when key_state > 0 do
    {:insert, "\t", :at_cursor}
  end

  # Backspace
  def input_to_buffer_action(%State{focused: true}, {:key, {:key_backspace, key_state, _mods}}) when key_state > 0 do
    {:delete, :before_cursor}
  end

  # Delete
  def input_to_buffer_action(%State{focused: true}, {:key, {:key_delete, key_state, _mods}}) when key_state > 0 do
    {:delete, :at_cursor}
  end

  # Arrow keys - cursor movement
  def input_to_buffer_action(%State{focused: true}, {:key, {:key_left, key_state, mods}}) when key_state > 0 do
    if :shift in mods do
      {:select_text, :left, 1}
    else
      {:move_cursor, :left, 1}
    end
  end

  def input_to_buffer_action(%State{focused: true}, {:key, {:key_right, key_state, mods}}) when key_state > 0 do
    if :shift in mods do
      {:select_text, :right, 1}
    else
      {:move_cursor, :right, 1}
    end
  end

  def input_to_buffer_action(%State{focused: true}, {:key, {:key_up, key_state, mods}}) when key_state > 0 do
    if :shift in mods do
      {:select_text, :up, 1}
    else
      {:move_cursor, :up, 1}
    end
  end

  def input_to_buffer_action(%State{focused: true}, {:key, {:key_down, key_state, mods}}) when key_state > 0 do
    if :shift in mods do
      {:select_text, :down, 1}
    else
      {:move_cursor, :down, 1}
    end
  end

  # Home/End keys
  def input_to_buffer_action(%State{focused: true}, {:key, {:key_home, key_state, _mods}}) when key_state > 0 do
    {:move_cursor, :line_start}
  end

  def input_to_buffer_action(%State{focused: true}, {:key, {:key_end, key_state, _mods}}) when key_state > 0 do
    {:move_cursor, :line_end}
  end

  # NOTE: The emacs/readline motions and the Cmd-key app-shortcut remap were applied
  # to :direct mode only (see process_input/2 above). This :buffer_backed map is
  # unused by worktree_notes and was intentionally left on the old [:ctrl] bindings.
  # Because normalize_command_key was removed, macOS Cmd shortcuts no longer reach
  # these clauses in :buffer_backed mode — acceptable since nothing uses this mode.

  # Ctrl+A - Select all
  def input_to_buffer_action(%State{focused: true}, {:key, {:key_a, 1, [:ctrl]}}) do
    :select_all
  end

  # Ctrl+C - Copy
  def input_to_buffer_action(%State{focused: true, selection: selection} = state, {:key, {:key_c, 1, [:ctrl]}}) when selection != nil do
    text = get_selected_text(state)
    {:clipboard_copy, text}
  end

  # Ctrl+X - Cut
  def input_to_buffer_action(%State{focused: true, selection: selection} = state, {:key, {:key_x, 1, [:ctrl]}}) when selection != nil do
    text = get_selected_text(state)
    {:clipboard_cut, text}
  end

  # Ctrl+V - Paste
  def input_to_buffer_action(%State{focused: true}, {:key, {:key_v, 1, [:ctrl]}}) do
    {:clipboard_paste}
  end

  # Ctrl+U - Undo
  def input_to_buffer_action(%State{focused: true}, {:key, {:key_u, 1, [:ctrl]}}) do
    :undo
  end

  # Ctrl+R - Redo
  def input_to_buffer_action(%State{focused: true}, {:key, {:key_r, 1, [:ctrl]}}) do
    :redo
  end

  # Ctrl+S - Save (pass through to parent)
  def input_to_buffer_action(%State{focused: true}, {:key, {:key_s, 1, [:ctrl]}}) do
    :save
  end

  # Ctrl+F - Find (emit event to parent)
  def input_to_buffer_action(%State{focused: true} = state, {:key, {:key_f, 1, [:ctrl]}}) do
    IO.puts("🔍 Ctrl+F pressed in buffer_backed mode! Emitting find_requested")
    {:find_requested, state.id}
  end

  # ===== SCROLLBAR DRAG (buffer_backed mode) =====

  # Mouse button release - end scrollbar drag
  def input_to_buffer_action(%State{scrollbar_drag: drag} = state, {:cursor_button, {:btn_left, 0, _, _pos}}) when drag != nil do
    {:local_update, %{state | scrollbar_drag: nil, scrollbar_drag_start: nil, scrollbar_drag_offset: nil}}
  end

  # Mouse move during horizontal scrollbar drag
  def input_to_buffer_action(%State{scrollbar_drag: :x, scrollbar_drag_start: {start_x, _}, scrollbar_drag_offset: start_offset, scroll: scroll} = state, {:cursor_pos, {x, _y}}) do
    drag_delta = x - start_x
    {_track_start, track_length, content_size, viewport_size} = State.scrollbar_track_info(state, :x)
    max_offset = content_size - viewport_size

    scroll_delta = (drag_delta / track_length) * max_offset
    new_offset_x = max(0, min(max_offset, start_offset + scroll_delta))
    new_scroll = %{scroll | offset_x: new_offset_x}

    {:local_update, %{state | scroll: new_scroll}}
  end

  # Mouse move during vertical scrollbar drag
  def input_to_buffer_action(%State{scrollbar_drag: :y, scrollbar_drag_start: {_, start_y}, scrollbar_drag_offset: start_offset, scroll: scroll} = state, {:cursor_pos, {_x, y}}) do
    drag_delta = y - start_y
    {_track_start, track_length, content_size, viewport_size} = State.scrollbar_track_info(state, :y)
    max_offset = content_size - viewport_size

    scroll_delta = (drag_delta / track_length) * max_offset
    new_offset_y = max(0, min(max_offset, start_offset + scroll_delta))
    new_scroll = %{scroll | offset_y: new_offset_y}

    {:local_update, %{state | scroll: new_scroll}}
  end

  # Mouse click - check for scrollbar hit first, then focus
  def input_to_buffer_action(%State{} = state, {:cursor_button, {:btn_left, 1, _mods, coords}}) do
    hit_result = State.scrollbar_hit_test(state, coords)
    {x, y} = coords
    gutter = if state.show_line_numbers, do: state.line_number_width, else: 0
    content_w = state.frame.size.width - gutter
    IO.puts("🖱️ CLICK: coords=#{inspect(coords)}, frame=#{state.frame.size.width}x#{state.frame.size.height}, gutter=#{gutter}, scrollbar_hit=#{inspect(hit_result)}")
    IO.puts("   Expected scrollbar_x range: #{gutter + content_w - 15}..#{gutter + content_w}")

    case hit_result do
      :x ->
        # Start horizontal scrollbar drag
        IO.puts("📜 Starting horizontal scrollbar drag at #{inspect(coords)}")
        {:local_update, %{state |
          scrollbar_drag: :x,
          scrollbar_drag_start: coords,
          scrollbar_drag_offset: state.scroll.offset_x
        }}

      :y ->
        # Start vertical scrollbar drag
        IO.puts("📜 Starting vertical scrollbar drag at #{inspect(coords)}")
        {:local_update, %{state |
          scrollbar_drag: :y,
          scrollbar_drag_start: coords,
          scrollbar_drag_offset: state.scroll.offset_y
        }}

      nil ->
        # Not on scrollbar - handle focus, cursor positioning, double-click, and text drag
        if State.point_inside?(state, coords) do
          # Convert click position to cursor line/col
          {line, col} = State.click_to_cursor(state, coords)
          click_pos = {line, col}
          now = System.monotonic_time(:millisecond)

          # Check for double-click
          is_double_click = case {state.last_click_time, state.last_click_pos} do
            {last_time, last_pos} when is_integer(last_time) and last_pos == click_pos ->
              now - last_time < @double_click_ms
            _ ->
              false
          end

          if is_double_click do
            # Double-click: select word at click position
            case State.word_boundaries_at(state, click_pos) do
              {start_col, end_col} ->
                # Select the word - start at word start, end at word end
                start_pos = {line, start_col}
                end_pos = {line, end_col}
                new_state = %{state |
                  focused: true,
                  text_drag: nil,
                  text_drag_start: nil,
                  last_click_time: nil,
                  last_click_pos: nil
                }
                {:double_click_select, new_state, {:select_range, start_pos, end_pos}}

              nil ->
                # No word at position - just move cursor (treat as single click)
                new_state = %{state |
                  focused: true,
                  text_drag: true,
                  text_drag_start: click_pos,
                  last_click_time: now,
                  last_click_pos: click_pos
                }
                {:click_move_cursor, new_state, {:set_cursor, click_pos}}
            end
          else
            # Single click: focus, start text drag for potential selection, and move cursor
            new_state = %{state |
              focused: true,
              text_drag: true,
              text_drag_start: click_pos,
              last_click_time: now,
              last_click_pos: click_pos
            }
            # Use :set_cursor for absolute positioning (not :move_cursor which is for relative movement)
            {:click_move_cursor, new_state, {:set_cursor, click_pos}}
          end
        else
          nil
        end
    end
  end

  # Mouse button release - end text drag
  def input_to_buffer_action(%State{text_drag: true} = state, {:cursor_button, {:btn_left, 0, _, _pos}}) do
    {:local_update, %{state | text_drag: nil, text_drag_start: nil}}
  end

  # Mouse move during text drag - update selection
  def input_to_buffer_action(%State{text_drag: true, text_drag_start: start_pos} = state, {:cursor_pos, coords}) when start_pos != nil do
    # Convert current position to line/col
    {line, col} = State.click_to_cursor(state, coords)
    current_pos = {line, col}

    # Only update if position changed
    if current_pos != state.cursor do
      # Send selection action to buffer
      {:drag_select, %{state | cursor: current_pos}, {:select_range, start_pos, current_pos}}
    else
      nil
    end
  end

  # Scroll handling - local update
  # Format: {{dx, dy}, {x, y}} - delta tuple and position tuple
  def input_to_buffer_action(%State{} = state, {:cursor_scroll, {{dx, dy}, {_x, _y}}}) do
    case handle_scroll_input_smart(state, dx, dy) do
      {:noop, new_state} -> {:local_update, new_state}
      _ -> nil
    end
  end

  # Format: {dx, dy, x, y} - 4-element tuple
  def input_to_buffer_action(%State{} = state, {:cursor_scroll, {dx, dy, _x, _y}}) do
    case handle_scroll_input_smart(state, dx, dy) do
      {:noop, new_state} -> {:local_update, new_state}
      _ -> nil
    end
  end

  # Shift key tracking for shift+scroll horizontal scrolling (buffer_backed mode)
  def input_to_buffer_action(%State{scroll: scroll} = state, {:key, {:key_leftshift, 1, _}}) do
    {:local_update, %{state | scroll: set_scroll_shift(scroll, true)}}
  end

  def input_to_buffer_action(%State{scroll: scroll} = state, {:key, {:key_rightshift, 1, _}}) do
    {:local_update, %{state | scroll: set_scroll_shift(scroll, true)}}
  end

  def input_to_buffer_action(%State{scroll: scroll} = state, {:key, {:key_leftshift, 0, _}}) do
    {:local_update, %{state | scroll: set_scroll_shift(scroll, false)}}
  end

  def input_to_buffer_action(%State{scroll: scroll} = state, {:key, {:key_rightshift, 0, _}}) do
    {:local_update, %{state | scroll: set_scroll_shift(scroll, false)}}
  end

  # Fallback - unhandled input
  def input_to_buffer_action(_state, _input) do
    nil
  end

  # ===== SEARCH HELPER =====

  @doc """
  Finds all occurrences of a query string in the lines.
  Returns list of {line_num, col_num, matched_text} tuples.
  Line and column numbers are 1-based.
  """
  defp find_all_matches(lines, query) when is_list(lines) and is_binary(query) do
    query_len = String.length(query)

    lines
    |> Enum.with_index(1)  # 1-based line numbers
    |> Enum.flat_map(fn {line, line_num} ->
      find_matches_in_line(line, query, query_len, line_num, 1, [])
    end)
  end

  # Recursively find all matches in a single line
  defp find_matches_in_line(line, query, query_len, line_num, col, acc) do
    case :binary.match(line, query) do
      :nomatch ->
        Enum.reverse(acc)

      {start, _len} ->
        # Convert byte offset to grapheme column (1-based)
        prefix = binary_part(line, 0, start)
        grapheme_col = col + String.length(prefix)

        # Get matched text
        matched_text = String.slice(line, String.length(prefix), query_len)

        # Continue searching in remainder
        remainder_start = start + byte_size(query)
        remainder = binary_part(line, remainder_start, byte_size(line) - remainder_start)
        new_col = grapheme_col + query_len

        find_matches_in_line(remainder, query, query_len, line_num, new_col,
          [{line_num, grapheme_col, matched_text} | acc])
    end
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
  Kill from the cursor to the end of the current line (Ctrl+K).

  Deletes the text after the cursor on the current line. This is a plain delete —
  there is no kill-ring, so nothing is stashed for a later yank. When the cursor is
  already at end-of-line, the line break is removed instead (joining the next line),
  matching `delete_at_cursor/1`'s forward-delete behavior. Cursor position is
  unchanged.
  """
  defp kill_to_line_end(%State{lines: lines, cursor: {line_num, col}} = state) do
    current_line = Enum.at(lines, line_num - 1, "")

    if col > String.length(current_line) do
      # At end of line - fall through to forward-delete, which joins the next line
      delete_at_cursor(state)
    else
      kept = String.slice(current_line, 0, col - 1)
      new_lines = List.replace_at(lines, line_num - 1, kept)

      %{state | lines: new_lines}
      |> update_scroll_content_size()
    end
  end

  # Kill from the cursor forward to `target` (the forward-word boundary; Alt+D, emacs
  # kill-word). Deletes exactly the span Alt+F would move over. Plain delete (no
  # kill-ring), reusing delete_selection/1 via a transient selection; the cursor is left
  # at its original position (delete_selection collapses to the selection start). Callers
  # guard the end-of-document no-op, so target is always past the cursor here.
  defp kill_word_forward(%State{cursor: cursor} = state, target) do
    delete_selection(%{state | selection: {cursor, target}})
  end

  # Delete from the backward-word boundary up to the cursor (Option+Backspace). Reuses
  # delete_selection, which normalizes order and lands the cursor at the earlier point.
  defp kill_word_backward(%State{cursor: cursor} = state, target) do
    delete_selection(%{state | selection: {target, cursor}})
  end

  # Delete from line start up to the cursor (Cmd+Backspace).
  defp kill_to_line_start(%State{} = state, {line, _col} = cursor) do
    delete_selection(%{state | selection: {{line, 1}, cursor}})
  end

  # Turn a State.undo/1 or State.redo/1 result into a process_input return value.
  defp apply_history(state, {:ok, new_state}) do
    {:event, {:text_changed, state.id, State.get_text(new_state)}, new_state}
  end

  defp apply_history(state, {:noop, _state}) do
    {:noop, state}
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

  # Word motions (Alt+B / Alt+F). Boundary math lives in State.word_motion_target/2;
  # here we just move the cursor there and keep it visible, like the other motions.
  defp move_cursor(%State{} = state, direction) when direction in [:word_left, :word_right] do
    new_state = %{state | cursor: State.word_motion_target(state, direction)}
    State.ensure_cursor_visible(new_state)
  end

  # Document motions (Cmd+Up / Cmd+Down): jump to the very start or end of the buffer.
  defp move_cursor(%State{} = state, :document_start) do
    State.ensure_cursor_visible(%{state | cursor: {1, 1}})
  end

  defp move_cursor(%State{lines: lines} = state, :document_end) do
    last_line = length(lines)
    last_col = String.length(Enum.at(lines, last_line - 1, "")) + 1
    State.ensure_cursor_visible(%{state | cursor: {last_line, last_col}})
  end

  @doc """
  Map a horizontal arrow's modifier set to a `{verb, direction}` action.

  Pure — never touches the font/render stack — so the whole modifier table is
  unit-testable directly. Shift picks the verb (`:select` extends a selection, `:move`
  collapses it); Option (`:alt`) selects word granularity, Cmd (`:meta`) the line
  boundary. `base` is the unmodified direction (`:left` / `:right`).
  """
  def horizontal_action(mods, base) when base in [:left, :right] do
    dir =
      cond do
        :alt in mods -> if base == :left, do: :word_left, else: :word_right
        :meta in mods -> if base == :left, do: :line_start, else: :line_end
        true -> base
      end

    {verb(mods), dir}
  end

  @doc """
  Map a vertical arrow's modifier set to a `{verb, direction}` action (see
  `horizontal_action/2`). Cmd (`:meta`) targets the document boundary; Option is not
  special-cased (paragraph motion is out of scope), so it falls through to line up/down.
  """
  def vertical_action(mods, base) when base in [:up, :down] do
    dir =
      if :meta in mods do
        if base == :up, do: :document_start, else: :document_end
      else
        base
      end

    {verb(mods), dir}
  end

  defp verb(mods), do: if(:shift in mods, do: :select, else: :move)

  defp apply_action(state, {:select, direction}), do: move_cursor_with_selection(state, direction)
  defp apply_action(state, {:move, direction}), do: move_cursor(state, direction) |> clear_selection()

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
  Update scroll content size based on current wrapped line count and max line width.
  Should be called after text changes that affect line count or line length.
  """
  def update_scroll_content_size(%State{lines: lines, scroll: scroll, wrap_mode: wrap_mode} = state) do
    line_height = State.line_height(state)

    # Calculate content dimensions based on wrap mode
    {content_width, display_line_count} = case wrap_mode do
      :none ->
        # No wrapping: content width is the widest line, height is line count
        {max_line_width, longest_line, longest_line_chars} = lines
          |> Enum.with_index()
          |> Enum.map(fn {line, idx} -> {State.string_width(state, line), idx + 1, String.length(line)} end)
          |> Enum.max_by(fn {w, _, _} -> w end, fn -> {0, 0, 0} end)
        # Add padding for cursor at end of line
        content_w = max(scroll.viewport_width, max_line_width + 40)
        max_scroll = content_w - scroll.viewport_width
        longest_line_text = Enum.at(lines, longest_line - 1, "") |> String.slice(0, 60)
        IO.puts("📏 Content (update): line #{longest_line} (#{longest_line_chars} chars)=#{max_line_width}px, viewport=#{scroll.viewport_width}, content_w=#{content_w}, max_scroll=#{max_scroll}")
        IO.puts("   └─ \"#{longest_line_text}...\" ")
        {content_w, length(lines)}

      _wrap ->
        # Word/char wrapping: content fits viewport width, but height depends on wrapped lines
        # Use the same wrapping logic as the renderer for accurate line count
        max_width = scroll.viewport_width - 40  # Account for padding and scrollbar
        wrapped_count = lines
          |> Enum.map(fn line -> count_wrapped_lines(state, line, max_width) end)
          |> Enum.sum()
        {scroll.viewport_width, wrapped_count}
    end

    # Add half line height of bottom padding so last line isn't jammed against frame edge
    bottom_padding = div(line_height, 2)
    content_height = display_line_count * line_height + bottom_padding

    new_scroll = Widgex.Scroll.ScrollState.update_content_size(scroll, content_width, content_height)

    # Update gutter width if line count changed significantly (different number of digits)
    %{state | scroll: new_scroll}
    |> State.maybe_update_gutter_width()
  end

  # Count how many display lines a single source line will wrap into
  defp count_wrapped_lines(state, line, max_width) do
    line_width = State.string_width(state, line)

    if line_width <= max_width do
      1
    else
      # Word wrap: split by words and count lines
      words = String.split(line, " ")
      {line_count, _current_width} = Enum.reduce(words, {1, 0}, fn word, {lines, current_w} ->
        word_width = State.string_width(state, word)
        space_width = State.string_width(state, " ")

        test_width = if current_w == 0, do: word_width, else: current_w + space_width + word_width

        if test_width <= max_width do
          {lines, test_width}
        else
          # Word doesn't fit, start new line
          {lines + 1, word_width}
        end
      end)
      line_count
    end
  end
end
