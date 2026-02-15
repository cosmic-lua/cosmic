-- type declarations for cosmo.getopt

local record parser
  --- Get the next option from the parser.
  --- Returns the next option character or long name, along with its argument
  --- if the option takes one. Returns nil when no more options remain.
  --- If the option is unknown, returns "?" as the option name and the unknown
  --- option string as the argument.
  next: function(self: parser): string | nil, string | nil
  --- Get remaining non-option arguments after all options have been parsed.
  remaining: function(self: parser): {string}
  --- Get any unknown options that were encountered during parsing.
  unknown: function(self: parser): {string}
end

local record getopt
  --- Create a new getopt parser for iterating through command-line options.
  --- The optstring uses standard getopt format:
  --- - A letter means that option takes no argument
  --- - A letter followed by : means it requires an argument
  --- - A letter followed by :: means it takes an optional argument
  --- The longopts table contains entries like {"name", "has_arg", "short"}:
  --- - name: the long option name (e.g., "help" for --help)
  --- - has_arg: "none", "required", or "optional"
  --- - short: the equivalent short option character (e.g., "h")
  --- Example - Basic usage:
  ---     local parser = getopt.new(arg, "hvo:", {
  ---       {"help",    "none",     "h"},
  ---       {"verbose", "none",     "v"},
  ---       {"output",  "required", "o"},
  ---     })
  ---     while true do
  ---       local opt, arg = parser:next()
  ---       if not opt then break end
  ---       if opt == "h" or opt == "help" then
  ---         print("Usage: ...")
  ---       elseif opt == "v" or opt == "verbose" then
  ---         verbose = true
  ---       elseif opt == "o" or opt == "output" then
  ---         output = arg
  ---       end
  ---     end
  ---     local remaining = parser:remaining()  -- non-option args
  ---     local unknown = parser:unknown()      -- unrecognized options
  --- Example - Handling repeated options:
  ---     local parser = getopt.new(arg, "e:", {})
  ---     local excludes = {}
  ---     while true do
  ---       local opt, arg = parser:next()
  ---       if not opt then break end
  ---       if opt == "e" then
  ---         table.insert(excludes, arg)
  ---       end
  ---     end
  ---     -- Now excludes contains all -e values: {"foo", "bar", "spam"}
  new: function(args: {string}, optstring: string, longopts?: {table}): parser
end

return getopt
