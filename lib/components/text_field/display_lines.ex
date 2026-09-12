defmodule ScenicWidgets.TextField.DisplayLines do
  @moduledoc """
  Pure display-line model for wrapped text.

  Owns the wrapping math and the mapping between two coordinate spaces:

    * **source** `{line, col}` — index into the buffer's logical `lines` plus the
      1-indexed column within that line. This stays the canonical cursor position
      on `%State{}`; editing and events all speak source coordinates.
    * **display** `{row, col}` — visual row index across the whole buffer (after
      wrapping) plus the 1-indexed column within that row. Used for navigation,
      scrolling, and drawing only; never persisted as the cursor.

  Computed on demand (no caching): a caller builds one `t()` per event or render
  pass with `compute/4` and threads it to the mapping helpers.

  Measurement is injected as a `measure` function (`String.t -> number`, pixel
  width) so this module never touches the font/render stack and stays directly
  unit-testable. In the component, `measure` is
  `fn text -> State.string_width(state, text) end`.
  """

  alias __MODULE__

  @enforce_keys [:measure]
  defstruct rows: [], meta: [], measure: nil

  @type row_meta :: %{
          source_line: pos_integer,
          first_of_source?: boolean,
          source_col_start: pos_integer
        }

  @type t :: %DisplayLines{
          rows: [String.t()],
          meta: [row_meta],
          measure: (String.t() -> number)
        }

  @doc """
  Build the display-line model for `lines` wrapped at `max_width` under `wrap_mode`.

  `measure` maps a string to its rendered pixel width. `max_width` is the text
  content width (the component uses `scroll.viewport_width - 40`). `wrap_mode` is
  `:none`, `:word`, or `:char`.
  """
  @spec compute([String.t()], (String.t() -> number), number, :none | :word | :char) :: t
  def compute(lines, measure, max_width, wrap_mode) when is_function(measure, 1) do
    {rows, meta} =
      lines
      |> Enum.with_index(1)
      |> Enum.reduce({[], []}, fn {line, source_line}, {rows_acc, meta_acc} ->
        segments = wrap_segments(line, measure, max_width, wrap_mode)
        {seg_rows, seg_meta} = annotate(segments, source_line, wrap_mode)
        {rows_acc ++ seg_rows, meta_acc ++ seg_meta}
      end)

    %DisplayLines{rows: rows, meta: meta, measure: measure}
  end

  @doc "Total number of display rows."
  @spec row_count(t) :: non_neg_integer
  def row_count(%DisplayLines{rows: rows}), do: length(rows)

  @doc "The text of display row `row` (1-indexed), or \"\" if out of range."
  @spec row_text(t, integer) :: String.t()
  def row_text(%DisplayLines{rows: rows}, row), do: Enum.at(rows, row - 1, "")

  @doc """
  Map a source cursor `{line, col}` to display `{row, col}`.

  `col` is clamped into the containing row; a column at a word-wrap boundary lands
  at the end of the earlier row (mirrors the renderer's original behavior).
  """
  @spec source_to_display(t, {pos_integer, pos_integer}) :: {pos_integer, pos_integer}
  def source_to_display(%DisplayLines{} = t, {line, col}) do
    case indexed_rows_for(t, line) do
      [] ->
        {1, 1}

      rows_for_line ->
        {row_idx, row, m} =
          Enum.find(rows_for_line, List.last(rows_for_line), fn {_i, r, m} ->
            col <= m.source_col_start + String.length(r)
          end)

        dcol =
          (col - m.source_col_start + 1)
          |> max(1)
          |> min(String.length(row) + 1)

        {row_idx, dcol}
    end
  end

  @doc """
  Map a display position `{row, col}` back to a source cursor `{line, col}`.

  `row` and `col` are clamped into range, so callers can hand in an off-the-end
  target (e.g. a click below the last row) without special-casing.
  """
  @spec display_to_source(t, {integer, integer}) :: {pos_integer, pos_integer}
  def display_to_source(%DisplayLines{rows: rows, meta: meta}, {row, col}) do
    n = length(rows)
    row = row |> max(1) |> min(max(n, 1))

    case {Enum.at(rows, row - 1), Enum.at(meta, row - 1)} do
      {r, m} when is_binary(r) and is_map(m) ->
        col = col |> max(1) |> min(String.length(r) + 1)
        {m.source_line, m.source_col_start + col - 1}

      _ ->
        {1, 1}
    end
  end

  @doc "Visual x (pixels) of display position `{row, col}` — width of the row text before `col`."
  @spec x_of(t, {integer, integer}) :: number
  def x_of(%DisplayLines{measure: measure} = t, {row, col}) do
    text = row_text(t, row)
    text_before = String.slice(text, 0, max(0, col - 1))
    measure.(text_before)
  end

  @doc """
  Column on display `row` whose position is nearest visual x `x` (pixels).

  Same character-walk semantics as the click hit-test: within a character, snaps
  to whichever edge is closer.
  """
  @spec col_at_x(t, integer, number) :: pos_integer
  def col_at_x(%DisplayLines{measure: measure} = t, row, x) do
    text = row_text(t, row)
    walk_to_x(String.graphemes(text), measure, x, 0, 1)
  end

  # ===== internals =====

  defp indexed_rows_for(%DisplayLines{rows: rows, meta: meta}, line) do
    [rows, meta]
    |> Enum.zip()
    |> Enum.with_index(1)
    |> Enum.map(fn {{r, m}, i} -> {i, r, m} end)
    |> Enum.filter(fn {_i, _r, m} -> m.source_line == line end)
  end

  # Attach source-column metadata to one source line's wrapped segments. Word wrap
  # consumes a single space at each boundary, so the next row starts one column
  # further along than its text length alone; char wrap consumes nothing.
  defp annotate(segments, source_line, wrap_mode) do
    consumed_between = if wrap_mode == :word, do: 1, else: 0

    {rows, meta, _} =
      segments
      |> Enum.with_index(0)
      |> Enum.reduce({[], [], 0}, fn {seg, idx}, {rows, meta, source_start} ->
        m = %{
          source_line: source_line,
          first_of_source?: idx == 0,
          source_col_start: source_start + 1
        }

        next_start = source_start + String.length(seg) + consumed_between
        {rows ++ [seg], meta ++ [m], next_start}
      end)

    {rows, meta}
  end

  defp wrap_segments(line, _measure, _max_width, :none), do: [line]

  defp wrap_segments(line, measure, max_width, :word) do
    if measure.(line) <= max_width, do: [line], else: wrap_by_words(line, measure, max_width)
  end

  defp wrap_segments(line, measure, max_width, :char) do
    if measure.(line) <= max_width, do: [line], else: wrap_by_chars(line, measure, max_width)
  end

  defp wrap_by_words(line, measure, max_width) do
    line
    |> String.split(" ")
    |> Enum.reduce({[], ""}, fn word, {wrapped, current} ->
      test = if current == "", do: word, else: current <> " " <> word

      cond do
        measure.(test) <= max_width -> {wrapped, test}
        current == "" -> {wrapped ++ [word], ""}
        true -> {wrapped ++ [current], word}
      end
    end)
    |> flush_current()
  end

  defp wrap_by_chars(line, measure, max_width) do
    line
    |> String.graphemes()
    |> Enum.reduce({[], ""}, fn char, {chunks, current} ->
      test = current <> char

      cond do
        measure.(test) <= max_width -> {chunks, test}
        current == "" -> {chunks ++ [char], ""}
        true -> {chunks ++ [current], char}
      end
    end)
    |> flush_current()
  end

  defp flush_current({segments, current}) do
    segments = if current == "", do: segments, else: segments ++ [current]
    if segments == [], do: [""], else: segments
  end

  defp walk_to_x([], _measure, _x, _cur, col), do: col

  defp walk_to_x([char | rest], measure, x, cur, col) do
    next = cur + measure.(char)

    if x < next do
      mid = cur + (next - cur) / 2
      if x < mid, do: col, else: col + 1
    else
      walk_to_x(rest, measure, x, next, col + 1)
    end
  end
end
