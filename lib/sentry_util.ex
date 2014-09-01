defmodule SentryUtil do
  @type change_type :: :deleted | :updated | :no_change | :added

  @spec discover_loaded_modules :: [module]
  def discover_loaded_modules do
    modules          = (:erlang.loaded -- :sync_utils.get_system_modules)
    filtered_modules = :sync_scanner.filter_modules_to_scan(modules)
    filtered_modules
  end

  @spec discover_src_dirs(pid, [module]) :: {[String.t], [String.t]}
  def discover_src_dirs(agent_pid, modules) do
    {src_dirs, hrl_dirs} = Enum.reduce(modules, {[], []},
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

  def discover_beam_files do
    build_path = Mix.Project.build_path
    deps_path  = Mix.Project.deps_path

    build_beams = :sync_utils.wildcard(build_path, ".*\\.beam")
    deps_beams  = :sync_utils.wildcard(deps_path, ".*\\.beam")

    beams = build_beams ++ deps_beams

    {erl_beams, ex_beams} = Enum.partition(beams, fn beam_file_path ->
      String.starts_with?(beam_file_path, "Elixir.")
    end)

    {erl_beams, ex_beams}
  end

  def module_name_from_beam_file(beam_file) do
  end

  @spec compare_beams(pid, [module]) :: {
    [{{module, String.t}, SentryState.last_mod}],
    [{{module, String.t}, SentryState.last_mod}]
  }
  def compare_beams(agent_pid, modules) do
   new_beam_lastmod = modules
    |> Stream.map(&({&1, :code.which(&1)}))
    |> Stream.filter(fn {module, beam_path} -> beam_path != :non_existing end)
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
    catch _ ->
      :error
    end

    current_version = try do
      module_version(:code.get_object_code(module))
    catch _ ->
      :error
    end

    case {loaded_version, current_version} do
      {:error, vsn} when is_list(vsn) ->
        :added
      {vsn, :error} when is_list(vsn) ->
        :deleted
      {:error, :error} ->
        :no_change
      {loaded_vsn, current_vsn} when loaded_vsn == current_vsn ->
        :no_change
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

  defp process_beam_lastmod(a, b) do
    process_beam_lastmod(a, b, {:undefined, []})
  end
  defp process_beam_lastmod([{module, last_mod}|t1], [{module, last_mod}|t2], acc) do
    # Beam hasn't changed, do nothing...
    process_beam_lastmod(t1, t2, acc)
  end
  defp process_beam_lastmod([{module, _}|t1], [{module, _}|t2], {first_beam, other_beams}) do
    # Beam has changed, reload...
    acc1 = case :code.get_object_code(module) do
        :error ->
            msg = "Error loading object code for #{IO.inspect(module)}\n"
            :sync_scanner.log_errors(msg)
            {first_beam, other_beams}
        {module, binary, filename} ->
            :code.load_binary(module, filename, binary)
            # TODO: add patching

            # Print a status message...
            msg = "#{IO.inspect(module)}: Reloaded! (Beam changed.)\n"
            :sync_scanner.log_success(msg)
            case first_beam do
               :undefined -> {module, other_beams}
               _ -> {first_beam, [module | other_beams] }
            end
    end
    process_beam_lastmod(t1, t2, acc1)
  end
  defp process_beam_lastmod([{module1, last_mod1}|t1], [{module2, last_mod2}|t2], acc) do
    # Lists are different, advance the smaller one...
    case module1 < module2 do
        true ->
            process_beam_lastmod(t1, [{module2, last_mod2}|t2], acc)
        false ->
            process_beam_lastmod([{module1, last_mod1}|t1], t2, acc)
    end
  end
  defp process_beam_lastmod([], [], acc) do
    msg_add = "."
    # Done.
    case acc do
        {:undefined, []} ->
            :nop # nothing changed
        {first_beam, []} ->
            # Print a status message...
            :sync_scanner.growl_success("Reloaded #{to_string(first_beam)}#{msg_add}")
            # TODO: add shit to this
            :sync_scanner.fire_onsync([first_beam])
        {first_beam, n} ->
            # Print a status message...
            :sync_scanner.growl_success("Reloaded #{to_string(first_beam)} and #{:erlang.length(n)} other beam files.")
            # TODO: add shit to this
            :sync_scanner.fire_onsync([first_beam | n])
    end
    :ok
  end
  defp process_beam_lastmod(:undefined, _other, _) do
    # First load, do nothing.
    :ok
  end

  # TODO: instead of using sorted lists, maybe use maps instead for comparing files?
  def process_src_file_lastmod([{file, last_mod}|t1], [{file, last_mod} | t2]) do
    # Beam hasn't changed, do nothing
    process_src_file_lastmod(t1, t2)
  end
  def process_src_file_lastmod([{file, _}|t1], [{file, _}|t2]) do
    # File has changed, recompile...
    recompile_src_file(file)
    process_src_file_lastmod(t1, t2)
  end
  def process_src_file_lastmod([{file1, last_mod1}|t1], [{file2, last_mod2}|t2]) do
    # Lists are different...
    case file1 < file2 do
      # File was removed, do nothing...
      true ->
        process_src_file_lastmod(t1, [{file2, last_mod2}|t2])
      false ->
        maybe_recompile_src_file(file2, last_mod2)
        process_src_file_lastmod([{file1, last_mod1}|t1], t2)
    end
  end
  def process_src_file_lastmod([], [{file, last_mod}|t2]) do
    maybe_recompile_src_file(file, last_mod)
    process_src_file_lastmod([], t2)
  end
  def process_src_file_lastmod([], [], _) do
    # Done.
    :ok
  end
  def process_src_file_lastmod(:undefined, _Other, _) do
    # First load, do nothing.
    :ok
  end

  @spec recompile_src_file(String.t) :: :ok
  def recompile_src_file(src_file) do
    # Get the module, src dir, and options...
    {:ok, src_dir} = :sync_utils.get_src_dir(src_file)
    {compile_fun, module} = {&(:compile.file/2), String.to_atom(:filename.basename(src_file, ".erl"))}

    # Get the old binary code...
    old_binary = case :code.get_object_code(module) do
      {^module, b, _filename} -> b
      _ -> :undefined
    end

    case :sync_options.get_options(src_dir) do
      {:ok, options} ->
        case compile_fun.(src_file, [:binary, :return|options]) do
          {:ok, module, ^old_binary, warnings} ->
            # Compiling didn't change the beam code. Don't reload...
            :sync_scanner.print_results(module, src_file, [], warnings)
            {:ok, [], warnings}
          {:ok, module, _binary, warnings} ->
            # Compiling changed the beam code. Compile and reload.
            compile_fun.(src_file, options)
            case :code.ensure_loaded(module) do
              {:module, ^module} -> :ok
              {:error, :embedded} ->
                # Module is not yet loaded, load it.
                case :code.load_file(module) do
                  {:module, ^module} -> :ok
                end
            end

            # compare beamz use genevent

            :sync_scanner.print_results(module, src_file, [], warnings)
            {:ok, [], warnings}
          {:error, errors, warnings} ->
            ## compiling failed. print the warnings and errors...
            :sync_scanner.print_results(module, src_file, errors, warnings)
        end
      :undefined ->
        msg = "Unable to determine options for #{IO.inspect src_file}"
        :sync_scanner.log_errors(msg)
    end
  end

  @spec maybe_recompile_src_file(String.t, any) :: :ok
  def maybe_recompile_src_file(file, last_mod) do
    module = :erlang.list_to_atom(:filename.basename(file, ".erl"))

    case :code.which(module) do
      beam_file when is_list(beam_file) ->
        case :filelib.last_modified(beam_file) do
          beam_last_mod when last_mod > beam_last_mod ->
            recompile_src_file(file)
          _ ->
            :ok
        end
      _ ->
        # File is new, recompile...
        recompile_src_file(file)
    end
  end

  def compare_hrl_files(hrl_files, hrl_file_lastmod, src_files) do
    new_hrl_file_last_mod = Enum.map(hrl_files, fn x ->
      last_mod = :file_lib.last_modified(x)
      {x, last_mod}
    end)
    |> Enum.uniq
    |> Enum.sort

    process_hrl_file_lastmod(hrl_file_lastmod, new_hrl_file_last_mod, src_files)
  end

  def process_hrl_file_lastmod([{file, last_mod}|t1], [{file, last_mod}|t2], src_files) do
    # Hrl hasn't changed, do nothing...
    process_hrl_file_lastmod(t1, t2, src_files)
  end
  def process_hrl_file_lastmod([{file, _}|t1], [{file, _}|t2], src_files) do
    # File has changed, recompile...
    who_include = :sync_scanner.who_include(file, src_files)
    Enum.each(who_include, fn src_file ->
      recompile_src_file(src_file)
    end)
    process_hrl_file_lastmod(t1, t2, src_files)
  end
  def process_hrl_file_lastmod([{file1, last_mod1}|t1], [{file2, last_mod2}|t2], src_files) do
    # Lists are different...
    case file1 < file2 do
        true ->
            # File was removed, do nothing...
            who_include = :sync_scanner.who_include(file1, src_files)
            case who_include do
                [] -> :ok
                _ ->
                  src_file_string = Enum.map(who_include, fn file ->
                    :filename.basename(file)
                  end)
                  IO.puts "Warning. Deleted #{IO.inspect :filename.basename(file1)} file included in existing src files: #{IO.inspect src_file_string}"
            end
            process_hrl_file_lastmod(t1, [{file2, last_mod2}|t2], src_files)
        false ->
            # file is new, look for src that include it
            who_include = :sync_scanner.who_include(file2, src_files)
            Enum.each(who_include, fn src_file ->
              maybe_recompile_src_file(src_file, last_mod2)
            end)
            process_hrl_file_lastmod([{file1, last_mod1}|t1], t2, src_files)
    end
  end
  def process_hrl_file_lastmod([], [{file, _LastMod}|t2], src_files) do
    # file is new, look for src that include it
    who_include = :sync_scanner.who_include(file, src_files)
    Enum.each(who_include, fn src_file ->
      recompile_src_file(src_file)
    end)

    process_hrl_file_lastmod([], t2, src_files)
  end
  def process_hrl_file_lastmod([], [], _) do
    # Done
    :ok
  end
  def process_hrl_file_lastmod(:undefined, _Other, _) do
    # First load, do nothing
    :ok
  end
end