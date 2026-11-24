--- `cosmic --standalone <file.tl> [args...]`: runs one file against this
--- binary's own standard library, with no tree around it -- nothing
--- staged or built, no build directory written, and no staleness
--- check, so it runs the same whatever state the working directory
--- is in. The file may require `cosmic.*` modules only; it is
--- checked and compiled in memory (a clean compile is cached under
--- $XDG_CACHE_HOME/cosmic/standalone), then called as `run` calls
--- one -- its words in `arg` and the returned function's `argv` --
--- with a record's `main` field standing for a returned function.
--- `cosmic --standalone --check <file.tl>` only checks the file, as
--- a run does, and never calls it: it prints the refusals and exits 4,
--- as a run of a file that does not compile does. It exits 0 when there
--- are none, and 1 when it cannot read the file.
--- COSMIC_STANDALONE=1 makes `cosmic <file.tl>` run so
--- @public

local Flags = require("cosmic.flags")

local command: Flags.Command = {
  about = "run one file with no tree around it",
  usage = "[--check] <file.tl> [args]",
  examples = {
    { line = "script.tl", about = "run a file alone, against the standard library" },
    { line = "--check script.tl", about = "only check it" },
  },
}

return command
