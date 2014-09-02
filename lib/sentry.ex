defmodule Sentry do
  # use Application

  import SentryUtil

  # TODO: figure out how to get this in a supervision tree
  # TODO: test to make sure Mix.Project works when this is used
  # as a dependency

  # def start(_type, _args) do
  #   pid = case init do
  #     {:ok, pid} ->
  #       IO.puts("Starting Sentry (Automatic Code Compiler / Reloader\n")
  #       pid
  #     {:error, {:already_started, pid}} ->
  #       IO.puts("Sentry already started\n")
  #       pid
  #   end
  #   {:ok, pid}
  # end

  # TODO: split out streams and actual running stream code
  def init do
    {:ok, sentry_state_pid} = Agent.start_link(fn -> %SentryState{} end, name: __MODULE__)

    modules_stream = Stream.concat([:ok], Streamz.Time.interval(30_000))
    |> Stream.map(fn _x ->
      modules = discover_compiled_modules
      Agent.update(__MODULE__, fn state ->
        %SentryState{state | modules: modules}
      end)

      # Update beams in SentryState
      {_diff, _deleted} = compare_beams(sentry_state_pid, modules)

      modules
    end)

    src_dirs_stream = modules_stream
    |> Stream.map(fn modules ->
      src_dirs = discover_src_dirs(sentry_state_pid, modules)
      Agent.update(__MODULE__, fn state ->
        %SentryState{state | src_dirs: src_dirs}
      end)
      src_dirs
    end)

    src_files_stream = src_dirs_stream
    |> Stream.flat_map(fn dirs ->
      Stream.concat([:ok], Streamz.Time.interval(5000))
      |> Stream.take(6)
      |> Stream.map(fn _x ->
        {erl_files, ex_files} = discover_src_files(dirs)
        Agent.update(__MODULE__, fn state ->
          %SentryState{state | src_files: Enum.concat(erl_files,ex_files)}
        end)
        {erl_files, ex_files}
      end)
    end)

    compare_src_files_stream = Streamz.Time.interval(1_000)
    |> Stream.map(fn _x ->
      src_files = Agent.get(__MODULE__, fn state ->
        state.src_files
      end)
      {diff, _new_files} = compare_src_files(sentry_state_pid, src_files)

      # TODO: move this into a separate
      # case diff do
      #   [] ->
      #   [_h|_t] ->
      #     # TODO: split into multiple commands
      #     output = :os.cmd('mix do deps.compile, compile')
      # end

      diff
    end)

    compile_stream = compare_src_files_stream
    |> Stream.filter(&(!Enum.empty?(&1)))
    |> Stream.each(fn _ ->
      # TODO: allow user to choose what commands they want to execute
      # on source file change
      output = :os.cmd('mix do deps.compile, compile')
      IO.puts(output)
    end)

    # TODO: refactor streams
    compare_beams_stream = compare_src_files_stream
    |> Stream.filter(&(!Enum.empty?(&1)))
    |> Stream.map(fn _x ->

      previous_modules = Agent.get(__MODULE__, &(&1.modules))
      module_refresh = discover_compiled_modules

      modules_before_and_after = Stream.concat(previous_modules, module_refresh)
      |> Stream.uniq
      |> Enum.to_list

      Agent.update(__MODULE__, fn state ->
        %SentryState{state | modules: module_refresh}
      end)

      diff = compare_beams2(modules_before_and_after)

      case diff do
        [] ->
          :no_change
        [_h|_t] ->
          Enum.each(diff, fn {module, reason} ->
            case reason do
              :deleted ->
                # IO.puts("Module #{to_string(module)} has been removed from disk, purging from VM..")
                :code.purge(module)
              _ ->
                IO.puts("Loading #{to_string(module)}...")
                # TODO: allow user to select if they want soft purge
                # or hard purge
                :code.soft_purge(module)
                :code.load_file(module)
            end
          end)
          IO.puts("Successfully reloaded modules.")
          :reloaded
      end
    end)

    _pid = spawn_link(fn ->
      src_files_stream
      |> Stream.run
    end)

    spawn_link(fn ->
      compile_stream |> Stream.run
    end)

    spawn_link(fn ->
      compare_beams_stream
      |> Stream.map(&IO.inspect&1)
      |> Stream.run
    end)
  end

end