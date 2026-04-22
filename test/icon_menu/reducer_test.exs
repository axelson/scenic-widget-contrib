defmodule ScenicWidgets.IconMenu.ReducerTest do
  @moduledoc """
  TDD gate for Bug 002 — menubar deselect.

  See `quillex/docs/bugs/002_menubar_deselect.md`. Two PRD-confirmed
  pure-state-transition failures live in `IconMenu.Reducer`:

    V1 (PRIMARY) — Escape key never closes an open dropdown. The clause
    at `reducer.ex:25` matches `{:key, {"escape", _mods, _action}}` but
    Scenic delivers `{:key, {:key_esc, key_state, mods}}` (cf.
    `text_field/reducer.ex:101`). Input falls through to the catch-all
    noop at `reducer.ex:29`.

    V2 (SECONDARY) — Click on the already-active icon (toggle-close)
    clears `active_menu`/`hovered_item` at `reducer.ex:91-93` but leaves
    `hovered_menu` set, so the icon retains hover styling visually until
    the cursor leaves the bar.

  These tests MUST fail on HEAD (`fb15316`) — they are the failing-test
  gate that authorises the fix commit.
  """

  use ExUnit.Case, async: true

  alias ScenicWidgets.IconMenu.{Reducer, State}
  alias Widgex.Frame

  defp build_state do
    frame = %Frame{
      pin: %{point: {0, 0}},
      size: %{width: 800, height: 35}
    }

    State.new(%{frame: frame, align: :left})
  end

  describe "menubar hover/deselect — Bug 002" do
    test "Escape with active dropdown closes it (V1 — primary)" do
      state = %{
        build_state()
        | active_menu: :file,
          hovered_menu: :file,
          hovered_item: "new"
      }

      escape_input = {:key, {:key_esc, 1, []}}

      assert {:noop, new_state} = Reducer.process_input(state, escape_input)

      assert new_state.active_menu == nil,
             "Escape must clear active_menu; got #{inspect(new_state.active_menu)}"

      assert new_state.hovered_menu == nil,
             "Escape must clear hovered_menu; got #{inspect(new_state.hovered_menu)}"

      assert new_state.hovered_item == nil,
             "Escape must clear hovered_item; got #{inspect(new_state.hovered_item)}"
    end

    test "Toggle-close (click on active icon) clears hovered_menu (V2 — secondary)" do
      # File icon spans x = 0..35 with align: :left and default button_size 35.
      # Click at (17, 17) lands inside the File icon button.
      state = %{
        build_state()
        | active_menu: :file,
          hovered_menu: :file,
          hovered_item: nil
      }

      click_input = {:cursor_button, {:btn_left, 1, [], {17, 17}}}

      assert {:noop, new_state} = Reducer.process_input(state, click_input)

      assert new_state.active_menu == nil,
             "Toggle-close must clear active_menu; got #{inspect(new_state.active_menu)}"

      assert new_state.hovered_menu == nil, """
      Toggle-close must clear hovered_menu, but it was #{inspect(new_state.hovered_menu)}.
      Bug 002 V2: reducer.ex:91-93 only clears active_menu/hovered_item.
      """
    end
  end
end
