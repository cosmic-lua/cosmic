--- Command-line option parsing utilities.
--- Wraps cosmo.getopt with a convenient Teal-typed interface for parsing
--- command-line arguments with support for short options, long options,
--- and optional/required arguments.
local cosmo_getopt = require("cosmo.getopt")

-- The underlying cosmo.getopt binding changed shape across cosmos releases:
-- newer builds expose the single-shot `parse` the generated declarations
-- describe, while older ones (including the pinned build bootstrap) expose
-- only a stateful `new`/parser iterator that the generated declarations no
-- longer carry. This record is that legacy surface, kept for runtime
-- feature detection; either field may be nil depending on the cosmos
-- version.
local record LegacyGetopt
  parse: function(args: {string}, optstring: string, longopts: {table}): any, any
  new: function(args: {string}, optstring: string, longopts: {table}): any
end
local legacy = cosmo_getopt as LegacyGetopt -- cast: legacy binding surface

--- Defines a long option with its name, argument behavior, and optional short alias.
--- @field name string The long option name (e.g., "help" for --help)
--- @field has_arg string Whether the option takes an argument: "none", "required", or "optional"
--- @field short string|nil The equivalent short option character (e.g., "h")
local record LongOpt
  name: string
  has_arg: string
  short: string
end

--- A single recognized option and its argument (the generated
--- cosmo.getopt.Option record).
--- For a long option that has a short alias, `opt` is that short letter; for a
--- long-only option, `opt` is the long name. `arg` is nil when the option takes
--- no argument.
--- @field opt string The option letter or long name
--- @field arg string|nil The option's argument, if any
local type Option = cosmo_getopt.Option

--- The outcome of a single `parse` call (the generated
--- cosmo.getopt.Result record).
--- @field opts {Option} Recognized options, in the order encountered
--- @field args {string} Non-option (positional) arguments
--- @field unknown {string} Unrecognized options, each including its dashes
--- @field missing {string} Options that required an argument but got none
local type Result = cosmo_getopt.Result

--- A parser object for iterating through command-line options one at a time.
--- Retained as a thin compatibility shim over `parse`; prefer `parse`.
local record Parser
  --- Get the next option, or nil when done. Unknown/missing options are
  --- reported as "?" with the offending option string as the second value.
  next: function(self: Parser): string, string
  --- Get remaining non-option arguments.
  remaining: function(self: Parser): {string}
  --- Get any unknown options encountered during parsing.
  unknown: function(self: Parser): {string}
end

-- Convert typed LongOpt records to the positional table form the C binding
-- expects: {name, has_arg, short}.
local function to_raw_longopts(longopts?: {LongOpt}): {table}
  if not longopts then
    return nil
  end
  local raw_longopts: {table} = {}
  for i, opt in ipairs(longopts) do
    raw_longopts[i] = {opt.name, opt.has_arg, opt.short}
  end
  return raw_longopts
end

