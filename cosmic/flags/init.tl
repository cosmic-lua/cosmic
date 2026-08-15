--- Declarative command-line flag parsing with a generated --help.
--- The one public parser — cosmic.getopt is an internal shard of this
--- module. Describe a program's flags once as data — names, value
--- placeholders, defaults, help text — and get parsing, validation,
--- and rendered --help from the one spec.
---
--- Example usage:
---   local flags = require("cosmic.flags")
---   local spec: flags.Spec = {
---     name = "greet",
---     summary = "Greet people from the command line",
---     usage = "[options] <name...>",
---     flags = {
---       {long = "verbose", short = "v", help = "print more detail"},
---       {long = "output", short = "o", arg = "FILE",
---        help = "write to FILE", default = "-"},
---     },
---   }
---   local parsed, err = flags.parse(spec, arg)
---   if not parsed then
---     io.stderr:write("greet: " .. err .. "\n")
---   elseif parsed.help then
---     print(flags.help(spec))
---   else
---     local out = parsed.values["output"]
---     local loud = parsed.switches["verbose"]
---   end
---
--- A flag with an `arg` placeholder takes a value (required, unless
--- `arg_optional`); without one it is a boolean switch. A `repeated`
--- flag collects every occurrence into parsed.lists. --help/-h is
--- recognized automatically (and --version when the spec carries a
--- version) unless the spec claims those names itself; parse never
--- prints or exits — it reports help/version requests as fields on
--- the result and the caller decides what to do. Error strings are
--- unprefixed: add your own program name when printing, the
--- way every other module's errors take context.
---
--- Multi-command programs (`todo add`, `todo list`, ...) declare a
--- CommandSpec — one Spec per subcommand — and dispatch with
--- flags.command(cspec, arg); flags.command_help renders the overview
--- or a command's page. Same contract as parse: never prints, never
--- exits. Options follow the command (`todo add --file x`).
---
---   local cspec: flags.CommandSpec = {
---     name = "todo",
---     summary = "manage a todo list",
---     commands = {
---       {name = "add", summary = "add a task", spec = {
---         usage = "<text...>", flags = {}}},
---       {name = "list", summary = "list tasks", spec = {flags = {
---         {long = "all", short = "a", help = "include done tasks"}}}},
---     },
---   }
---   local d, derr = flags.command(cspec, arg)
---   if not d then
---     io.stderr:write("todo: " .. derr .. "\n")
---   elseif d.help then
---     print(flags.command_help(cspec, d.command))
---   elseif d.command == "add" then
---     add_task(d.parsed.args)
---   end
local flags_command = require("cosmic.flags.command")
local flags_parse = require("cosmic.flags.parse")
local types = require("cosmic.flags.types")

local record FlagsModule
  type Flag = types.Flag
  type Spec = types.Spec
  type Parsed = types.Parsed
  type Command = types.Command
  type CommandSpec = types.CommandSpec
  type Dispatched = types.Dispatched

  parse: function(spec: Spec, argv: {string}): Parsed | nil, string
  help: function(spec: Spec): string
  command: function(cspec: CommandSpec, argv: {string}): Dispatched | nil, string
  command_help: function(cspec: CommandSpec, name?: string): string
end

local M: FlagsModule = {
  parse = flags_parse.parse,
  help = flags_parse.help,
  command = flags_command.command,
  command_help = flags_command.command_help,
}

return M
