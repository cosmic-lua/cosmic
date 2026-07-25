-- Editor/LSP tooling config only (teal-language-server, tl CLI). cosmic's own
-- build and --check-types do NOT read this file: checker options are set in
-- lib/cosmic/teal.tl (process_file/compile). teal_config_test.tl fails if
-- this mirror drifts from cosmic.teal's compiled-in defaults or from the
-- Makefile's INCLUDE_DIRS, so the editor resolves cosmic.* and cosmo.*
-- exactly like the build does.
return {
  gen_target = "5.4",
  gen_compat = "off",
  include_dir = {"lib", "lib/types"},
  source_dir = ".",
  build_dir = "o/teal",
}
