-- Editor/LSP tooling config only (teal-language-server, tl CLI). cosmic's own
-- build and --check-types do NOT read this file: checker options are set in
-- lib/cosmic/teal.tl (process_file/compile). Keep the two in sync by hand.
return {
  gen_target = "5.4",
  gen_compat = "off",
  include_dir = { "lib/types" },
  source_dir = ".",
  build_dir = "o/teal",
}
