# getopt

 Command-line option parsing utilities.
 Wraps cosmo.getopt with a convenient Teal-typed interface for parsing
 command-line arguments with support for short options, long options,
 and optional/required arguments.

## Types

### RawGetopt

```teal
local record RawGetopt
  parse: function(args: {string}, optstring: string, longopts: {table}): any, any
  new: function(args: {string}, optstring: string, longopts: {table}): any
end
```

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

### Option

 A single recognized option and its argument.
 For a long option that has a short alias, `opt` is that short letter; for a
 long-only option, `opt` is the long name. `arg` is nil when the option takes
 no argument.
 @field opt string The option letter or long name
 @field arg string|nil The option's argument, if any

```teal
local record Option
  opt: string
  arg: string
end
```

### Result

 The outcome of a single `parse` call.
 @field opts {Option} Recognized options, in the order encountered
 @field args {string} Non-option (positional) arguments
 @field unknown {string} Unrecognized options, each including its dashes
 @field missing {string} Options that required an argument but got none

```teal
local record Result
  opts: {Option}
  args: {string}
  unknown: {string}
  missing: {string}
end
```

### Parser

 A parser object for iterating through command-line options one at a time.
 Retained as a thin compatibility shim over `parse`; prefer `parse`.

```teal
local record Parser
  --  Get the next option, or nil when done. Unknown/missing options are
  --  reported as "?" with the offending option string as the second value.
  next: function(self: Parser): string, string
  --  Get remaining non-option arguments.
  remaining: function(self: Parser): {string}
  --  Get any unknown options encountered during parsing.
  unknown: function(self: Parser): {string}
end
```

### GetoptModule

```teal
local record GetoptModule
  --  Type for defining long options
  LongOpt: LongOpt
  --  Type for a single recognized option
  Option: Option
  --  Type for the parse result
  Result: Result
  --  Type for the stateful parser
  Parser: Parser
  --  Parse a command-line argument vector in one shot
  parse: function(args: {string}, optstring: string, longopts?: {LongOpt}): Result, string
  --  Create a stateful parser (compatibility shim over parse)
  new: function(args: {string}, optstring: string, longopts?: {LongOpt}): Parser
end
```

## Functions

### parse

```teal
function parse(args: {string}, optstring: string, longopts?: {LongOpt}): Result, string
```

 Parse a command-line argument vector in one shot.
 The optstring uses standard getopt format:
 - A letter means that option takes no argument (e.g., "h" for -h)
 - A letter followed by : means it requires an argument (e.g., "o:" for -o file)
 - A letter followed by :: means it takes an optional argument (e.g., "v::" for -v or -vN)
 The result separates four outcomes: recognized `opts` (each a {opt, arg}
 record, in order), leftover positional `args`, `unknown` options (always
 spelled with their dashes, e.g. "-x" or "--nope"), and `missing` options
 that required an argument but were given none (named without dashes).
 Example - Basic usage:
     local getopt = require("cosmic.getopt")
     local r = getopt.parse(arg, "hvo:", {
       {name = "help",    has_arg = "none",     short = "h"},
       {name = "verbose", has_arg = "none",     short = "v"},
       {name = "output",  has_arg = "required", short = "o"},
     })
     for _, o in ipairs(r.opts) do
       -- Both -h and --help yield "h" since a short alias is defined
       if o.opt == "h" then
         print("Usage: ...")
       elseif o.opt == "v" then
         print("verbose")
       elseif o.opt == "o" then
         print("output = " .. o.arg)
       end
     end

**Parameters:**

- `args` ({string}) - The argument list to parse (typically the global `arg` table)
- `optstring` (string) - Short options specification
- `longopts` ({LongOpt}|nil) - Long options table, each entry is {name, has_arg, short}

**Returns:**

- Result|nil - The parse result, or nil on error
- string|nil - An error message when parsing failed

### new

```teal
function new(args: {string}, optstring: string, longopts?: {LongOpt}): Parser
```

 Create a stateful parser (compatibility shim over `parse`).
 Prefer `parse`, which returns all results at once. `next` yields each
 recognized option in turn, then "?" entries for unknown/missing options.

**Parameters:**

- `args` ({string}) - The argument list to parse
- `optstring` (string) - Short options specification
- `longopts` ({LongOpt}|nil) - Long option definitions

**Returns:**

- Parser - A parser instance for iterating through options
