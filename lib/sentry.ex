defmodule Sentry do
  use GenEvent

  def start do
    {:ok, x} = GenEvent.start([name: __MODULE__])
    # GenEvent.add_handler(x, __MODULE__, {})

    stream = GenEvent.stream(x)

    spawn_link fn ->
      1..100 |> Enum.each fn num ->
        GenEvent.notify(x, num)
      end
    end

    stream
    |> Stream.take(10)
    |> Enum.each(fn num -> IO.puts "HI" end)
  end

  def handle_event(event, state) do
    IO.puts event
    state
  end

  def handle_call(event, state) do
    IO.puts event
    state
  end

  @spec discover_modules :: [module]
  def discover_modules do
    modules          = (:erlang.loaded -- :sync_utils.get_system_modules)
    filtered_modules = :sync_scanner.filter_modules_to_scan(modules)
    filtered_modules
  end

  @spec discover_src_dirs([module]) :: {[String.t], [String.t]}
  def discover_src_dirs(modules) do
    {src_dirs, hrl_dirs} = Enum.reduce(modules, {[], []},
      fn elem, acc = {src_acc, hrl_acc} ->
        case :sync_utils.get_src_dir_from_module(elem) do
          {:ok, src_dir} ->
            {:ok, options} = :sync_utils.get_options_from_module(elem)
            :sync_options.set_options(src_dir, options)
            hrl_dir = :proplists.get_value(:i, Options, [])
            {[src_dir|src_acc], [hrl_dir|hrl_acc]}
          :undefined ->
            acc
        end
    end)

    {src_dirs |> Enum.uniq |> Enum.sort, hrl_dirs |> Enum.uniq |> Enum.sort }
  end


  @spec discover_src_files({[String.t], [String.t]}) :: {[String.t], [String.t]}
  def discover_src_files({src_dirs, hrl_dirs}) do
    {erl_files, ex_files} = Enum.reduce(src_dirs, [], fn elem, acc ->
      :sync_utils.wildcard(elem, ".*\\.erl$") ++
      :sync_utils.wildcard(elem, ".*\\.dtl$") ++
      :sync_utils.wildcard(elem, ".*\\.ex$") ++
      :sync_utils.wildcard(elem, ".*\\.exs$") ++ acc
    end)
    |> Enum.uniq
    |> Enum.sort
    |> Enum.partition(fn x ->
      String.ends_with(x, ".erl") or String.ends_with(x, ".dtl")
    end)

    hrl_files = Enum.reduce(hrl_dirs, [], fn elem, acc ->
      :sync_utils.wildcard(elem, ".*\\.hrl$") ++ acc
    end)
    |> Enum.uniq
    |> Enum.sort

    {erl_files, ex_files, hrl_files}
  end

  @spec compare_beams([module]) :: [String.t]
  def compare_beams(modules) do
    Enum.map(modules, fn x ->
      beam = :code.which(x)
      last_mod = :filelib.last_modified(beam)
      {x, last_mod}
    end)
    |> Enum.uniq
    |> Enum.sort
  end

  @spec compare_src_files([String.t]) :: [String.t]
  def compare_src_files(src_files) do
    Enum.map(src_files, fn x ->
      last_mod = :filelib.last_modified(x)
      {x, last_mod}
    end)
    |> Enum.uniq
    |> Enum.sort
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
    {compile_fun, module} = case :sync_utils.is_erldtl_template(src_file) do
      false ->
        {&(:compile.file/2), :erlang.list_to_atom(:filename.basename(src_file, ".erl"))}
      true ->
        {&(:erlydtl.compile/2), :erlang.list_to_atom(:lists.flatten(:filename.basename(src_file, ".dtl") ++ "_dtl"))}
    end

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

  def compare_hrl_files do
  end
end