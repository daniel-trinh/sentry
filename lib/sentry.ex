defmodule Sentry do
  # use Application

  import SentryUtil

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
  def init do
    {:ok, sentry_state_pid} = Agent.start_link(fn -> %SentryState{} end, name: __MODULE__)

    modules_stream = Stream.concat([:ok], Streamz.Time.interval(30_000))
    |> Stream.map(fn _x ->
      modules = discover_loaded_modules
      Agent.update(__MODULE__, fn state ->
        %SentryState{state | modules: modules}
      end)

      # Update beams in SentryState
      {_diff, _deleted} = compare_beams(sentry_state_pid, modules)

      modules
    end)

    src_dirs_stream = modules_stream
    |> Stream.map(fn modules ->
      {src_dirs, hrl_dirs} = discover_src_dirs(sentry_state_pid, modules)
      Agent.update(__MODULE__, fn state ->
        %SentryState{state | src_dirs: src_dirs, hrl_dirs: hrl_dirs}
      end)
      {src_dirs, hrl_dirs}
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
      file_last_mods = Agent.get(__MODULE__, fn state ->
        state.src_files
      end)
      {diff, _new_files} = compare_src_files(sentry_state_pid, file_last_mods)

      case diff do
        [] ->
          :no_change
        [_h|_t] ->
          # TODO: split into multiple commands
          output = :os.cmd('mix do deps.compile, compile, dialyzer')
          IO.puts(output)
          :compiled
      end
    end)

    # TODO: refactor streams
    compare_beams_stream = compare_src_files_stream
    |> Stream.filter(&(&1 == :compiled))
    |> Stream.map(fn _x ->
      module_refresh = discover_loaded_modules

      beam_last_mods = Agent.update(__MODULE__, fn state ->
        %SentryState{state | modules: module_refresh}
      end)

      {diff, deleted, _new_beam_lastmod} = compare_beams(sentry_state_pid, module_refresh)
      case deleted do
        [] ->
          :no_change
        [_h|_t] ->
          IO.inspect(diff)
          Enum.each(diff, fn {{module, beam_path}, last_mod} ->
            IO.puts("Loading #{to_string(module)}...")
            IEx.Helpers.l(module)
          end)
          IO.puts("Successfully reloaded modules.")
          :reloaded
      end
    end)

    _pid = spawn_link(fn ->
      src_files_stream
      |> Stream.each(fn x -> IO.inspect(x) end)
      |> Stream.run
    end)

    spawn_link(fn ->
      compare_beams_stream
      |> Stream.map(&IO.inspect&1)
      |> Stream.run
    end)
  end

  def hello_world do
    "hi"
  end
end