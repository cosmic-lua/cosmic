--- Pinned before top-level make installs source resolution. Keep the explicit
--- list reviewable: coldbuild_test overlays only these shipped snapshots.
--- The compiler capsule is frozen before the first tree source is compiled.
local modules: {string} = {
  "_cli.args", "_cli.parse", "_make.startup",
  "_make.imports", "_make.project", "_make.root", "_make.types", "_make.validate",
  "cosmic.searcher", "cosmic._searcher_make", "cosmic._teal_project",
  "cosmic.flags", "cosmic.flags.command", "cosmic.flags.getopt",
  "cosmic.flags.parse", "cosmic.flags.types",
  "cosmic.errno", "cosmic.fd", "cosmic.fs", "cosmic.fs.dir", "cosmic.fs.file",
  "cosmic.fs.find", "cosmic.fs.octal", "cosmic.fs.ops", "cosmic.fs.path",
  "cosmic.fs.tree", "cosmic.fs.types", "cosmic.fs.walk", "cosmic.proc",
  "cosmic.proc.rusage", "cosmic.stream",
  "cosmic.teal", "cosmic._teal_engine", "cosmic._teal_hints", "tl",
  "cosmic._teal_ast", "cosmic._teal_discard", "cosmic._teal_types",
}

return {modules = modules}
