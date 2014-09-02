defmodule SentryUtil do
  @type change_type :: :deleted | :updated | :no_change | :added

  @doc """
    Returns a list of modules that have been compiled
    in the umbrella Mix project.
  """
  @spec discover_compiled_modules :: [module]
  def discover_compiled_modules do
    {erl_beams, ex_beams} = discover_beam_files
    Enum.map(erl_beams ++ ex_beams, &module_from_beam_path(&1))
  end

  # TODO: figure out if it's possible to just use the Mix.Project
  # methods for determining src dirs
  @spec discover_src_dirs(pid, [module]) :: [String.t]
  def discover_src_dirs(agent_pid, modules) do
    {src_dirs, _hrl_dirs} = Enum.reduce(modules, {[], []},
      fn elem, acc = {src_acc, hrl_acc} ->
        case :sync_utils.get_src_dir_from_module(elem) do
          {:ok, src_dir} ->
            {:ok, options} = :sync_utils.get_options_from_module(elem)

            Agent.update(agent_pid, fn state ->
              %SentryState{state | src_dirs_options: options}
            end)

            hrl_dir = :proplists.get_value(:i, options, [])
            {[to_string(src_dir)|src_acc], [to_string(hrl_dir)|hrl_acc]}
          :undefined ->
            acc
        end
    end)

    src_dirs |> Enum.uniq |> Enum.sort
  end

  @spec discover_src_files([String.t]) :: {[String.t], [String.t]}
  def discover_src_files(src_dirs) do
    {erl_files, ex_files} = Enum.reduce(src_dirs, [], fn dir, acc ->
      :sync_utils.wildcard(dir, ".*\\.erl$") ++
      :sync_utils.wildcard(dir, ".*\\.ex$") ++
      :sync_utils.wildcard(dir, ".*\\.exs$") ++ acc
    end)
    |> Enum.uniq
    |> Enum.sort
    |> Enum.partition(fn x ->
      String.ends_with?(x, ".erl")
    end)

    {erl_files, ex_files}
  end

  @doc """
  Intended to be run directly after a compile attempt.
  """
  @spec discover_beam_files :: {[String.t], [String.t]}
  def discover_beam_files do
    # TODO: figure out if this needs to be a macro
    build_path = Mix.Project.build_path
    deps_path  = Mix.Project.deps_path

    build_beams = :sync_utils.wildcard(build_path, ".*\\.beam")
    deps_beams  = :sync_utils.wildcard(deps_path, ".*\\.beam")

    beams = build_beams ++ deps_beams

    {erl_beams, ex_beams} = Enum.partition(beams, fn beam_file_path ->
      !String.match?(beam_file_path, ~r/.*ebin\/Elixir\.(.*)\.beam/)
    end)

    {erl_beams, ex_beams}
  end

  @spec module_from_beam_path(String.t) :: module | nil
  def module_from_beam_path(beam_file) do
    case Regex.named_captures(~r/.*ebin\/(?<module_name>.*)\.beam/, beam_file) do
      captures when is_map(captures) ->
        case Map.get(captures, "module_name") do
          nil -> nil
          module_name -> String.to_atom(module_name)
        end
      nil -> nil
    end
  end

  @spec compare_beams(pid, [module]) :: {
    [{{module, String.t}, SentryState.last_mod}],
    [{{module, String.t}, SentryState.last_mod}]
  }
  def compare_beams(agent_pid, modules) do

   new_beam_lastmod = modules
    |> Stream.map(&({&1, :code.which(&1)}))
    |> Stream.filter(fn {_module, beam_path} -> beam_path != :non_existing end)
    |> Stream.map(fn {module, beam_path} ->
      last_mod = :filelib.last_modified(beam_path)
      {{module, beam_path}, last_mod}
    end)
    |> Enum.into(HashSet.new)

    prev_beam_lastmod = Agent.get(agent_pid, fn state ->
      state.beam_lastmod
    end)

    Agent.update(agent_pid, fn state ->
      %SentryState{state | beam_lastmod: new_beam_lastmod}
    end)

    diff = Set.difference(new_beam_lastmod, prev_beam_lastmod)
    |> Enum.into([])

    # If beam files existed before and are now gone, the
    # module has been removed
    deleted = Set.difference(prev_beam_lastmod, new_beam_lastmod)
    |> Enum.into([])
    {diff, deleted}
  end

  @spec compare_beams2([module]) :: [{module, change_type}]
  def compare_beams2(modules) do
    modules 
    |> Stream.map(&({&1, changed?(&1)}))
    |> Stream.filter(&(elem(&1, 1) != :no_change))
    |> Enum.to_list
  end

  @doc """
  Compare the beam code of a module that is currently loaded
  to the VM, with the beam code of the same module on disk.

  Returns :added if the module has been recently added
  """
  @spec changed?(module) :: change_type
  def changed?(module) do

    loaded_version = try do
      module_version(module.module_info)
    catch _, _ ->
      :error
    end

    current_version = try do
      module_version(:code.get_object_code(module))
    catch _, _ ->
      :error
    end

    case {loaded_version, current_version} do
      # The loaded in VM version doesn't exist, so
      # the last compile most likely added this module
      {:error, vsn} when is_list(vsn) ->
        :added
      # The current beam version from disk.. doesn't exist, so
      # the last compile most likely removed it
      {vsn, :error} when is_list(vsn) ->
        :deleted
      # Module probably doesn't exist
      {:error, :error} ->
        :no_change
      # No diff from loaded VM beam and disk VM beam, nothing
      # happened
      {loaded_vsn, current_vsn} when loaded_vsn == current_vsn ->
        :no_change
      # Most likely a newly compiled version of this module has been made
      {loaded_vsn, current_vsn} when loaded_vsn != current_vsn ->
        :updated
    end
  end

  defp module_version({m, beam, _f}) do
    {:ok, {^m, vsn}} = :beam_lib.version(beam)
    vsn
  end
  defp module_version(l) when is_list(l) do
    {_, attrs} = :lists.keyfind(:attributes, 1, l)
    {_, vsn} = :lists.keyfind(:vsn, 1, attrs)
    vsn
  end

  @doc """
  Given a GenEvent with Sentry handler, and a list of source files,
  this will compare the last stored source files (if any), and return
  `{diff, new_files}`, where diff is the Set.union - Set.intersection of
  the previous stored source files state and the given source files.

  TODO: make sure deleted files are captured somehow, so a recompile
  can happen to remove beams that don't exist anymore
  """
  @spec compare_src_files(pid, [String.t]) :: {[{String.t, SentryState.last_mod}], %{}}
  def compare_src_files(agent_pid, src_files) do
    new_files = Stream.map(src_files, fn file_path ->
      last_mod = :filelib.last_modified(file_path)
      {file_path, last_mod}
    end)
    |> Enum.into(HashSet.new)

    prev_files = Agent.get(agent_pid, fn state ->
      state.src_file_lastmod
    end)

    Agent.update(agent_pid, fn state ->
      %SentryState{state | src_file_lastmod: new_files}
    end)
    diff = Set.difference(new_files, prev_files) |> Enum.into([])

    {diff, new_files}
  end
end