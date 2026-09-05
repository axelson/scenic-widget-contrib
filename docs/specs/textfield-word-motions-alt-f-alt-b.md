# TextField word motions — Alt-F / Alt-B / Alt-D

## Goal

Add emacs/readline **forward-word (Alt-F)**, **backward-word (Alt-B)**, and
**kill-word (Alt-D)** to the TextField, routing word-boundary detection through a
single configurable predicate so the definition of "a word" can be overridden per
field.

## Background

The recent "emacs/readline motions on Ctrl" work (`scenic_widget_contrib`
commit `10117c1`) added the single-character/line Ctrl motions
(Ctrl-A/E/B/F/P/N/D/K) but **no `:alt`-modified handlers and no word motion of
any kind**. So Alt-F / Alt-B / Alt-D currently match nothing and do nothing. This
spec fills that gap.

Relevant existing code (paths relative to this repo root,
`deps/scenic_widget_contrib`):

- `lib/components/text_field/reducer.ex`
  - `process_input/2` — key dispatch; the Ctrl motions live at ~L292–L326.
  - `move_cursor/2` (private, ~L1044) — the motion seam: `:left`, `:right`,
    `:up`, `:down`, `:line_start`, `:line_end`. Word motions plug in here.
  - `move_cursor_with_selection/2` (~L1118) / `clear_selection/1` (~L1133).
  - `@command_mods [:ctrl, :meta, :super]` (~L30) and
    `process_input_codepoint/2` (~L70) — the codepoint filter that drops
    shortcut chars so they aren't inserted as text.
- `lib/components/text_field/state.ex`
  - `word_char?/1` (~L718) — `Regex.match?(~r/[\w]/, char)`. Currently the only
    definition of a "word character", used by the double-click selection
    helpers `get_word_boundaries/2`, `find_word_start/2`, `find_word_end/2`,
    `extract_word_at/2`.
  - `State.new/1` (~L113) — reads all per-field options from `data` via
    `Map.get`. New config is threaded in here.
- `lib/utils/scenic_events_definitions.ex` — confirms Scenic delivers Alt as the
  `:alt` modifier (e.g. `{:key, {:key_leftalt, _, [:alt]}}`).

## Word-boundary semantics (the default)

Match emacs `forward-word` / `backward-word`, which is also what GNU readline's
`M-f` / `M-b` do. This is the canonical "emacs bindings" behavior a user pressing
Alt-F/Alt-B expects.

- **Alt-F (forward-word)** — from the cursor, skip forward over any *non-word*
  characters, then skip forward over *word* characters; stop. The cursor lands
  immediately **after** the last word character passed. If the cursor is already
  inside a word, it finishes that word.
- **Alt-B (backward-word)** — from the cursor, skip backward over any *non-word*
  characters, then skip backward over *word* characters; stop. The cursor lands
  immediately **before** the first word character of that word (i.e. at the word
  start).
- **Alt-D (kill-word)** — delete the text from the cursor up to the
  **forward-word** target, i.e. delete exactly the span Alt-F would move over
  (any separators plus the following word). Emacs `M-d` / readline `M-d`. The
  cursor stays put; the text after it is pulled left. Deleting nothing (already
  at end of document) is a no-op. Like the existing Ctrl-D/Ctrl-K deletes, it
  pushes an undo entry and emits `:text_changed`. No kill-ring — this is a plain
  delete, consistent with how Ctrl-K was implemented.
- **Word character** — default is `\w` (`[A-Za-z0-9_]`), so **underscore counts
  as a word character** (`foo_bar` is one word), matching the widget's existing
  double-click word selection and emacs `prog-mode`. Everything else (spaces,
  punctuation, newlines) is a separator. Hosts wanting the stricter readline
  behavior (alphanumeric only) override via the seam below.
- **Multi-line** — newlines count as separators, and motion **crosses line
  boundaries** (as in emacs, where the whole buffer is one space). Alt-F at end
  of line moves into the next line's first word; Alt-B at start of line moves
  into the previous line's last word. At the very start/end of the document the
  motion is a no-op.
- **Selection** — plain Alt-F / Alt-B clear any active selection, consistent with
  how the existing Ctrl motions and unmodified arrows behave.

