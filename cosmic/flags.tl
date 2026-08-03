--- Declarative command-line flag parsing.
--- Describe a program's options once as data — names, value
--- placeholders, defaults, help text — and get parsing, validation,
--- and rendered --help from the one spec. Built over cosmic.getopt,
--- which supplies the underlying short/long option grammar; reach for
--- getopt directly when you need its lower-level control.
---
--- Example usage:
---   local flags = require("cosmic.flags")
---   local spec: flags.Spec = {
---     name = "greet",
---     summary = "Greet people from the command line",
---     usage = "[options] <name...>",
---     options = {
---       {long = "verbose", short = "v", help = "print more detail"},
---       {long = "output", short = "o", arg = "FILE",
---        help = "write to FILE", default = "-"},
---     },
---   }
---   local parsed, err = flags.parse(spec, arg)
---   if not parsed then
---     io.stderr:write(err .. "\n")
---   elseif parsed.help then
---     print(flags.help(spec))
---   else
---     local out = parsed.values["output"]
---     local loud = parsed.flags["verbose"]
---   end
---
--- An option with an `arg` placeholder takes a required value;
--- without one it is a boolean flag. --help/-h is recognized
--- automatically (and --version when the spec carries a version)
--- unless the spec claims those names itself; parse never prints or
--- exits — it reports help/version requests as fields on the result
--- and the caller decides what to do.
---
--- Reserved name: flags.command(spec): subcommand dispatch is
--- reserved for a post-stable battery. Do not reuse this name.
local getopt = require("cosmic.getopt")

--- One option declaration.
local record Option
  --- Long name, without dashes (e.g. "output" for --output). Required.
  long: string
  --- Optional single-letter short alias, without the dash.
  short: string
  --- Value placeholder shown in help (e.g. "FILE"). Its presence
  --- makes the option take a required value; absent means boolean.
  arg: string
  --- One-line description shown in help.
  help: string
  --- Default value, applied when the option is absent (valued only).
  default: string
  --- Reject the command line when the option is absent (valued only).
  required: boolean
end

--- A program's declared interface.
local record Spec
  --- Program name, used in error messages and help (default "program").
  name: string
  --- One-line description shown in help.
  summary: string
  --- Usage tail shown after the name (default "[options]").
  usage: string
  --- Version string; when set, --version is recognized automatically.
  version: string
  --- The declared options, in help-display order.
  options: {Option}
end

--- A successful parse.
local record Parsed
  --- Boolean options by long name; every declared flag is present
  --- (false when absent), so lookups never need a nil check.
  flags: {string: boolean}
  --- Valued options by long name, with defaults applied.
  values: {string: string}
  --- Positional (non-option) arguments, in order.
  args: {string}
  --- True when --help / -h was given.
  help: boolean
  --- True when --version was given (specs with a version only).
  version: boolean
end

local function prog(spec: Spec): string
  return spec.name or "program"
end

--- Validate a spec and index its options. Returns long-name and
--- short-letter lookup maps, or nil and a message naming the defect.
local function index_options(spec: Spec): {string: Option}, {string: Option}, string
  local by_long: {string: Option} = {}
  local by_short: {string: Option} = {}
  for _, opt in ipairs(spec.options or {}) do
    if not opt.long or #opt.long == 0 then
      return nil, nil, prog(spec) .. ": invalid spec: option without a long name"
    end
    if by_long[opt.long] then
      return nil, nil, prog(spec) .. ": invalid spec: duplicate option --" .. opt.long
    end
    by_long[opt.long] = opt
    if opt.short then
      if #opt.short ~= 1 then
        return nil, nil, prog(spec) .. ": invalid spec: short alias must be one letter: "
        .. opt.short
      end
      if by_short[opt.short] then
        return nil, nil, prog(spec) .. ": invalid spec: duplicate short option -" .. opt.short
      end
      by_short[opt.short] = opt
    end
    if not opt.arg and (opt.default or opt.required) then
      return nil, nil, prog(spec) .. ": invalid spec: --" .. opt.long
      .. " is boolean; default/required need an arg placeholder"
    end
    if opt.default and opt.required then
      return nil, nil, prog(spec) .. ": invalid spec: --" .. opt.long
      .. " cannot be both required and defaulted"
    end
  end
  return by_long, by_short
end

