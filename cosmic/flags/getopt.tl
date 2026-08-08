--- Command-line option parsing: the short/long option grammar behind
--- cosmic.flags (#991: an internal shard now — cosmic.flags is the one
--- public parser). Wraps cosmo.getopt with a Teal-typed single-shot
--- parse supporting short options, long options, and
--- optional/required arguments.
local cosmo_getopt = require("cosmo.getopt")

--- Whether an option takes an argument (#991: a real enum — the
--- stringly field let any typo through as "none").
local enum HasArg
  "none"
  "required"
  "optional"
end

--- Defines a long option with its name, argument behavior, and optional short alias.
--- @field name string The long option name (e.g., "help" for --help)
--- @field has_arg HasArg Whether the option takes an argument
--- @field short string|nil The equivalent short option character (e.g., "h")
local record LongOpt
  name: string
  has_arg: HasArg
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
---     local getopt = require("cosmic.flags.getopt")
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
  local res, err = cosmo_getopt.parse(args, optstring, raw_longopts)
  if not res then
    return nil, err
  end
  return res
end

local record GetoptModule
  --- Argument behavior for a long option
  type HasArg = HasArg
  --- Type for defining long options
  type LongOpt = LongOpt
  --- Type for a single recognized option
  type Option = Option
  --- Type for the parse result
  type Result = Result
  --- Parse a command-line argument vector in one shot
  parse: function(args: {string}, optstring: string, longopts?: {LongOpt}): Result | nil, string
end

local M: GetoptModule = {
  parse = parse,
}

return M
