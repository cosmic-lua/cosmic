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

 Multi-command programs (`todo add`, `todo list`, ...) declare a
 CommandSpec — one Spec per subcommand — and dispatch with
 flags.command(cspec, arg); flags.command_help renders the overview
 or a command's page. Same contract as parse: never prints, never
 exits.

   local cspec: flags.CommandSpec = {
     name = "todo",
     summary = "manage a todo list",
     commands = {
       {name = "add", summary = "add a task", spec = {
         usage = "<text...>", options = {}}},
       {name = "list", summary = "list tasks", spec = {options = {
         {long = "all", short = "a", help = "include done tasks"}}}},
     },
   }
   local d, derr = flags.command(cspec, arg)
   if not d then
     io.stderr:write(derr .. "\n")
   elseif d.help then
     print(flags.command_help(cspec, d.command))
   elseif d.command == "add" then
     add_task(d.parsed.args)
   end

## Types

### FlagsModule

```teal
local record FlagsModule
  parse: function(spec: Spec, argv: {string}): Parsed | nil, string
  help: function(spec: Spec): string
  command: function(cspec: CommandSpec, argv: {string}): Dispatched | nil, string
  command_help: function(cspec: CommandSpec, name?: string): string
end
```
