# getopt

 Command-line option parsing utilities.
 Wraps cosmo.getopt with a convenient Teal-typed interface for parsing
 command-line arguments with support for short options, long options,
 and optional/required arguments.

## Types

### LongOpt

 Defines a long option with its name, argument behavior, and optional short alias.
 @field name string The long option name (e.g., "help" for --help)
 @field has_arg string Whether the option takes an argument: "none", "required", or "optional"
 @field short string|nil The equivalent short option character (e.g., "h")

```teal
local record LongOpt
  name: string
  has_arg: string
  short: string
end
```

### Parser

 Parser for iterating through command-line options.
 Use next() in a loop to get each option, then remaining() and unknown()
 after parsing is complete.

```teal
local record Parser
  --  Get the next option from the parser.
  --  Returns the short option character when a short alias is defined,
  --  or the long option name when no short alias exists.
  --  This means both `-h` and `--help` return `"h"` if `short = "h"` is set.
  --  Returns nil when no more options remain.
  --  If the option is unknown, returns "?" as the option name and the
  --  unknown option string as the argument.
  next: function(self: Parser): string, string
  --  Get remaining non-option arguments after all options have been parsed.
  --  Call this after the next() loop completes to get positional arguments.
  remaining: function(self: Parser): {string}
  --  Get any unknown options that were encountered during parsing.
  --  Useful for error reporting or warning about unrecognized options.
  unknown: function(self: Parser): {string}
end
```

### GetoptModule

```teal
local record GetoptModule
  --  Type for defining long options
  LongOpt: LongOpt
  --  Type for the option parser
  Parser: Parser
  --  Create a new option parser
  new: function(args: {string}, optstring: string, longopts?: {LongOpt}): Parser
end
```

## Functions

### new

```teal
function new(args: {string}, optstring: string, longopts?: {LongOpt}): Parser
```

 Create a new option parser for command-line arguments.
 The optstring uses standard getopt format:
 - A letter means that option takes no argument (e.g., "h" for -h)
 - A letter followed by : means it requires an argument (e.g., "o:" for -o file)
 - A letter followed by :: means it takes an optional argument (e.g., "v::" for -v or -vN)
 Example - Basic usage:
     local getopt = require("cosmic.getopt")
     local parser = getopt.new(arg, "hvo:", {
       {name = "help",    has_arg = "none",     short = "h"},
       {name = "verbose", has_arg = "none",     short = "v"},
       {name = "output",  has_arg = "required", short = "o"},
     })
     local verbose = false
     local output: string
     while true do
       local opt, optarg = parser:next()
       if not opt then break end
       -- Both -h and --help return "h" since short alias is defined
       if opt == "h" then
         print("Usage: ...")
         os.exit(0)
       elseif opt == "v" then
         verbose = true
       elseif opt == "o" then
         output = optarg
       end
     end
     local files = parser:remaining()
     for _, unknown in ipairs(parser:unknown()) do
       io.stderr:write("warning: unknown option: " .. unknown .. "\n")
     end

**Parameters:**

- `args` ({string}) - The argument list to parse (typically the global `arg` table)
- `optstring` (string) - Short options specification
- `longopts` ({LongOpt}|nil) - Long options table, each entry is {name, has_arg, short}

**Returns:**

- Parser - A parser instance for iterating through options
