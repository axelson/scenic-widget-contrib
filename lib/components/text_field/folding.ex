defmodule ScenicWidgets.TextField.Folding do
  @moduledoc "Pure indentation-fold calculations used by TextField view state."

  @type folds :: MapSet.t(pos_integer())

  def foldable?(lines, line) do
    with current when is_binary(current) <- Enum.at(lines, line - 1),
         {_next_line, next} <- next_nonblank(lines, line + 1) do
      indent(next) > indent(current)
    else
      _ -> false
    end
  end

  def toggle(lines, folds, line) do
    cond do
      MapSet.member?(folds, line) -> MapSet.delete(folds, line)
      foldable?(lines, line) -> MapSet.put(folds, line)
      true -> folds
    end
  end

  def unfold_all, do: MapSet.new()

  def fold_to_level(lines, level) when level in 1..4 do
    lines
    |> Enum.with_index(1)
    |> Enum.reduce(MapSet.new(), fn {_text, line}, acc ->
      if foldable?(lines, line) and indentation_level(lines, line) < level,
        do: MapSet.put(acc, line),
        else: acc
    end)
  end

  @doc "Return `{source_line, text, folded_child_count}` visible rows."
  def projection(lines, folds) do
    do_projection(lines, folds, 1, []) |> Enum.reverse()
  end

  def expand_to_line(lines, folds, target) do
    Enum.reduce(folds, folds, fn header, acc ->
      if target in hidden_range(lines, header), do: MapSet.delete(acc, header), else: acc
    end)
  end

  def reconcile_after_edit(folds, old_lines, new_lines) do
    if length(old_lines) == length(new_lines), do: folds, else: MapSet.new()
  end

  defp do_projection(lines, _folds, line, acc) when line > length(lines), do: acc

  defp do_projection(lines, folds, line, acc) do
    text = Enum.at(lines, line - 1)

    if MapSet.member?(folds, line) and foldable?(lines, line) do
      range = hidden_range(lines, line)

      do_projection(lines, folds, Enum.max(range, fn -> line end) + 1, [
        {line, text, Enum.count(range)} | acc
      ])
    else
      do_projection(lines, folds, line + 1, [{line, text, 0} | acc])
    end
  end

  defp hidden_range(lines, header) do
    base = lines |> Enum.at(header - 1, "") |> indent()

    last =
      (header + 1)..length(lines)
      |> Enum.reduce_while(header, fn line, previous ->
        text = Enum.at(lines, line - 1, "")

        if String.trim(text) == "" or indent(text) > base,
          do: {:cont, line},
          else: {:halt, previous}
      end)

    if last > header, do: (header + 1)..last, else: []
  end

  defp next_nonblank(lines, line) do
    if line > length(lines) do
      nil
    else
      line..length(lines)
      |> Enum.find_value(fn n ->
        text = Enum.at(lines, n - 1, "")
        if String.trim(text) != "", do: {n, text}
      end)
    end
  end

  defp indentation_level(lines, line) do
    width = lines |> Enum.at(line - 1, "") |> indent()
    div(width, 2)
  end

  defp indent(text) do
    text
    |> String.to_charlist()
    |> Enum.reduce_while(0, fn
      ?\s, n -> {:cont, n + 1}
      ?\t, n -> {:cont, n + 4}
      _, n -> {:halt, n}
    end)
  end
end
