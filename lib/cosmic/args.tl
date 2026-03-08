--- CLI option definitions for cosmic.
--- Shared by the dispatcher and tests to keep option lists in sync.

local getopt = require("cosmic.getopt")

--- Short options string for getopt (e.g. "e:l:ivEWh").
--- Options followed by ':' require an argument.
local shortopts = "e:l:ivEWh"

--- Long options table for getopt.
local longopts: {getopt.LongOpt} = {
  {name = "version", has_arg = "none", short = "v"},
  {name = "help", has_arg = "none", short = "h"},
  {name = "compile", has_arg = "required"},
  {name = "format", has_arg = "required"},
  {name = "check-format", has_arg = "required"},
  {name = "check-types", has_arg = "required"},
  {name = "check-style", has_arg = "required"},
  {name = "embed", has_arg = "required"},
  {name = "output", has_arg = "required"},
  {name = "extract", has_arg = "required"},
  {name = "check-examples", has_arg = "required"},
  {name = "examples", has_arg = "optional"},
  {name = "benchmark", has_arg = "required"},
  {name = "docs", has_arg = "optional"},
  {name = "welcome", has_arg = "none"},
  {name = "test", has_arg = "required"},
  {name = "report", has_arg = "none"},
  {name = "make", has_arg = "optional"},
  {name = "skill", has_arg = "required"},
  {name = "write-if-changed", has_arg = "none"},
  {name = "include-dir", has_arg = "required"},
}

return {
  shortopts = shortopts,
  longopts = longopts,
}
