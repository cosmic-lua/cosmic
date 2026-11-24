--- `cosmic db [path...]`: what the three databases in the build
--- directory hold, each named by its path,
--- table by table -- rows, pages, bytes -- how the last few builds
--- went, and the slowest tests. Paths narrow it to the rows about the
--- sources under them -- a row whose file, module or source hash is
--- one under a path -- counted per table (coverage counting every run
--- kept, not only the latest), and the slowest of those tests. Pages,
--- bytes and builds are not per source, so a narrowed report leaves
--- them out. The tree is found as `test` finds it
--- @public

local Flags = require("cosmic.flags")

local command: Flags.Command = {
  about = "what the build directory's databases hold",
  usage = "[path...]",
  examples = {
    { line = "", about = "what the build directory's databases hold" },
    { line = "tally.tl", about = "only the rows about one source" },
  },
}

return command
