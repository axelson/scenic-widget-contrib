defmodule ScenicWidgets.TextField do
  @moduledoc """
  A multi-line text field component with support for both direct and external input modes.

  ## Features (Phase 1)
  - Multi-line and single-line modes
  - Optional line numbers
  - Blinking cursor
  - Configurable fonts and colors
  - Transparent background support

  ## Usage

      # Minimal configuration
      graph
      |> TextField.add_to_graph(
        %{
          frame: Widgex.Frame.new(pin: {100, 100}, size: {400, 300}),
          initial_text: "Hello World!\\nType here..."
        },
        id: :my_text_field
      )

      # With line numbers
      graph
      |> TextField.add_to_graph(
        %{
          frame: frame,
          initial_text: "line 1\\nline 2\\nline 3",
          show_line_numbers: true,
          mode: :multi_line
        },
        id: :code_editor
      )

  ## Input Modes

  ### Direct Mode (default)
  TextField handles keyboard input directly (Phase 2).
  Good for: forms, simple text editors, Widget Workbench.

  ### External Mode
  Parent scene controls all input via `handle_put/2` (Phase 3).
  Good for: Flamelex, vim-mode editors, complex applications.

  ## Events (Phase 2+)

  - `{:text_changed, id, full_text}` - Text content changed
  - `{:focus_gained, id}` - TextField gained focus
  - `{:focus_lost, id}` - TextField lost focus
  - `{:enter_pressed, id, text}` - Enter pressed (single-line mode only)
  """

  use Scenic.Component, has_children: false
  require Logger

  alias ScenicWidgets.TextField.{State, Renderer, Reducer}
  alias Scenic.Graph

  # ===== VALIDATION =====

  @doc """
  Validate TextField initialization data.

  Accepts:
  - Widgex.Frame directly (Widget Workbench passes this)
  - Map with :frame key containing Widgex.Frame
  """
  def validate(%Widgex.Frame{} = frame) do
    # Widget Workbench passes frame directly - wrap it in a map
    {:ok, %{frame: frame}}
  end

  def validate(%{frame: %Widgex.Frame{}} = data) do
    {:ok, data}
  end

  def validate(data) do
    {:error, "TextField requires Widgex.Frame or map with :frame. Got: #{inspect(data)}"}
  end

  # ===== LIFECYCLE =====

  @doc """
  Initialize the TextField component.
  """
  def init(scene, data, _opts) do
    # Create initial state
    state = State.new(data)

    # Render initial graph
    graph = Renderer.initial_render(Graph.build(), state)

    # Start cursor blink timer (only if editable)
    {:ok, timer} = if state.editable do
      :timer.send_interval(state.cursor_blink_rate, :blink)
    else
      {:ok, nil}
    end

    # Update state with timer reference
    state = %{state | cursor_timer: timer}

    # Phase 2: Request input if in direct mode
    if state.input_mode == :direct do
      # Include :cursor_pos for scrollbar drag support
      request_input(scene, [:cursor_button, :cursor_pos, :key, :codepoint, :cursor_scroll])
    end

    scene =
      scene
      |> assign(state: state, graph: graph)
      |> push_graph(graph)

    {:ok, scene}
  end

  # ===== INPUT HANDLING (Phase 2) =====

  def handle_input(input, _context, scene) do
    state = scene.assigns.state

    # Debug ALL key input
    # case input do
    #   {:key, {key, 1, mods}} ->
    #     IO.puts("🔍 TextField.handle_input received: #{inspect(key)} with mods #{inspect(mods)}, focused: #{state.focused}")
    #   _ -> :ok
    # end

    case Reducer.process_input(state, input) do
      {:noop, ^state} ->
        {:noreply, scene}

      {:noop, new_state} ->
        update_scene(scene, state, new_state)

      {:event, {:clipboard_copy, _id, text}, new_state} ->
        # Copy to system clipboard
        IO.puts("📋 COPYING TO CLIPBOARD: #{inspect(text)}")
        copy_to_system_clipboard(text)
        send_parent_event(scene, {:clipboard_copy, state.id, text})
        update_scene(scene, state, new_state)

      {:event, {:clipboard_cut, _id, text}, new_state} ->
        # Cut to system clipboard
        copy_to_system_clipboard(text)
        send_parent_event(scene, {:clipboard_cut, state.id, text})
        update_scene(scene, state, new_state)

      {:event, {:clipboard_paste_requested, _id}, new_state} ->
        # Get text from system clipboard and paste it
        clipboard_text = paste_from_system_clipboard()
        IO.puts("📋 PASTING FROM CLIPBOARD: #{inspect(clipboard_text)}")
        {:event, event_data, final_state} = Reducer.process_action(new_state, {:insert_text, clipboard_text})
        send_parent_event(scene, event_data)
        update_scene(scene, state, final_state)

      {:event, event_data, new_state} ->
        send_parent_event(scene, event_data)
        update_scene(scene, state, new_state)
    end
  end

  # ===== EXTERNAL CONTROL (Phase 3) =====

  # def handle_put({:action, action_type, data}, scene) do
  #   state = scene.assigns.state
  #
  #   case Reducer.process_action(state, {action_type, data}) do
  #     {:noop, new_state} ->
  #       update_scene(scene, state, new_state)
  #
  #     {:event, event_data, new_state} ->
  #       send_parent_event(scene, event_data)
  #       update_scene(scene, state, new_state)
  #   end
  # end
  #
  # def handle_put(text, scene) when is_bitstring(text) do
  #   # Simple text replacement
  #   state = %{scene.assigns.state | lines: String.split(text, "\n")}
  #   send_parent_event(scene, {:text_changed, scene.assigns.state.id, text})
  #   update_scene(scene, scene.assigns.state, state)
  # end

  # ===== CURSOR BLINK TIMER =====

  @doc """
  Handle cursor blink timer message.
  """
  def handle_info(:blink, scene) do
    state = scene.assigns.state

    # Debug: Check if blink is changing focus
    if not state.focused do
      # IO.puts("🔍 BLINK with focused=false!")
    end

    # Toggle cursor visibility
    new_state = %{state | cursor_visible: !state.cursor_visible}

    # Update only the cursor (efficient partial update)
    graph = Renderer.update_cursor_visibility(scene.assigns.graph, new_state)

    scene =
      scene
      |> assign(state: new_state, graph: graph)
      |> push_graph(graph)

    {:noreply, scene}
  end

  # ===== HANDLE CAST (for Scenic input routing) =====

  @doc """
  Handle input sent via GenServer.cast from Scenic.
  This is how Scenic delivers input when a component requests it.
  """
  def handle_cast({:user_input, input}, scene) do
    # Forward to handle_input
    handle_input(input, nil, scene)
  end

  # ===== HELPER FUNCTIONS =====

  defp update_scene(scene, old_state, new_state) do
    if old_state.focused != new_state.focused do
      # IO.puts("🔍 FOCUS CHANGED in update_scene: #{old_state.focused} -> #{new_state.focused}")
      # IO.puts("🔍 Stacktrace: #{inspect(Process.info(self(), :current_stacktrace), limit: 5)}")
    end

    graph = Renderer.update_render(scene.assigns.graph, old_state, new_state)

    scene =
      scene
      |> assign(state: new_state, graph: graph)
      |> push_graph(graph)

    {:noreply, scene}
  end

  # ===== CLIPBOARD HELPERS =====

  defp copy_to_system_clipboard(text) do
    case :os.type() do
      {:unix, :darwin} ->
        # macOS - use Port to pipe text to pbcopy
        case System.find_executable("pbcopy") do
          nil -> {:error, "pbcopy not found"}
          path ->
            port = Port.open({:spawn_executable, path}, [:binary])
            send(port, {self(), {:command, text}})
            send(port, {self(), :close})
            receive do
              {^port, :closed} -> :ok
            after
              5000 -> {:error, "Clipboard operation timed out"}
            end
        end

      {:unix, _} ->
        # Linux - try xclip
        case System.find_executable("xclip") do
          nil ->
            {:error, "xclip not found"}
          path ->
            port = Port.open({:spawn_executable, path}, [:binary, args: ["-selection", "clipboard"]])
            send(port, {self(), {:command, text}})
            send(port, {self(), :close})
            receive do
              {^port, :closed} -> :ok
            after
              5000 -> {:error, "Clipboard operation timed out"}
            end
        end

      {:win32, _} ->
        # Windows - use clip.exe
        case System.find_executable("clip") do
          nil -> {:error, "clip not found"}
          path ->
            port = Port.open({:spawn_executable, path}, [:binary])
            send(port, {self(), {:command, text}})
            send(port, {self(), :close})
            receive do
              {^port, :closed} -> :ok
            after
              5000 -> {:error, "Clipboard operation timed out"}
            end
        end

      _ ->
        Logger.warning("Clipboard copy not supported on this OS")
        {:error, "Unsupported OS"}
    end
  end

  defp paste_from_system_clipboard() do
    case :os.type() do
      {:unix, :darwin} ->
        # macOS
        {text, 0} = System.cmd("pbpaste", [])
        text

      {:unix, _} ->
        # Linux - try xclip
        case System.find_executable("xclip") do
          nil ->
            Logger.warning("xclip not found, clipboard paste not available")
            ""
          _ ->
            {text, 0} = System.cmd("xclip", ["-selection", "clipboard", "-o"])
            text
        end

      {:win32, _} ->
        # Windows - powershell Get-Clipboard
        {text, 0} = System.cmd("powershell", ["-command", "Get-Clipboard"])
        text

      _ ->
        Logger.warning("Clipboard paste not supported on this OS")
        ""
    end
  end

  # ===== SCENIC CALLBACKS =====

  @doc """
  Handle fetch requests - returns the full TextField state.
  This allows parent scenes to retrieve the TextField's current state
  before rebuilding graphs (e.g., on window resize).

  Returns: `{:ok, %ScenicWidgets.TextField.State{}}`
  """
  @impl Scenic.Scene
  def handle_fetch(_from, scene) do
    {:reply, {:ok, scene.assigns.state}, scene}
  end
end
