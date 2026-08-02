defmodule ScenicWidgets.CursorPosLabel do
  @moduledoc """
  A tiny "Ln X, Col Y" label that follows a store-backed text buffer.

  This component is the store architecture in miniature: it subscribes to a
  `Scenic.PubSub` source publishing buffer snapshots (the same source a
  store-backed TextField renders from) and re-renders its label on every
  snapshot. It holds no other state, talks to no other process, and the
  host scene is not involved after creation — the status line is just
  another subscriber.

  ## Data

      %{
        frame:  %Widgex.Frame{},   # required — label area (text right-aligned)
        source: atom,              # required — Scenic.PubSub source of buffer snapshots
        font: %{name: atom, size: number} | nil,   # optional (default :roboto 13)
        color: color | nil         # optional (default dim grey)
      }

  Snapshots are expected to carry `cursors: [%{line: l, col: c} | _]`
  (the Quillex `BufState` shape).
  """
  use Scenic.Component, has_children: false
  require Logger

  alias Scenic.Graph
  import Scenic.Primitives

  @default_color {160, 160, 170}
  @default_font %{name: :roboto, size: 13}

  @impl Scenic.Component
  def validate(%{frame: %{pin: _, size: _}, source: source} = data) when is_atom(source) do
    {:ok, data}
  end

  def validate(data) do
    {:error, "CursorPosLabel requires :frame and :source, got: #{inspect(data)}"}
  end

  @impl Scenic.Scene
  def init(scene, data, _opts) do
    font = Map.get(data, :font) || @default_font
    color = Map.get(data, :color) || @default_color

    scene =
      scene
      |> assign(frame: data.frame, font: font, color: color, cursor: {1, 1})

    graph = render(scene.assigns)
    scene = scene |> assign(graph: graph) |> push_graph(graph)

    # Subscribing re-delivers the source's retained snapshot, so the label
    # is correct immediately even if it was created mid-session.
    Scenic.PubSub.subscribe(data.source)

    {:ok, scene}
  end

  def handle_info({{Scenic.PubSub, :data}, {_source, buf_state, _ts}}, scene) do
    cursor =
      case buf_state do
        %{cursors: [%{line: l, col: c} | _]} -> {l, c}
        _ -> scene.assigns.cursor
      end

    if cursor == scene.assigns.cursor do
      {:noreply, scene}
    else
      scene = assign(scene, cursor: cursor)
      graph = render(scene.assigns)
      {:noreply, scene |> assign(graph: graph) |> push_graph(graph)}
    end
  end

  def handle_info({{Scenic.PubSub, :registered}, _}, scene), do: {:noreply, scene}
  def handle_info({{Scenic.PubSub, :unregistered}, _}, scene), do: {:noreply, scene}

  defp render(%{frame: frame, font: font, color: color, cursor: {line, col}}) do
    %{size: %{width: w, height: h}} = frame

    Graph.build()
    |> text("Ln #{line}, Col #{col}",
      translate: {w - 8, h / 2 + font.size / 3},
      text_align: :right,
      font: font.name,
      font_size: font.size,
      fill: color,
      id: :cursor_pos_text
    )
  end
end