--- The options parse actually recognizes: the declared ones plus the
--- automatic help/version entries when their names are free.
local function effective_options(spec: Spec, by_long: {string: Option},
    by_short: {string: Option}): {Option}
  local opts: {Option} = {}
  for _, opt in ipairs(spec.options or {}) do
    opts[#opts + 1] = opt
  end
  if not by_long["help"] then
    local short: string = nil
    if not by_short["h"] then
      short = "h"
    end
    opts[#opts + 1] = {long = "help", short = short, help = "show this help"}
  end
  if spec.version and not by_long["version"] then
    opts[#opts + 1] = {long = "version", help = "show version"}
  end
  return opts
end

--- Parse a command-line argument vector against a spec.
--- Never prints and never exits: --help/--version requests come back
--- as fields on Parsed, and any problem — invalid spec, unknown
--- option, missing value, missing required option — is nil plus a
--- one-line message prefixed with the program name. Repeated valued
--- options keep the last occurrence.
--- @param spec Spec The declared interface
--- @param argv {string} The argument list (typically the global arg)
--- @return Parsed | nil The parse result, or nil on any error
--- @return string? Error message when the spec or command line is invalid
local function parse(spec: Spec, argv: {string}): Parsed | nil, string
  local by_long, by_short, spec_err = index_options(spec)
  if not by_long then
    return nil, spec_err
  end
  local opts = effective_options(spec, by_long, by_short)

  local optstring = ""
  local longopts: {getopt.LongOpt} = {}
  local lookup: {string: Option} = {}
  for _, opt in ipairs(opts) do
    local has_arg = "none"
    if opt.arg then
      has_arg = "required"
    end
    if opt.short then
      optstring = optstring .. opt.short
      if opt.arg then
        optstring = optstring .. ":"
      end
      -- getopt reports an aliased long option as its short letter
      lookup[opt.short] = opt
    end
    lookup[opt.long] = opt
    longopts[#longopts + 1] = {name = opt.long, has_arg = has_arg, short = opt.short}
  end

  local r0, gerr = getopt.parse(argv, optstring, longopts)
  if not r0 then
    return nil, prog(spec) .. ": " .. tostring(gerr)
  end
  local r = r0 as getopt.Result -- cast: record union after guard

  if r.unknown[1] then
    return nil, prog(spec) .. ": unknown option: " .. r.unknown[1] .. " (try --help)"
  end
  if r.missing[1] then
    -- getopt names a missing aliased option by its short letter;
    -- report the long name, which is what the spec declares.
    local missing_opt = lookup[r.missing[1]]
    local name = missing_opt and missing_opt.long or r.missing[1]
    return nil, prog(spec) .. ": option requires a value: --" .. name
  end

  local parsed: Parsed = {
    flags = {},
    values = {},
    args = r.args,
    help = false,
    version = false,
  }
  for _, opt in ipairs(opts) do
    if opt.arg then
      if opt.default then
        parsed.values[opt.long] = opt.default
      end
    else
      parsed.flags[opt.long] = false
    end
  end

  for _, o in ipairs(r.opts) do
    local opt = lookup[o.opt]
    if opt then
      if opt.arg then
        parsed.values[opt.long] = o.arg
      else
        parsed.flags[opt.long] = true
      end
    end
  end

  parsed.help = parsed.flags["help"] or false
  -- Only the built-in --version (registered by effective_options when
  -- spec.version is set) sets parsed.version. A user-declared --version
  -- boolean with no spec.version is an ordinary flag: it stays in
  -- parsed.flags, not mirrored onto parsed.version (doc: "specs with a
  -- version only").
  if spec.version then
    parsed.version = parsed.flags["version"] or false
  end

  -- A help or version request short-circuits required-option
  -- enforcement: `prog --help` must always work.
  if not parsed.help and not parsed.version then
    for _, opt in ipairs(opts) do
      if opt.required and parsed.values[opt.long] == nil then
        return nil, prog(spec) .. ": missing required option: --" .. opt.long
        .. " (try --help)"
      end
    end
  end
  return parsed
end

--- Render help text for a spec: a usage line, the summary, and one
--- aligned row per option (including the automatic help/version
--- entries), with defaults and required markers noted. Returns the
--- text without a trailing newline; printing is the caller's job.
--- @param spec Spec The declared interface
--- @return string The rendered help text
local function help(spec: Spec): string
  local by_long, by_short = index_options(spec)
  local opts: {Option}
  if by_long then
    opts = effective_options(spec, by_long, by_short)
  else
    -- Invalid specs still render their declared options so the
    -- defect is visible next to the parse error.
    opts = spec.options or {}
  end

  local lines: {string} = {
    "usage: " .. prog(spec) .. " " .. (spec.usage or "[options]"),
  }
  if spec.summary then
    lines[#lines + 1] = ""
    lines[#lines + 1] = spec.summary
  end

  local lefts: {string} = {}
  local width = 0
  for i, opt in ipairs(opts) do
    local left: string
    if opt.short then
      left = "-" .. opt.short .. ", --" .. opt.long
    else
      left = "    --" .. opt.long
    end
    if opt.arg then
      left = left .. " " .. opt.arg
    end
    lefts[i] = left
    if #left > width then
      width = #left
    end
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = "options:"
  for i, opt in ipairs(opts) do
    local row = "  " .. lefts[i] .. string.rep(" ", width - #lefts[i])
    local desc = opt.help or ""
    if opt.default then
      desc = desc .. " (default: " .. opt.default .. ")"
    end
    if opt.required then
      desc = desc .. " (required)"
    end
    if #desc > 0 then
      row = row .. "  " .. desc
    end
    lines[#lines + 1] = row
  end
  return table.concat(lines, "\n")
end

local record FlagsModule
  type Option = Option
  type Spec = Spec
  type Parsed = Parsed

  parse: function(spec: Spec, argv: {string}): Parsed | nil, string
  help: function(spec: Spec): string
end

local M: FlagsModule = {
  parse = parse,
  help = help,
}

return M
