-- Editor/LSP tooling config only (teal-language-server, tl CLI). cosmic's own
-- build and --check types do NOT read this file: checker options are set in
-- cosmic/teal.tl (process_file/compile). teal_config_test.tl fails if this
-- mirror drifts from cosmic.teal's include dirs, so the editor resolves
-- cosmic.* and cosmo.* exactly like the build does.
--
-- o/_types/types_gen is GENERATED and not committed: `cosmic --make build`
-- (or any graph verb) writes it. A fresh clone's editor cannot resolve
-- cosmo.* until it has built once.
return {
  gen_target = "5.4",
  gen_compat = "off",
  include_dir = {".", "o/_types/types_gen"},
  source_dir = ".",
  build_dir = "o/teal",
}
