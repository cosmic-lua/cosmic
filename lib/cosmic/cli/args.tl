--- CLI option definitions for cosmic.
--- Shared by the dispatcher and tests to keep option lists in sync.

local getopt = require("cosmic.getopt")

--- Short options string for getopt (e.g. "e:l:ivEWh").
--- Options followed by ':' require an argument.
--- `-c` is make's shell contract: `$(SHELL) $(.SHELLFLAGS) '<line>'`
--- with `.SHELLFLAGS` defaulting to `-c`, so `SHELL := cosmic` works
--- with no further configuration.
local shortopts = "c:e:l:ivEWh"

--- Long options table for getopt.
local longopts: {getopt.LongOpt} = {
  {name = "version", has_arg = "none", short = "v"},
  {name = "help", has_arg = "none", short = "h"},
  {name = "compile", has_arg = "required"},
  {name = "compile-strict", has_arg = "required"},
  {name = "format", has_arg = "required"},
  {name = "fix", has_arg = "required"},
  {name = "check-format", has_arg = "required"},
  {name = "check-types", has_arg = "required"},
  {name = "check-style", has_arg = "required"},
  {name = "embed", has_arg = "required"},
  {name = "output", has_arg = "required"},
  {name = "extract", has_arg = "required"},
  {name = "exe", has_arg = "required"},
  {name = "check-examples", has_arg = "required"},
  {name = "examples", has_arg = "optional"},
  {name = "benchmark", has_arg = "required"},
  {name = "docs", has_arg = "optional"},
  {name = "welcome", has_arg = "none"},
  {name = "test", has_arg = "required"},
  {name = "report", has_arg = "none"},
  {name = "coverage-report", has_arg = "none"},
  {name = "build", has_arg = "required"},
  {name = "make", has_arg = "optional"},
  {name = "skill", has_arg = "required"},
  {name = "write-if-changed", has_arg = "none"},
  {name = "include-dir", has_arg = "required"},
}

--- Options requiring an argument, derived from the tables above and
--- shared so the dispatcher's pre-scan stays in sync with them.
local short_needs_arg: {string: boolean} = {}
do
  local j = 1
  while j <= #shortopts do
    local c = shortopts:sub(j, j)
    if c ~= ":" then
      if j < #shortopts and shortopts:sub(j + 1, j + 1) == ":" and
      (j + 1 >= #shortopts or shortopts:sub(j + 2, j + 2) ~= ":") then
        short_needs_arg[c] = true
      end
    end
    j = j + 1
  end
end

local long_needs_arg: {string: boolean} = {}
for _, opt in ipairs(longopts) do
  if opt.has_arg == "required" then
    long_needs_arg[opt.name] = true
  end
end

--- Resolve optional arg value that may be space-separated.
--- For flags like --docs, --examples, --make where getopt returns ""
--- but the value may be the next positional arg.
local function resolve_optional_arg(flag: string, value: string): string
  if value ~= "" then return value end
  for i = 1, #arg do
    if arg[i] == flag then
      if i < #arg and not arg[i + 1]:match("^%-") then
        return arg[i + 1]
      end
      break
    end
  end
  return ""
end

return {
  shortopts = shortopts,
  longopts = longopts,
  short_needs_arg = short_needs_arg,
  long_needs_arg = long_needs_arg,
  resolve_optional_arg = resolve_optional_arg,
}
