--- The single-spec half of the flags family: validate a Spec, parse an
--- argument vector against it, render its help. Shard of cosmic.flags;
--- the public surface is init.tl's.
local getopt = require("cosmic.flags.getopt")
local types = require("cosmic.flags.types")

local type Flag = types.Flag
local type Spec = types.Spec
local type Parsed = types.Parsed

local function prog(spec: Spec): string
  return spec.name or "program"
end

--- Validate a spec and index its flags. Returns long-name and
--- short-letter lookup maps, or nil and a message naming the defect.
--- Error strings are unprefixed (#991): the caller knows its own name.
local function index_flags(spec: Spec): {string: Flag}, {string: Flag}, string
  local by_long: {string: Flag} = {}
  local by_short: {string: Flag} = {}
  for _, f in ipairs(spec.flags or {}) do
    if not f.long or #f.long == 0 then
      return nil, nil, "invalid spec: flag without a long name"
    end
    if by_long[f.long] then
      return nil, nil, "invalid spec: duplicate flag --" .. f.long
    end
    by_long[f.long] = f
    if f.short then
      if #f.short ~= 1 then
        return nil, nil, "invalid spec: short alias must be one letter: "
        .. f.short
      end
      if by_short[f.short] then
        return nil, nil, "invalid spec: duplicate short flag -" .. f.short
      end
      by_short[f.short] = f
    end
    if not f.arg and (f.default or f.required or f.repeated or f.arg_optional) then
      return nil, nil, "invalid spec: --" .. f.long
      .. " is a switch; default/required/repeated/arg_optional need an arg placeholder"
    end
    if f.default and f.required then
      return nil, nil, "invalid spec: --" .. f.long
      .. " cannot be both required and defaulted"
    end
    if f.arg_optional and f.required then
      return nil, nil, "invalid spec: --" .. f.long
      .. " cannot be both required and arg_optional"
    end
  end
  return by_long, by_short
end

--- The flags parse actually recognizes: the declared ones plus the
--- automatic help/version entries when their names are free.
local function effective_flags(spec: Spec, by_long: {string: Flag},
    by_short: {string: Flag}): {Flag}
  local out: {Flag} = {}
  for _, f in ipairs(spec.flags or {}) do
    out[#out + 1] = f
  end
  if not by_long["help"] then
    local short: string = nil
    if not by_short["h"] then
      short = "h"
    end
    out[#out + 1] = {long = "help", short = short, help = "show this help"}
  end
  if spec.version and not by_long["version"] then
    out[#out + 1] = {long = "version", help = "show version"}
  end
  return out
end

--- Parse a command-line argument vector against a spec.
--- Never prints and never exits: --help/--version requests come back
--- as fields on Parsed, and any problem — invalid spec, unknown flag,
--- missing value, missing required flag — is nil plus a one-line
--- message. The message is NOT prefixed with the program name (#991):
--- add your own context, like every other module's errors. Repeated
--- valued flags keep the last occurrence in `values`; declare
--- `repeated` to collect every occurrence in `lists`.
--- @param spec Spec The declared interface
--- @param argv {string} The argument list (typically the global arg)
--- @return Parsed | nil The parse result, or nil on any error
--- @return string? Error message when the spec or command line is invalid
local function parse(spec: Spec, argv: {string}): Parsed | nil, string
  local by_long, by_short, spec_err = index_flags(spec)
  if not by_long then
    return nil, spec_err
  end
  local flags = effective_flags(spec, by_long, by_short)

  local optstring = ""
  local longopts: {getopt.LongOpt} = {}
  local lookup: {string: Flag} = {}
  for _, f in ipairs(flags) do
    local has_arg: getopt.HasArg = "none"
    if f.arg then
      has_arg = f.arg_optional and "optional" or "required"
    end
    if f.short then
      optstring = optstring .. f.short
      if f.arg and not f.arg_optional then
        optstring = optstring .. ":"
      elseif f.arg then
        optstring = optstring .. "::"
      end
      -- getopt reports an aliased long flag as its short letter
      lookup[f.short] = f
    end
    lookup[f.long] = f
    longopts[#longopts + 1] = {name = f.long, has_arg = has_arg, short = f.short}
  end

  local r0, gerr = getopt.parse(argv, optstring, longopts)
  if not r0 then
    return nil, tostring(gerr)
  end
  local r = r0

  if r.unknown[1] then
    return nil, "unknown option: " .. r.unknown[1] .. " (try --help)"
  end
  if r.missing[1] then
    -- getopt names a missing aliased flag by its short letter;
    -- report the long name, which is what the spec declares.
    local missing_flag = lookup[r.missing[1]]
    local name = missing_flag and missing_flag.long or r.missing[1]
    return nil, "option requires a value: --" .. name
  end

  local parsed: Parsed = {
    switches = {},
    values = {},
    lists = {},
    args = r.args,
    help = false,
    version = false,
  }
  for _, f in ipairs(flags) do
    if f.arg then
      if f.default then
        parsed.values[f.long] = f.default
      end
      if f.repeated then
        parsed.lists[f.long] = {}
      end
    else
      parsed.switches[f.long] = false
    end
  end

  for _, o in ipairs(r.opts) do
    local f = lookup[o.opt]
    if f then
      if f.arg then
        -- A bare arg_optional flag reads as "": present, no value.
        local v = o.arg or ""
        parsed.values[f.long] = v
        if f.repeated then
          local list = parsed.lists[f.long]
          list[#list + 1] = v
        end
      else
        parsed.switches[f.long] = true
      end
    end
  end

  parsed.help = parsed.switches["help"] or false
  -- Only the built-in --version (registered by effective_flags when
  -- spec.version is set) sets parsed.version. A user-declared --version
  -- switch with no spec.version is an ordinary switch: it stays in
  -- parsed.switches, not mirrored onto parsed.version (doc: "specs
  -- with a version only").
  if spec.version then
    parsed.version = parsed.switches["version"] or false
  end

  -- A help or version request short-circuits required-flag
  -- enforcement: `prog --help` must always work.
  if not parsed.help and not parsed.version then
    for _, f in ipairs(flags) do
      if f.required and parsed.values[f.long] == nil then
        return nil, "missing required option: --" .. f.long
        .. " (try --help)"
      end
    end
  end
  return parsed
end

--- Render help text for a spec: a usage line, the summary, and one
--- aligned row per flag (including the automatic help/version
--- entries), with defaults and required markers noted. Returns the
--- text without a trailing newline; printing is the caller's job.
--- @param spec Spec The declared interface
--- @return string The rendered help text
local function help(spec: Spec): string
  local by_long, by_short = index_flags(spec)
  local flags: {Flag}
  if by_long then
    flags = effective_flags(spec, by_long, by_short)
  else
    -- Invalid specs still render their declared flags so the
    -- defect is visible next to the parse error.
    flags = spec.flags or {}
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
  for i, f in ipairs(flags) do
    local left: string
    if f.short then
      left = "-" .. f.short .. ", --" .. f.long
    else
      left = "    --" .. f.long
    end
    if f.arg then
      left = left .. (f.arg_optional and " [" .. f.arg .. "]" or " " .. f.arg)
    end
    lefts[i] = left
    if #left > width then
      width = #left
    end
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = "options:"
  for i, f in ipairs(flags) do
    local row = "  " .. lefts[i] .. string.rep(" ", width - #lefts[i])
    local desc = f.help or ""
    if f.default then
      desc = desc .. " (default: " .. f.default .. ")"
    end
    if f.required then
      desc = desc .. " (required)"
    end
    if #desc > 0 then
      row = row .. "  " .. desc
    end
    lines[#lines + 1] = row
  end
  return table.concat(lines, "\n")
end

local record ParseModule
  parse: function(spec: Spec, argv: {string}): Parsed | nil, string
  help: function(spec: Spec): string
end

local M: ParseModule = {
  parse = parse,
  help = help,
}

return M
