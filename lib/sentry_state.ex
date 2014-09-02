defmodule SentryState do
  defstruct modules: [],
            src_dirs: [],
            src_dirs_options: %{},
            src_files: [],
            beam_lastmod: HashSet.new,
            src_file_lastmod: HashSet.new

  @type t :: %SentryState{
    modules: [module],
    src_dirs: [String.t],
    src_dirs_options: [any],
    src_files: [String.t],
    beam_lastmod: Set.t,
    src_file_lastmod: Set.t
  }

  @type last_mod :: {{integer, integer, integer}, {integer, integer, integer}}
end