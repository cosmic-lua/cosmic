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
  -- One flag, a KIND, then the file: `--check types foo.tl`. It
  -- mirrors `--make <verb> [paths]` — a word, then what to apply it to
  -- — so the per-file spelling and the project-wide one are one
  -- vocabulary instead of four flags beside four verbs.
  {name = "check", has_arg = "required"},
  {name = "embed", has_arg = "required"},
  {name = "output", has_arg = "required"},
  {name = "extract", has_arg = "required"},
  {name = "exe", has_arg = "required"},
  {name = "examples", has_arg = "optional"},
  {name = "benchmark", has_arg = "required"},
  {name = "docs", has_arg = "optional"},
  {name = "welcome", has_arg = "none"},
  {name = "test", has_arg = "required"},
  {name = "report", has_arg = "none"},
  {name = "coverage-report", has_arg = "none"},
  {name = "make", has_arg = "required"},
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
--- For flags like --docs and --examples where getopt returns ""
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

--- Flags that once named one kind of check each, mapped to the kind
--- each is spelled with now. A script written against the retired
--- spelling is told the current one rather than dropping into the
--- REPL, and this is checked before getopt, which would prefix-match
--- them onto `--check`.
local RENAMED_CHECKS < const >: {string: string} = {
  ["--check-types"] = "types",
  ["--check-format"] = "fmt",
  ["--check-style"] = "lint",
  ["--check-examples"] = "example",
}

--- Complain about a retired check flag, if the argv holds one.
--- @param argv {string} The arguments cosmic will parse
--- @return string|nil The error message, or nil when there is none
local function renamed_check(argv: {string}): string | nil
  for _, a in ipairs(argv) do
    local base = a:match("^([^=]+)=") or a
    local kind = RENAMED_CHECKS[base]
    if kind then
      -- The verb comes from `_cli.check`, which owns the mapping.
      -- A second copy here is how the two vocabularies drifted in the
      -- first place. Required inside the branch so the argument parser
      -- does not pull the check machinery in on every run.
      local kinds = require("_cli.check").KINDS
      return "cosmic-lua: " .. base .. " is now `--check " .. kind ..
      " <file>` (the project-wide spelling is `cosmic --make " ..
      kinds[kind] .. "`)"
    end
  end
  return nil
end

return {
  renamed_check = renamed_check,
  shortopts = shortopts,
  longopts = longopts,
  short_needs_arg = short_needs_arg,
  long_needs_arg = long_needs_arg,
  resolve_optional_arg = resolve_optional_arg,
}