Worked example (`·` = cursor, `|` marks nothing — just prose): in
`foo.bar baz`, with the cursor at column 1 (`·foo.bar baz`), repeated Alt-F
stops after `foo` (`foo·.bar baz`), then after `bar` (`foo.bar· baz`), then after
`baz`. From the end, repeated Alt-B stops before `baz`, then before `bar`, then
before `foo`. Punctuation (`.`) is a separator, so `foo` and `bar` are distinct
words — standard emacs behavior.

## The seam — configurable word predicate

Requirement: "make the word boundary configurable if possible (leave a seam)."

Make the **word-character predicate** a single configurable value that is the one
source of truth for *all* word logic (new motions **and** existing double-click
selection), so the two never disagree.

- Represent it as a 1-arity predicate `(String.t() -> boolean())` over a single
  grapheme. Store it on `State` as `:word_char_fun` (or equivalent), defaulting
  to `&State.default_word_char?/1`, where `default_word_char?/1` wraps the
  current `~r/[\w]/` regex.
- Accept an override through `data` in `State.new/1`
  (e.g. `data.word_char_fun`), so a host can pass e.g.
  `fn g -> g =~ ~r/[\p{L}\p{N}]/ end` (Unicode letters+numbers, no underscore) to
  get macOS-Cocoa-ish word boundaries, or a stricter alphanumeric-only predicate
  to match readline exactly.
- Refactor the existing private `word_char?/1` and its callers so classification
  flows through the configured predicate rather than the hard-coded regex. Keep
  the public double-click API unchanged; only its internal notion of a word char
  becomes the configurable one.

This keeps the override tiny (one function) while covering the realistic tuning
knobs (Unicode-awareness, whether `_` is a word char, whether punctuation splits).

## Approach

1. **Word-boundary computation in `State`** — add a pure function that, given the
   current `state` (buffer `lines`, `cursor`, and the word predicate) and a
   direction, returns the target `{line, col}` cursor. This is the reusable core;
   it contains the skip-separators-then-skip-word-chars logic and the cross-line
   walk. Cursor coordinates are 1-indexed `{line, col}` where `col` ranges
   `1..String.length(line)+1` (same convention as the existing `move_cursor/2`).

2. **Wire into the motion seam** — add `move_cursor(state, :word_left)` and
   `move_cursor(state, :word_right)` clauses in the reducer that delegate to the
   `State` function and then call `State.ensure_cursor_visible/1`, mirroring the
   existing clauses.

3. **Key handlers** — add `process_input/2` clauses for Alt-F, Alt-B, and Alt-D,
   matching the shape of the Ctrl-motion / Ctrl-K clauses (accept `key_state > 0`
   so key-repeat works):
   - `{:key, {:key_f, key_state, [:alt]}}` → `move_cursor(:word_right)`, clear
     selection, `{:noop, …}`.
   - `{:key, {:key_b, key_state, [:alt]}}` → `move_cursor(:word_left)`, clear
     selection, `{:noop, …}`.
   - `{:key, {:key_d, key_state, [:alt]}}` → push undo, delete
     `[cursor, word_right target)`, emit `{:event, {:text_changed, …}}` — same
     shape as the Ctrl-D / Ctrl-K clauses.

4. **Word-kill deletion** — reuse the existing range-deletion machinery rather
   than writing a new one: compute the forward-word target with
   `State.word_motion_target(state, :word_right)`, then delete the range
   `[cursor, target)` via the same path `delete_selection/1` uses (e.g. set a
   transient `selection: {cursor, target}` and call `delete_selection/1`, or
   factor its body into a `delete_range/3`). Leaves the cursor at the original
   position.

5. **Suppress the macOS Option codepoint** — on macOS, Option+F/B/D also emit a
   composed codepoint (`ƒ`, `∫`, `∂`) carrying the `:alt` modifier. Add `:alt`
   **unconditionally** (all platforms) to `@command_mods` so
   `process_input_codepoint/2` drops Alt-modified codepoints instead of inserting
   the character. This is a deliberate, accepted tradeoff: Option-as-compose-key
   text entry (typing `ƒ`, `£`, `•`, …) no longer works in this field, which is
   the expected behavior for an emacs-bindings editor where `M-` is a command
   modifier.

