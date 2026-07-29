defmodule WidgetWorkbench.ComponentBuilder do

  @doc """
  Creates a new GUI component by generating the necessary files.

  ## Parameters

    - `component_name`: The name of the new component as an atom or string.

  ## Example

      WidgetWorkbench.ComponentBuilder.build_new_component(:todo_list)
  """
  def build_new_component(component_name)
      when is_binary(component_name) do
    # when is_atom(component_name) or is_binary(component_name) do
    # Convert the component name to a string and format it
    component_name_str =
      component_name
      # |> to_string()
      |> String.replace(" ", "")
      |> Macro.camelize()

    # Prepare module and file names
    module_base = "ScenicWidgets.#{component_name_str}"
    file_base = Macro.underscore(component_name_str)

    # Define base paths (from flamelex!)
    base_path = "../scenic-widget-contrib/lib/components/#{file_base}"
    File.mkdir_p!(base_path)

    # List of files to create with their content generators
    files = [
      {Path.join(base_path, "#{file_base}_cmpnt.ex"), component_module_content(module_base)},
      {Path.join(base_path, "#{file_base}_state.ex"), state_module_content(module_base)},
      {Path.join(base_path, "#{file_base}_reducer.ex"), reducer_module_content(module_base)},
      {Path.join(base_path, "#{file_base}_mutator.ex"), mutator_module_content(module_base)},
      {Path.join(base_path, "#{file_base}_render.ex"), render_module_content(module_base)},
      {Path.join(base_path, "#{file_base}_user_input_handler.ex"),
       user_input_handler_content(module_base)}
    ]

    # Create each file with its content
    require Logger
    Enum.each(files, fn {file_path, content} ->
      if File.exists?(file_path) do
        Logger.warning("File already exists: #{file_path}")
      else
        File.write!(file_path, content)
        Logger.info("Created file: #{file_path}")
      end
    end)

    # TODO
    # now what would be amazingly ninja would be to add it to the radix state programatically...

    :ok

    %{
      module_base: module_base,
      file_base: file_base
    }
  end

  # Helper functions to generate file contents

  defp component_module_content(module_base) do
    """
    defmodule #{module_base} do
      @moduledoc \"\"\"
      A GUI component for #{humanize_module_name(module_base)}.
      \"\"\"

      use Scenic.Component
      require Logger
      alias Widgex.Frame
      alias Scenic.Graph
      alias Flamelex.Fluxus.RadixState
      alias #{module_base}
      alias #{module_base}.State
      alias #{module_base}.Render
      alias Flamelex.GUI.Utils.Draw

      # Validate function for Scenic component
      def validate(%{frame: %Frame{}} = data) do
        {:ok, data}
      end

      def init(scene, %{frame: %Frame{} = frame}, _opts) do
        state = Flamelex.Fluxus.RadixStore.get().apps.#{module_base |> Macro.underscore() |> String.split("/") |> List.last()}
        graph = Render.go(frame, state)

        init_scene =
          scene
          |> assign(frame: frame)
          |> assign(graph: graph)
          |> assign(state: state)
          |> push_graph(graph)

        Flamelex.Lib.Utils.PubSub.subscribe(topic: :radix_state_change)

        {:ok, init_scene}
      end

      # Handle state changes where the state hasn't changed
      def handle_info(
            {:radix_state_change, %{apps: %{#{module_base |> Macro.underscore() |> String.split("/") |> List.last()}: state}}},
            %{assigns: %{frame: frame, state: state}} = scene
          ) do
        # State variables in pattern match are the same; no state change occurred
        {:noreply, scene}
      end

      # Handle state changes where the state has changed
      def handle_info(
            {:radix_state_change, %{apps: %{#{module_base |> Macro.underscore() |> String.split("/") |> List.last()}: new_state}}},
            %{assigns: %{frame: frame, state: old_state}} = scene
          ) do
        # State has changed; raise an error as handling is app-specific
        raise "State change handling not implemented in template"
        {:noreply, scene}
      end
    end
    """
  end

  defp state_module_content(module_base) do
    """
    defmodule #{module_base}.State do
      @moduledoc \"\"\"
      State management for the #{humanize_module_name(module_base)} component.
      \"\"\"

      use StructAccess

      defstruct [
        # Define state fields here
      ]

      def new do
        %__MODULE__{}
      end
    end
    """
  end

  defp reducer_module_content(module_base) do
    """
    defmodule #{module_base}.Reducer do
      @moduledoc \"\"\"
      Processes actions and updates the Radix state for the #{humanize_module_name(module_base)} component.
      \"\"\"

      alias Flamelex.Fluxus.RadixState
      alias #{module_base}
      alias #{module_base}.Mutator

      def process(%RadixState{} = rdx, action) do
        case action do
          # Match on specific actions and call mutators
          _ ->
            rdx
        end
      end
    end
    """
  end

  defp mutator_module_content(module_base) do
    """
    defmodule #{module_base}.Mutator do
      @moduledoc \"\"\"
      Functions to mutate the Radix state for the #{humanize_module_name(module_base)} component.
      \"\"\"

      alias Flamelex.Fluxus.RadixState

      def some_mutation(%RadixState{} = rdx, params) do
        # Perform state mutation
        raise "not implemented"
      end
    end
    """
  end

  defp render_module_content(module_base) do
    """
    defmodule #{module_base}.Render do
      @moduledoc \"\"\"
      Functions to render the %Scenic.Graph{} for #{humanize_module_name(module_base)} component.
      \"\"\"

      alias #{module_base}.State
      alias Flamelex.Fluxus.RadixState
      alias Flamelex.GUI.Utils.Draw

      def go(%Widgex.Frame{} = f, %State{} = _state) do
        Scenic.Graph.build()
        |> Scenic.Primitives.group(
          fn graph ->
            graph
            |> Draw.background(f, :medium_slate_blue)
            |> Widgex.Frame.draw_guidewires(f)
            |> Scenic.Primitives.text("#{module_base}",
              font_size: 24,
              translate: {f.size.width / 2, f.size.height / 2}
            )
          end,
          translate: f.pin.point
        )
      end
    end
    """
  end

  defmodule Flamelex.GUI.Component.AgentHuddle.Render do
    alias Flamelex.GUI.Component.AgentHuddle.State
    alias Flamelex.GUI.Utils.Draw
  end

  defp user_input_handler_content(module_base) do
    """
    defmodule #{module_base}.UserInputHandler do
      @moduledoc \"\"\"
      Handles user input for the #{humanize_module_name(module_base)} component.
      \"\"\"

      require Logger
      use ScenicWidgets.ScenicEventsDefinitions
      alias #{module_base}
      alias #{module_base}.Reducer

      def handle(rdx, input) do
        case input do
          # Match on specific inputs and return actions
          _ ->
            Logger.warning("\#{__MODULE__} received unhandled input: \#{inspect(input)}")
            :ignore
        end
      end
    end
    """
  end

  # Helper function to humanize module names
  defp humanize_module_name(module_name) do
    module_name
    |> String.split(".")
    |> List.last()
    |> Macro.underscore()
    |> String.replace("_", " ")
    |> String.capitalize()
  end
end
