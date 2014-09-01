defmodule SentryState do
  defstruct modules: [],
            src_dirs: [],
            src_dirs_options: %{},
            hrl_dirs: [],
            src_files: [],
            beam_lastmod: HashSet.new,
            src_file_lastmod: HashSet.new,
            hrl_file_lastmod: []

  @type t :: %SentryState{
    modules: [module],
    src_dirs: [String.t],
    src_dirs_options: [any],
    hrl_dirs: [String.t],
    src_files: [String.t],
    beam_lastmod: Set.t,
    src_file_lastmod: Set.t,
    hrl_file_lastmod: [{String.t, last_mod}]
  }

  @type last_mod :: {{integer, integer, integer}, {integer, integer, integer}}
end