--- Parse a command-line argument vector in one shot.
--- The optstring uses standard getopt format:
--- - A letter means that option takes no argument (e.g., "h" for -h)
--- - A letter followed by : means it requires an argument (e.g., "o:" for -o file)
--- - A letter followed by :: means it takes an optional argument (e.g., "v::" for -v or -vN)
---
--- The result separates four outcomes: recognized `opts` (each a {opt, arg}
--- record, in order), leftover positional `args`, `unknown` options (always
--- spelled with their dashes, e.g. "-x" or "--nope"), and `missing` options
--- that required an argument but were given none (named without dashes).
---
--- @param args {string} The argument list to parse (typically the global `arg` table)
--- @param optstring string Short options specification
--- @param longopts {LongOpt}|nil Long options table, each entry is {name, has_arg, short}
--- @return Result|nil The parse result, or nil on error
--- @return string|nil An error message when parsing failed
--- Example - Basic usage:
---     local getopt = require("cosmic.getopt")
---     local r = getopt.parse(arg, "hvo:", {
---       {name = "help",    has_arg = "none",     short = "h"},
---       {name = "verbose", has_arg = "none",     short = "v"},
---       {name = "output",  has_arg = "required", short = "o"},
---     })
---     for _, o in ipairs(r.opts) do
---       -- Both -h and --help yield "h" since a short alias is defined
---       if o.opt == "h" then
---         print("Usage: ...")
---       elseif o.opt == "v" then
---         print("verbose")
---       elseif o.opt == "o" then
---         print("output = " .. o.arg)
---       end
---     end
local function parse(args: {string}, optstring: string, longopts?: {LongOpt}): Result | nil, string
  local raw_longopts = to_raw_longopts(longopts)

  if legacy.parse then
    -- Newer cosmos: native single-shot parse via the generated surface.
    local res, err = cosmo_getopt.parse(args, optstring, raw_longopts)
    if not res then
      return nil, err
    end
    return res
  end

  -- Older cosmos (build bootstrap): emulate parse via the iterator. The
  -- old binding conflates unknown and missing as "?", so both land in
  -- `unknown` here; the accurate split is only available on the native path,
  -- which is what the shipped binary uses.
  local result: Result = {opts = {}, args = {}, unknown = {}, missing = {}}
  local p = legacy.new(args, optstring, raw_longopts) as Parser -- cast: from any
  while true do
    local opt, optarg = p:next()
    if not opt then
      break
    end
    if opt == "?" then
      table.insert(result.unknown, optarg)
    else
      table.insert(result.opts, {opt = opt, arg = optarg})
    end
  end
  result.args = p:remaining()
  return result
end

--- Create a stateful parser (compatibility shim over `parse`).
--- Prefer `parse`, which returns all results at once. `next` yields each
--- recognized option in turn, then "?" entries for unknown/missing options.
--- @param args {string} The argument list to parse
--- @param optstring string Short options specification
--- @param longopts {LongOpt}|nil Long option definitions
--- @return Parser A parser instance for iterating through options
local function new(args: {string}, optstring: string, longopts?: {LongOpt}): Parser
  if legacy.new then
    -- Older cosmos: use the native iterator directly.
    -- cast: from any
    return legacy.new(args, optstring, to_raw_longopts(longopts)) as Parser
  end

  -- Newer cosmos: replay parse() results through an iterator interface.
  local r = parse(args, optstring, longopts) as Result -- cast: record union, nil handled
  local stream: {Option} = {}
  if r then
    for _, o in ipairs(r.opts) do
      table.insert(stream, o)
    end
    for _, u in ipairs(r.unknown) do
      table.insert(stream, {opt = "?", arg = u})
    end
    for _, m in ipairs(r.missing) do
      local dash = #m == 1 and "-" or "--"
      table.insert(stream, {opt = "?", arg = dash .. m})
    end
  end
  local idx = 0
  local p: Parser = {
    next = function(_self: Parser): string, string
      idx = idx + 1
      local e = stream[idx]
      if not e then
        return nil
      end
      return e.opt, e.arg
    end,
    remaining = function(_self: Parser): {string}
      return r and r.args or {}
    end,
    unknown = function(_self: Parser): {string}
      return r and r.unknown or {}
    end,
  }
  return p
end

local record GetoptModule
  --- Type for defining long options
  LongOpt: LongOpt
  --- Type for a single recognized option
  Option: Option
  --- Type for the parse result
  Result: Result
  --- Type for the stateful parser
  Parser: Parser
  --- Parse a command-line argument vector in one shot
  parse: function(args: {string}, optstring: string, longopts?: {LongOpt}): Result | nil, string
  --- Create a stateful parser (compatibility shim over parse)
  new: function(args: {string}, optstring: string, longopts?: {LongOpt}): Parser
end

local M: GetoptModule = {
  parse = parse,
  new = new,
}

return M
