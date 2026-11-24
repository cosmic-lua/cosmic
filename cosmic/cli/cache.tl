--- `cosmic cache trim compiles PATH --since-ns N` keeps supported compile
--- and parse rows last used at or after N, a Unix nanosecond timestamp.
--- `trim verdicts PATH... --since-ns N` keeps an unreached cache whole;
--- `--whole` instead preserves all active verdict rows without vacuuming.
--- Paths are explicit and absolute. This running binary owns the formats
--- and never discovers, stages or rebuilds the candidate project.
--- Unknown schemas and unreadable files are retained. `--restored PATH`
--- compares retained compile keys against a pre-run snapshot without
--- deleting that snapshot. `--json` prints one versioned report with
--- per-file results, a complete canonical save digest when available,
--- and the fresh compile count when requested and established.
--- Writers must remain stopped through maintenance and the caller's save.
--- An incomplete WAL checkpoint, read or write suppresses the save digest.
--- Exit 0 means complete, 1 incomplete maintenance, and 2 a refused command
--- line. Diagnostics go to stderr; no summary is printed.
--- @public

local Flags = require("cosmic.flags")

local since: Flags.Option = { value = "N", about = "keep rows used at or after this Unix nanosecond timestamp",
  integer = { min = 0 } }
local json: Flags.Option = { about = "print one versioned JSON maintenance report" }

local command: Flags.Command = {
  about = "trim the shared caches named",
  usage = "trim <compiles|verdicts> ...",
  examples = {
    { line = "trim compiles --since-ns 1700000000000000000 /var/cache/cosmic/compiles.db", about = "drop compile rows last used before that time" },
  },
  subcommands = {
    trim = {
      about = "trim the cache files named",
      usage = "<compiles|verdicts> ...",
      subcommands = {
        compiles = {
          about = "keep the compile and parse rows used since a time",
          usage = "--since-ns N [--restored PATH] [--json] PATH",
          spec = {
            ["--since-ns"] = since,
            ["--restored"] = { value = "PATH", about = "compare retained compile keys with this snapshot" },
            ["--json"] = json,
          },
        },
        verdicts = {
          about = "keep the verdict rows used since a time, or all of them",
          usage = "(--since-ns N | --whole) [--json] PATH...",
          spec = {
            ["--since-ns"] = since,
            ["--whole"] = { about = "keep verdict rows whole, without vacuuming" },
            ["--json"] = json,
          },
        },
      },
    },
  },
}

return command
