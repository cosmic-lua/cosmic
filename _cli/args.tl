--- CLI flag definitions for cosmic, as one flags.Spec (#991).
--- Shared by the dispatcher and tests to keep the flag list in sync.

local flags = require("cosmic.flags")

--- The dispatcher's interface. `-c` is make's shell contract:
--- `$(SHELL) $(.SHELLFLAGS) '<line>'` with `.SHELLFLAGS` defaulting to
--- `-c`, so `SHELL := cosmic` works with no further configuration.
--- The long names for the Lua-compatible shorts (-e/-l/-i/-E/-W) are
--- new with the flags port; the shorts remain the documented spelling.
local spec: flags.Spec = {
  name = "cosmic-lua",
  flags = {
    {long = "recipe", short = "c", arg = "LINE",
      help = "run one build-recipe line (make SHELL contract)"},
    {long = "execute", short = "e", arg = "CODE", repeated = true,
      help = "execute a string of code"},
    {long = "load", short = "l", arg = "MODULE", repeated = true,
      help = "require a library before running"},
    {long = "interactive", short = "i", help = "enter the REPL"},
    {long = "version", short = "v", help = "print the version"},
    {long = "ignore-env", short = "E", help = "ignore environment variables"},
    {long = "warn", short = "W", help = "turn warnings into errors"},
    {long = "help", short = "h", help = "show help"},
    {long = "compile", arg = "FILE", help = "compile a Teal file"},
    {long = "compile-strict", arg = "FILE", help = "compile, warnings fatal"},
    {long = "format", arg = "FILE", help = "print files formatted"},
    {long = "fix", arg = "FILE", help = "format files in place"},
    -- One flag, a KIND, then the file: `--check types foo.tl`. It
    -- mirrors `--make <verb> [paths]` — a word, then what to apply it
    -- to — so the per-file spelling and the project-wide one are one
    -- vocabulary instead of four flags beside four verbs.
    {long = "check", arg = "KIND", help = "run one check kind on files"},
    {long = "embed", arg = "PATH", repeated = true,
      help = "embed a file into the output executable"},
    {long = "output", arg = "FILE", help = "where to write"},
    {long = "extract", arg = "DIR", help = "extract the embedded zip"},
    {long = "exe", arg = "FILE", help = "source executable"},
    {long = "examples", arg = "MODULE", arg_optional = true,
      help = "run examples"},
    {long = "benchmark", arg = "PATH", help = "run benchmarks"},
    {long = "docs", arg = "QUERY", arg_optional = true, help = "query docs"},
    {long = "welcome", help = "print the welcome banner"},
    {long = "test", arg = "OUTPUT", help = "run a test command"},
    {long = "report", help = "summarize test outputs"},
    {long = "coverage-report", help = "summarize coverage"},
    {long = "make", arg = "VERB", help = "run a build verb"},
    {long = "write-if-changed", help = "only write when content differs"},
    {long = "include-dir", arg = "DIR", repeated = true,
      help = "add a module include directory"},
    -- Consumed by hand at the top of the dispatcher, before any other
    -- require -- see cmd/cosmic/main.tl. It is declared here so the
    -- parser takes its ARGUMENT rather than leaving a bare path in the
    -- positionals, where it would become the script to run.
    {long = "modules", arg = "MANIFEST", help = "module resolution manifest"},
  },
}

--- Options requiring an argument, derived from the spec and shared so
--- the dispatcher's pre-scan stays in sync with it.
local short_needs_arg: {string: boolean} = {}
local long_needs_arg: {string: boolean} = {}
for _, f in ipairs(spec.flags) do
  if f.arg and not f.arg_optional then
    long_needs_arg[f.long] = true
    if f.short then
      short_needs_arg[f.short] = true
    end
  end
end

--- Resolve optional arg value that may be space-separated.
--- For flags like --docs and --examples where the parser returns ""
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
--- REPL, and this is checked before parsing, which would prefix-match
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

--- The path list behind a file-taking flag: the flag's own argument
--- first, then the positionals that followed it. `first` is nil for
--- `--check`, whose argument is the KIND rather than a path.
--- @param first string The flag's own argument, when it names a file
--- @param rest {string} The positionals the parser left over
--- @return {string} Every path named, in the order given
local function with_extra_paths(first: string, rest: {string}): {string}
  local paths: {string} = {}
  if first then
    paths[#paths + 1] = first
  end
  for _, path in ipairs(rest) do
    paths[#paths + 1] = path
  end
  return paths
end

--- Run one per-file action over every path and return the WORST exit
--- code, so one bad file among many still fails the run. One fan-out,
--- shared by every flag that takes a path list.
--- @param paths {string} The files to act on
--- @param action function What to do with one path
--- @return integer The worst exit code any path produced
local function over_paths(paths: {string},
    action: function(string): integer): integer
  local worst = 0
  for _, path in ipairs(paths) do
    local code = action(path)
    if code > worst then
      worst = code
    end
  end
  return worst
end

return {
  spec = spec,
  renamed_check = renamed_check,
  resolve_optional_arg = resolve_optional_arg,
  with_extra_paths = with_extra_paths,
  over_paths = over_paths,
  -- Derived from the spec, for the dispatcher's pre-scan (main.tl).
  short_needs_arg = short_needs_arg,
  long_needs_arg = long_needs_arg,
}