## Changes

### `lib/components/text_field/state.ex`
- Add struct field `:word_char_fun` (default `&__MODULE__.default_word_char?/1`).
- Add `def default_word_char?(grapheme)` wrapping the existing `~r/[\w]/` regex.
- In `State.new/1`, read `Map.get(data, :word_char_fun, &default_word_char?/1)`.
- Refactor `word_char?/1` (and the `get_word_boundaries/2`, `find_word_start/2`,
  `find_word_end/2`, `extract_word_at/2` callers) to use the configured
  predicate, so double-click selection and word motions share one definition.
- Add `def word_motion_target(state, :word_left | :word_right) :: {line, col}` —
  the pure cross-line skip-separators-then-skip-word-chars computation returning
  the new cursor. This is the seam's core and the natural unit-test target.

### `lib/components/text_field/reducer.ex`
- Add `move_cursor/2` clauses for `:word_left` and `:word_right` delegating to
  `State.word_motion_target/2` + `State.ensure_cursor_visible/1`.
- Add `process_input/2` clauses for Alt-F (`:key_f`, `[:alt]`) and
  Alt-B (`:key_b`, `[:alt]`), near the Ctrl-motion clauses, clearing selection.
- Add a `process_input/2` clause for Alt-D (`:key_d`, `[:alt]`): push undo,
  delete `[cursor, word_right target)`, emit `:text_changed`.
- Add the range-delete helper (or reuse `delete_selection/1` with a transient
  selection) for the Alt-D kill.
- Add `:alt` to `@command_mods`.

### `test/` (new)
- Unit tests for `State.word_motion_target/2`: forward/backward within a line,
  across punctuation, across line boundaries, at document start/end (no-op),
  cursor mid-word, and with a **custom `word_char_fun`** to prove the seam works.
- Reducer-level test that an Alt-F / Alt-B `:key` event moves the cursor and
  clears an active selection.
- Reducer-level test that Alt-D deletes exactly the forward-word span (leaving
  the cursor put), is undoable, and is a no-op at end of document.

## Implementation notes (as-built)

Implemented on branch `jax-keyboard-handling` (base `10117c1`) in the fork checkout
`~/dev/forks/scenic-widget-contrib`, consumed by the parent app via `LOCAL_DEPS=1`.
Deviations from the spec above:

- **Alt-F/Alt-B reducer tests are dispatch-only.** The motions funnel through
  `move_cursor/2` → `State.ensure_cursor_visible/1`, which needs a real frame and
  loaded FontMetrics, so they cannot be asserted on a bare `%State{}` (the existing
  `text_field_reducer_test.exs` documents this same limitation for the Ctrl motions).
  Full motion semantics are instead covered exhaustively by the pure
  `State.word_motion_target/2` unit tests; the reducer test only asserts Alt-F/B are
  dispatched to a word motion. **Alt-D is asserted end-to-end** because its path
  (`push_undo` → `delete_selection` → `get_text`) stays off the render stack.
- **`:word_char_fun` defaults to `nil` in the struct** (a `defstruct` atom list gives
  every field a `nil` default). `word_predicate/1` falls back to `default_word_char?/1`
  when the field is `nil`, and `State.new/1` sets the default explicitly — so states
  built directly as `%State{}` (e.g. in tests) still get correct behavior.
- **Word-kill reuses `delete_selection/1`** via a transient selection (the "or factor
  into `delete_range/3`" alternative was not needed); this matches how the
  backspace/delete-selection handlers already delete a range.
- The `@command_mods` comment was expanded to explain the macOS Option/`:alt` tradeoff.

Tests: `test/components/text_field_word_motions_test.exs` (new) plus an extension of the
codepoint-guard test in `text_field_reducer_test.exs`. All pass (24 tests).

## Out of scope (future, but the seam makes them cheap)
- **Backward** word-kill (emacs `M-DEL` backward-kill-word) — mirror of Alt-D
  using the `:word_left` target. Left out; only Alt-D was requested.
- Alt+Shift+F/B **selection extension** (macOS-style). Could be added later via
  `move_cursor_with_selection(state, :word_right | :word_left)` matching the
  Shift+arrow pattern; left out per request.
