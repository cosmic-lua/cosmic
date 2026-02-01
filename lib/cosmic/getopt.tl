--- Command-line option parsing utilities.
--- Wraps cosmo.getopt with a convenient Teal-typed interface for parsing
--- command-line arguments with support for short options, long options,
--- and optional/required arguments.
local cosmo_getopt = require("cosmo.getopt")

--- Defines a long option with its name, argument behavior, and optional short alias.
--- @field name string The long option name (e.g., "help" for --help)
--- @field has_arg string Whether the option takes an argument: "none", "required", or "optional"
--- @field short string|nil The equivalent short option character (e.g., "h")
local record LongOpt
  name: string
  has_arg: string
  short: string
end

--- Parser for iterating through command-line options.
--- Use next() in a loop to get each option, then remaining() and unknown()
--- after parsing is complete.
local record Parser
  --- Get the next option from the parser.
  --- Returns the option character (for short options) or long option name,
  --- along with its argument if the option takes one.
  --- Returns nil when no more options remain.
  --- If the option is unknown, returns "?" as the option name and the
  --- unknown option string as the argument.
  --- @return string|nil The option name, or nil when done
  --- @return string|nil The option's argument, if any
  next: function(self: Parser): string, string

  --- Get remaining non-option arguments after all options have been parsed.
  --- Call this after the next() loop completes to get positional arguments.
  --- @return {string} Array of remaining arguments
  remaining: function(self: Parser): {string}

  --- Get any unknown options that were encountered during parsing.
  --- Useful for error reporting or warning about unrecognized options.
  --- @return {string} Array of unknown option strings
  unknown: function(self: Parser): {string}
end

--- Create a new option parser for command-line arguments.
--- The optstring uses standard getopt format:
--- - A letter means that option takes no argument (e.g., "h" for -h)
--- - A letter followed by : means it requires an argument (e.g., "o:" for -o file)
--- - A letter followed by :: means it takes an optional argument (e.g., "v::" for -v or -vN)
---
--- @param args {string} The argument list to parse (typically the global `arg` table)
--- @param optstring string Short options specification
--- @param longopts {LongOpt}|nil Long options table, each entry is {name, has_arg, short}
--- @return Parser A parser instance for iterating through options
--- Example - Basic usage:
---     local getopt = require("cosmic.getopt")
---     local parser = getopt.new(arg, "hvo:", {
---       {name = "help",    has_arg = "none",     short = "h"},
---       {name = "verbose", has_arg = "none",     short = "v"},
---       {name = "output",  has_arg = "required", short = "o"},
---     })
---     local verbose = false
---     local output: string
---     while true do
---       local opt, optarg = parser:next()
---       if not opt then break end
---       if opt == "h" or opt == "help" then
---         print("Usage: ...")
---         os.exit(0)
---       elseif opt == "v" or opt == "verbose" then
---         verbose = true
---       elseif opt == "o" or opt == "output" then
---         output = optarg
---       end
---     end
---     local files = parser:remaining()
---     for _, unknown in ipairs(parser:unknown()) do
---       io.stderr:write("warning: unknown option: " .. unknown .. "\n")
---     end
local function new(args: {string}, optstring: string, longopts?: {LongOpt}): Parser
  -- Convert LongOpt records to the table format expected by cosmo.getopt
  local raw_longopts: {table} = nil
  if longopts then
    raw_longopts = {}
    for i, opt in ipairs(longopts) do
      raw_longopts[i] = {opt.name, opt.has_arg, opt.short}
    end
  end

  local raw_parser = cosmo_getopt.new(args, optstring, raw_longopts)

  -- Wrap the raw parser in our typed Parser interface
  local parser: Parser = {
    next = function(_self: Parser): string, string
      return raw_parser:next()
    end,
    remaining = function(_self: Parser): {string}
      return raw_parser:remaining()
    end,
    unknown = function(_self: Parser): {string}
      return raw_parser:unknown()
    end,
  }

  return parser
end

local record GetoptModule
  --- Type for defining long options
  LongOpt: LongOpt

  --- Type for the option parser
  Parser: Parser

  --- Create a new option parser
  new: function(args: {string}, optstring: string, longopts?: {LongOpt}): Parser
end

local M: GetoptModule = {
  new = new,
}

return M
