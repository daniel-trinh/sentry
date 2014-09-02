defmodule SentryUtiltest do
  use ExUnit.Case

  test "discover_loaded_modules" do
    modules = SentryUtil.discover_loaded_modules
    assert Enum.member?(modules, SentryUtil) == true
  end

  test "discover_compiled_modules" do
    modules = SentryUtil.discover_compiled_modules
    assert Enum.member?(modules, SentryUtil) == true
  end

  test "discover_src_dirs" do
    {:ok, pid} = Agent.start_link(fn -> %SentryState{} end, name: Sentry)
    modules    = SentryUtil.discover_loaded_modules
    src_dirs   = SentryUtil.discover_src_dirs(pid, modules)

    Enum.each(src_dirs, fn x ->
      assert String.contains?(x, "/oss/sentry") == true
    end)
  end

  test "discover_src_files" do
    {:ok, pid} = Agent.start_link(fn -> %SentryState{} end, name: Sentry)
    modules    = SentryUtil.discover_loaded_modules
    dirs       = SentryUtil.discover_src_dirs(pid, modules)

    {erl_files, ex_files} = SentryUtil.discover_src_files(dirs)

    Enum.each(erl_files, fn x ->
      assert String.ends_with?(x, ".erl")
    end)
    Enum.each(ex_files, fn x ->
      assert String.ends_with?(x, ".ex") || String.ends_with?(x, ".exs") == true
    end)

    assert Enum.empty?(erl_files) == false
  end

  test "compare_src_files" do
    {:ok, pid} = Agent.start_link(fn -> %SentryState{} end, name: Sentry)

    modules = SentryUtil.discover_loaded_modules

    dirs                        = SentryUtil.discover_src_dirs(pid, modules)
    {erl_files, ex_files}       = SentryUtil.discover_src_files(dirs)
    {new_files_lastmods, _}     = SentryUtil.compare_src_files(pid, ex_files)
    {new_erl_files_lastmods, _} = SentryUtil.compare_src_files(pid, erl_files)

    Enum.each(new_files_lastmods, fn x ->
      {_dir, {{_year, _month, _day}, {_hour, _minute, _second}}} = x
    end)
    Enum.each(new_erl_files_lastmods, fn x ->
      {_dir, {{_year, _month, _day}, {_hour, _minute, _second}}} = x
    end)
  end

  test "discover_beam_files" do
    {erl_beams, ex_beams} = SentryUtil.discover_beam_files
    Enum.each(erl_beams, fn x ->
      assert String.match?(x,  ~r/.*ebin\/Elixir\.(.*)\.beam/) == false
      assert String.ends_with?(x, ".beam") == true
    end)
    Enum.each(ex_beams, fn x ->
      assert String.match?(x,  ~r/.*ebin\/Elixir\.(.*)\.beam/) == true
      assert String.ends_with?(x, ".beam") == true
    end)
  end
  test "module_from_beam_path" do
    {erl_beams, ex_beams} = SentryUtil.discover_beam_files
    Enum.each(erl_beams, fn x ->
      assert String.match?(x,  ~r/.*ebin\/Elixir\.(.*)\.beam/) == false
      assert String.ends_with?(x, ".beam") == true
    end)
    Enum.each(ex_beams, fn x ->
      assert String.match?(x,  ~r/.*ebin\/Elixir\.(.*)\.beam/) == true
      assert String.ends_with?(x, ".beam") == true
    end)
  end

  test "changed?" do
    assert SentryUtil.changed?(Enum) == :no_change
  end
end