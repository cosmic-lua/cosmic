-- type declarations for cosmo.getopt
-- GENERATED from cosmopolitan's definitions.lua by lib/types/gentype.tl.
-- Do not edit by hand. Regenerate with: bin/make regen-types

--- A single recognized option and its argument (nil when the option takes
--- none). For a long option that has a short equivalent, `opt` is that short
--- letter; for a long-only option, `opt` is the long name.
local record Option
  ---
  opt: string
  ---
  arg: string
end

--- The outcome of a single `getopt.parse` call.
local record Result
  --- Recognized options, in the order encountered
  opts: {Option}
  --- Non-option (positional) arguments
  args: {string}
  --- Unrecognized options, each including its dashes
  unknown: {string}
  --- Options that required an argument but got none
  missing: {string}
end

local record getopt
  type Option = Option
  type Result = Result

  --- Parse a command-line argument vector in one shot.
  --- The optstring uses standard getopt format:
  --- - A letter means that option takes no argument
  --- - A letter followed by : means it requires an argument
  --- - A letter followed by :: means it takes an optional argument
  --- The longopts table contains entries like {"name", "has_arg", "short"}:
  --- - name: the long option name (e.g., "help" for --help)
  --- - has_arg: "none", "required", or "optional"
  --- - short: the equivalent short option character (e.g., "h"), or nil
  --- The result separates four outcomes. `opts` lists the recognized options in
  --- order, each as a {opt, arg} pair. `args` holds the leftover positional
  --- arguments. `unknown` holds unrecognized options (always spelled with their
  --- dashes, e.g. "-x" or "--nope"). `missing` holds the options that required an
  --- argument but were given none (named without dashes, e.g. "o"); this is kept
  --- distinct from `unknown` via getopt's leading-`:` protocol.
  --- Example - Basic usage:
  ---     local r = getopt.parse(arg, "hvo:", {
  ---       {"help",    "none",     "h"},
  ---       {"verbose", "none",     "v"},
  ---       {"output",  "required", "o"},
  ---     })
  ---     for _, o in ipairs(r.opts) do
  ---       if o.opt == "h" then
  ---         print("Usage: ...")
  ---       elseif o.opt == "v" then
  ---         verbose = true
  ---       elseif o.opt == "o" then
  ---         output = o.arg
  ---       end
  ---     end
  ---     -- r.args     -- non-option arguments
  ---     -- r.unknown  -- unrecognized options, with dashes
  ---     -- r.missing  -- options missing a required argument
  --- Example - Handling repeated options:
  ---     local r = getopt.parse(arg, "e:")
  ---     local excludes = {}
  ---     for _, o in ipairs(r.opts) do
  ---       if o.opt == "e" then
  ---         table.insert(excludes, o.arg)
  ---       end
  ---     end
  ---     -- Now excludes contains all -e values: {"foo", "bar", "spam"}
  parse: function(args: {string}, optstring: string, longopts?: {table}): Result | nil, string
end

return getopt
