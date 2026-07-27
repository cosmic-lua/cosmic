# flags

 Declarative command-line flag parsing.
 Describe a program's options once as data — names, value
 placeholders, defaults, help text — and get parsing, validation,
 and rendered --help from the one spec. Built over cosmic.getopt,
 which supplies the underlying short/long option grammar; reach for
 getopt directly when you need its lower-level control.

 Example usage:
   local flags = require("cosmic.flags")
   local spec: flags.Spec = {
     name = "greet",
     summary = "Greet people from the command line",
     usage = "[options] <name...>",
     options = {
       {long = "verbose", short = "v", help = "print more detail"},
       {long = "output", short = "o", arg = "FILE",
        help = "write to FILE", default = "-"},
     },
   }
   local parsed, err = flags.parse(spec, arg)
   if not parsed then
     io.stderr:write(err .. "\n")
   elseif parsed.help then
     print(flags.help(spec))
   else
     local out = parsed.values["output"]
     local loud = parsed.flags["verbose"]
   end

 An option with an `arg` placeholder takes a required value;
 without one it is a boolean flag. --help/-h is recognized
 automatically (and --version when the spec carries a version)
 unless the spec claims those names itself; parse never prints or
 exits — it reports help/version requests as fields on the result
 and the caller decides what to do.

 Reserved name: flags.command(spec): subcommand dispatch is
 reserved for a post-stable battery. Do not reuse this name.

## Types

### Option

 One option declaration.

```teal
local record Option
  --  Long name, without dashes (e.g. "output" for --output). Required.
  long: string
  --  Optional single-letter short alias, without the dash.
  short: string
  --  Value placeholder shown in help (e.g. "FILE"). Its presence
  --  makes the option take a required value; absent means boolean.
  arg: string
  --  One-line description shown in help.
  help: string
  --  Default value, applied when the option is absent (valued only).
  default: string
  --  Reject the command line when the option is absent (valued only).
  required: boolean
end
```

### Spec

 A program's declared interface.

```teal
local record Spec
  --  Program name, used in error messages and help (default "program").
  name: string
  --  One-line description shown in help.
  summary: string
  --  Usage tail shown after the name (default "[options]").
  usage: string
  --  Version string; when set, --version is recognized automatically.
  version: string
  --  The declared options, in help-display order.
  options: {Option}
end
```

### Parsed

 A successful parse.

```teal
local record Parsed
  --  Boolean options by long name; every declared flag is present
  --  (false when absent), so lookups never need a nil check.
  flags: {string: boolean}
  --  Valued options by long name, with defaults applied.
  values: {string: string}
  --  Positional (non-option) arguments, in order.
  args: {string}
  --  True when --help / -h was given.
  help: boolean
  --  True when --version was given (specs with a version only).
  version: boolean
end
```

### FlagsModule

```teal
local record FlagsModule
  parse: function(spec: Spec, argv: {string}): Parsed | nil, string
  help: function(spec: Spec): string
end
```

## Functions

### parse

```teal
function parse(spec: Spec, argv: {string}): Parsed | nil, string
```

 Parse a command-line argument vector against a spec.
 Never prints and never exits: --help/--version requests come back
 as fields on Parsed, and any problem — invalid spec, unknown
 option, missing value, missing required option — is nil plus a
 one-line message prefixed with the program name. Repeated valued
 options keep the last occurrence.

**Parameters:**

- `spec` (Spec) - The declared interface
- `argv` ({string}) - The argument list (typically the global arg)

**Returns:**

- Parsed - | nil The parse result, or nil on any error
- string? - Error message when the spec or command line is invalid

### help

```teal
function help(spec: Spec): string
```

 Render help text for a spec: a usage line, the summary, and one
 aligned row per option (including the automatic help/version
 entries), with defaults and required markers noted. Returns the
 text without a trailing newline; printing is the caller's job.

**Parameters:**

- `spec` (Spec) - The declared interface

**Returns:**

- string - The rendered help text
