defmodule ScenicWidgets.TextField do
  @moduledoc """
  A multi-line text field component with support for both direct and external input modes.

  ## Features
  - Multi-line and single-line modes
  - Optional line numbers
  - Blinking cursor
  - Configurable fonts and colors
  - Transparent background support
  - Undo/redo support
  - Text selection and clipboard operations

  ## Input Modes - IMPORTANT!

  TextField supports three input modes that fundamentally change how it receives input.
  **Choosing the wrong mode will cause input routing problems!**

  ### `:direct` (default)

  TextField calls `request_input/2` and handles all keyboard input directly.
  The component receives `:key` and `:codepoint` events from Scenic.

  **Use when:** TextField is the primary/only text input in your scene.
  **Examples:** Simple forms, standalone text editors, Widget Workbench demos.

  ```elixir
  %{frame: frame, input_mode: :direct}  # or just omit, it's the default
  ```

  **⚠️ WARNING:** In `:direct` mode, TextField will intercept ALL keyboard input,
  including keyboard shortcuts! If your app has shortcuts like `space+k` that should
  be handled at the root scene level, those shortcuts will NOT work while TextField
  has focus because TextField grabs the keystrokes first.

  ### `:external`

  TextField does NOT request or handle keyboard input. It only renders text.
  The parent application is responsible for:
  1. Receiving keyboard input at a higher level (e.g., RootScene)
  2. Processing that input through its own state management (e.g., Fluxus/Redux)
  3. Updating the underlying buffer
  4. TextField re-renders when it receives buffer updates via PubSub

  **Use when:** Your app has its own input routing/state management system.
  **Examples:** Flamelex Kommander, Vim-mode editors, apps with global keyboard shortcuts.

  ```elixir
  %{frame: frame, input_mode: :external}
  ```

  **Flow in external mode:**
  ```
  Keyboard → RootScene → Fluxus/Redux → Buffer.Process → PubSub → TextField (render only)
  ```

  ### `:buffer_backed`

  TextField syncs with a Buffer.Process for state management.
  Similar to `:direct` but delegates state to an external buffer.

  **Use when:** You want TextField to handle input but persist to a buffer process.
  **Examples:** QuillEx editor buffers with undo/redo managed by buffer.

  ```elixir
  %{frame: frame, input_mode: :buffer_backed, buffer_controller: pid, buffer_topic: topic}
  ```

  ## Line Modes

  - `:multi_line` (default) - Enter key inserts newline
  - `:single_line` - Enter key emits `{:enter_pressed, id, text}` event (for command bars)

  ## Basic Usage

      # Simple text editor (direct mode)
      graph
      |> TextField.add_to_graph(
        %{
          frame: Widgex.Frame.new(pin: {100, 100}, size: {400, 300}),
          initial_text: "Hello World!",
          input_mode: :direct
        },
        id: :my_editor
      )

      # Command bar in an app with global shortcuts (external mode)
      graph
      |> TextField.add_to_graph(
        %{
          frame: frame,
          mode: :single_line,
          input_mode: :external  # App routes input through its own system
        },
        id: :command_bar
      )

  ## Events (direct/buffer_backed modes only)

  - `{:text_changed, id, full_text}` - Text content changed
  - `{:focus_gained, id}` - TextField gained focus
  - `{:focus_lost, id}` - TextField lost focus
  - `{:enter_pressed, id, text}` - Enter pressed (single-line mode only)
  - `{:escape_pressed, id}` - Escape pressed
  - `{:save_requested, id, text}` - Ctrl+S pressed
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

    # For buffer_backed mode, subscribe to buffer updates and fetch initial state
    state = if state.input_mode == :buffer_backed and state.buffer_topic do
      # Subscribe to buffer PubSub updates
      IO.puts("🔔 TextField init: subscribing to buffer_topic=#{inspect(state.buffer_topic)}")
      if Code.ensure_loaded?(Quillex.Utils.PubSub) do
        result = Quillex.Utils.PubSub.subscribe(topic: state.buffer_topic)
        IO.puts("🔔 TextField init: subscribe result=#{inspect(result)}")
      else
        IO.puts("⚠️ TextField init: Quillex.Utils.PubSub NOT loaded!")
      end

      # Fetch initial state from buffer if controller is available
      state = if state.buffer_controller do
        case GenServer.call(state.buffer_controller, :get_state, 5000) do
          {:ok, buf_state} ->
            # Extract state from buffer
            cursor = case buf_state.cursors do
              [%{line: l, col: c} | _] -> {l, c}
              _ -> {1, 1}
            end
            # Convert selection from buffer format %{start: ..., end: ...} to TextField format {start, end}
            selection = case buf_state.selection do
              %{start: start_pos, end: end_pos} -> {start_pos, end_pos}
              nil -> nil
              other -> other  # Pass through if already in tuple format
            end
            %{state |
              lines: buf_state.data,
              cursor: cursor,
              selection: selection,
              # In buffer_backed mode, we don't need local undo stacks
              undo_stack: [],
              redo_stack: []
            }
          _ ->
            state
        end
      else
        state
      end
      state
    else
      state
    end

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

    # Request input for direct mode or buffer_backed mode
    # Only request keyboard input if editable - otherwise just register for mouse/scroll
    # This prevents read-only TextFields from stealing keyboard input
    if state.input_mode in [:direct, :buffer_backed] do
      if state.editable do
        # Full input for editable fields
        request_input(scene, [:cursor_button, :cursor_pos, :key, :codepoint, :cursor_scroll])
      else
        # Only mouse/scroll for read-only fields (allows clicking, scrolling, but no typing)
        request_input(scene, [:cursor_button, :cursor_pos, :cursor_scroll])
      end
    end

    scene =
      scene
      |> assign(state: state, graph: graph)
      |> push_graph(graph)

    # Note: We don't use capture_input here because it steals input globally,
    # preventing shortcuts like space+k from reaching RootScene.
    # request_input (called above) is sufficient for normal TextField operation.

    {:ok, scene}
  end

  # ===== INPUT HANDLING (Phase 2) =====

  def handle_input(input, _context, scene) do
    state = scene.assigns.state

    # CRITICAL: Only process keyboard input if focused AND editable
    # This prevents unfocused/read-only TextFields from stealing input
    # (e.g., buffer pane shouldn't receive input when search bar is open,
    #  read-only HyperCards shouldn't capture keyboard input)
    case input do
      # Keyboard input - only process if focused AND editable
      {:key, _} when not state.focused or not state.editable ->
        {:noreply, scene}

      {:codepoint, _} when not state.focused or not state.editable ->
        {:noreply, scene}

      # Mouse/scroll input - always process (for clicks, scrolling)
      # But don't allow gaining focus if not editable
      _ ->
        do_handle_input(input, scene)
    end
  end

  defp do_handle_input(input, scene) do
    state = scene.assigns.state

    # For buffer_backed mode, route input to Buffer.Process
    if state.input_mode == :buffer_backed do
      handle_buffer_backed_input(input, scene)
    else
      # Original direct mode handling
      handle_direct_mode_input(input, scene)
    end
  end

  # Handle input for buffer_backed mode - send actions to Buffer.Process
  defp handle_buffer_backed_input(input, scene) do
    state = scene.assigns.state

    action = Reducer.input_to_buffer_action(state, input)
    # Debug: log shift+arrow inputs
    case input do
      {:key, {:key_left, _, mods}} when mods != [] -> IO.puts("🔑 DEBUG: Shift+Left input=#{inspect(input)} -> action=#{inspect(action)}")
      {:key, {:key_right, _, mods}} when mods != [] -> IO.puts("🔑 DEBUG: Shift+Right input=#{inspect(input)} -> action=#{inspect(action)}")
      _ -> :ok
    end

    case action do
      nil ->
        # No action to send (e.g., unhandled key)
        {:noreply, scene}

      {:clipboard_copy, text} ->
        # Copy is handled locally (clipboard is a system thing)
        copy_to_system_clipboard(text)
        {:noreply, scene}

      {:clipboard_cut, text} ->
        # Cut: copy to clipboard and send delete action to buffer
        copy_to_system_clipboard(text)
        if state.buffer_controller do
          GenServer.cast(state.buffer_controller, {:action, [{:delete, :selection}]})
        end
        {:noreply, scene}

      {:clipboard_paste} ->
        # Paste: get clipboard text and send insert action to buffer
        clipboard_text = paste_from_system_clipboard()
        if state.buffer_controller && clipboard_text != "" do
          GenServer.cast(state.buffer_controller, {:action, [{:insert, clipboard_text, :at_cursor}]})
        end
        {:noreply, scene}

      {:local_update, new_state} ->
        # Some updates (like focus, scrollbar drag) are handled locally
        update_scene(scene, state, new_state)

      {:click_move_cursor, new_state, action} ->
        # Click updates focus locally and sends cursor move to buffer
        if state.buffer_controller do
          GenServer.cast(state.buffer_controller, {:action, [action]})
        end
        update_scene(scene, state, new_state)

      {:drag_select, new_state, action} ->
        # Drag selection updates cursor locally and sends selection to buffer
        if state.buffer_controller do
          GenServer.cast(state.buffer_controller, {:action, [action]})
        end
        update_scene(scene, state, new_state)

      {:double_click_select, new_state, action} ->
        # Double-click word selection - send selection action to buffer
        if state.buffer_controller do
          GenServer.cast(state.buffer_controller, {:action, [action]})
        end
        update_scene(scene, state, new_state)

      {:find_requested, id} ->
        # Emit find_requested event to parent scene
        send_parent_event(scene, {:find_requested, id})
        {:noreply, scene}

      :save ->
        # Emit save_requested event to parent scene
        send_parent_event(scene, {:save_requested, state.id, State.get_text(state)})
        {:noreply, scene}

      action when is_tuple(action) or is_atom(action) ->
        # Send action to buffer controller
        if state.buffer_controller do
          GenServer.cast(state.buffer_controller, {:action, [action]})
        end
        {:noreply, scene}  # Wait for buffer broadcast to update
    end
  end

  # Handle input for direct mode (original implementation)
  defp handle_direct_mode_input(input, scene) do
    state = scene.assigns.state

    case Reducer.process_input(state, input) do
      {:noop, ^state} ->
        {:noreply, scene}

      {:noop, new_state} ->
        update_scene(scene, state, new_state)

      {:event, {:clipboard_copy, _id, text}, new_state} ->
        # Copy to system clipboard
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
        {:event, event_data, final_state} = Reducer.process_action(new_state, {:insert_text, clipboard_text})
        send_parent_event(scene, event_data)
        update_scene(scene, state, final_state)

      {:event, event_data, new_state} ->
        IO.puts("📤 TextField: Sending event to parent: #{inspect(event_data)}")
        send_parent_event(scene, event_data)
        update_scene(scene, state, new_state)
    end
  end

  # ===== EXTERNAL CONTROL (Phase 3) =====

  @doc """
  Handle action messages from parent scene.
  Actions are processed by the Reducer and may emit events.
  In buffer_backed mode, actions are forwarded to Buffer.Process.
  """
  def handle_put({:action, action}, scene) do
    state = scene.assigns.state

    if state.input_mode == :buffer_backed and state.buffer_controller do
      # Forward action to Buffer.Process - wait for broadcast to update
      GenServer.cast(state.buffer_controller, {:action, [action]})
      {:noreply, scene}
    else
      # Direct mode - process locally
      case Reducer.process_action(state, action) do
        {:noop, new_state} ->
          update_scene(scene, state, new_state)

        {:event, event_data, new_state} ->
          send_parent_event(scene, event_data)
          update_scene(scene, state, new_state)
      end
    end
  end

  def handle_put(text, scene) when is_bitstring(text) do
    # Text replacement - also move cursor to end of text
    lines = String.split(text, "\n")
    last_line = length(lines)
    last_col = String.length(List.last(lines) || "") + 1

    state = %{scene.assigns.state |
      lines: lines,
      cursor: {last_line, last_col}  # Move cursor to end
    }
    send_parent_event(scene, {:text_changed, scene.assigns.state.id, text})
    update_scene(scene, scene.assigns.state, state)
  end

  def handle_put(:focus, scene) do
    # Focus the text field
    state = %{scene.assigns.state | focused: true}
    update_scene(scene, scene.assigns.state, state)
  end

  def handle_put(:blur, scene) do
    # Blur the text field
    state = %{scene.assigns.state | focused: false}
    update_scene(scene, scene.assigns.state, state)
  end

  def handle_put(%{editable: editable} = opts, scene) do
    # Update editable and optionally focused state
    state = scene.assigns.state

    # Handle cursor blink timer when editable changes
    new_timer = if editable != state.editable do
      if editable and state.cursor_timer == nil do
        # Becoming editable - start blink timer
        {:ok, timer} = :timer.send_interval(state.cursor_blink_rate, :blink)
        timer
      else if not editable and state.cursor_timer != nil do
        # Becoming read-only - stop blink timer
        :timer.cancel(state.cursor_timer)
        nil
      else
        state.cursor_timer
      end
      end
    else
      state.cursor_timer
    end

    # When entering edit mode, ensure cursor starts visible
    cursor_visible = if editable and not state.editable do
      true  # Always start with cursor visible when entering edit mode
    else
      state.cursor_visible
    end

    new_state = %{state |
      editable: editable,
      focused: Map.get(opts, :focused, state.focused),
      cursor_timer: new_timer,
      cursor_visible: cursor_visible
    }

    # CRITICAL: When editable changes, update input registration
    # If becoming editable, request keyboard input; if becoming read-only, release it
    if editable != state.editable and state.input_mode in [:direct, :buffer_backed] do
      if editable do
        # Now editable - request keyboard input
        request_input(scene, [:cursor_button, :cursor_pos, :key, :codepoint, :cursor_scroll])
      else
        # Now read-only - only need mouse/scroll (release keyboard)
        # Note: Scenic doesn't have release_input, but re-requesting with fewer types works
        request_input(scene, [:cursor_button, :cursor_pos, :cursor_scroll])
      end
    end

    update_scene(scene, state, new_state)
  end

  # ===== CURSOR BLINK TIMER =====

  @doc """
  Handle cursor blink timer message.
  """
  def handle_info(:blink, scene) do
    state = scene.assigns.state

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

  @doc """
  Handle buffer state updates (for buffer_backed mode).
  When Buffer.Process broadcasts state changes, update TextField to match.
  """
  def handle_info({:buf_state_changes, buf_state}, scene) do
    state = scene.assigns.state

    # Debug: log selection updates
    if buf_state.selection != nil do
      IO.puts("📥 TextField received buf_state_changes: selection=#{inspect(buf_state.selection)}")
    end

    # Only process if we're in buffer_backed mode
    if state.input_mode == :buffer_backed do
      # Extract cursor from buffer state
      cursor = case buf_state.cursors do
        [%{line: l, col: c} | _] -> {l, c}
        _ -> state.cursor
      end

      # Convert selection from buffer format %{start: ..., end: ...} to TextField format {{line, col}, {line, col}}
      selection = case buf_state.selection do
        %{start: %{line: sl, col: sc}, end: %{line: el, col: ec}} ->
          {{sl, sc}, {el, ec}}
        nil -> nil
        other -> other  # Pass through if already in tuple format
      end

      # Get new search state
      new_search_query = Map.get(buf_state, :search_query, state.search_query)
      new_search_matches = Map.get(buf_state, :search_matches, state.search_matches)
      new_search_index = Map.get(buf_state, :search_current_index, state.search_current_index)

      # Update local state from buffer
      new_state = %{state |
        lines: buf_state.data,
        cursor: cursor,
        selection: selection,
        search_query: new_search_query,
        search_matches: new_search_matches,
        search_current_index: new_search_index
      }

      # Update scroll content size when lines change (critical for horizontal scrolling)
      # This ensures the scroll state knows the actual content dimensions
      new_state = if state.lines != buf_state.data do
        Reducer.update_scroll_content_size(new_state)
      else
        new_state
      end

      # Emit search_complete if search results changed
      old_matches = state.search_matches || []
      new_matches = new_search_matches || []
      # Always emit when we have a search query and match count changes
      if new_search_query != nil do
        old_count = length(old_matches)
        new_count = length(new_matches)
        IO.puts("📊 Match count check: query=#{inspect(new_search_query)}, old=#{old_count}, new=#{new_count}")
        if old_count != new_count do
          send_parent_event(scene, {:search_complete, state.id, new_search_query, new_count})
        end
      end

      # Emit search_navigated if index changed
      if new_search_index != state.search_current_index and new_search_query != nil do
        total = length(new_matches)
        send_parent_event(scene, {:search_navigated, state.id, new_search_index, total})
      end

      # Ensure cursor is visible after update
      new_state = State.ensure_cursor_visible(new_state)

      update_scene(scene, state, new_state)
    else
      {:noreply, scene}
    end
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
