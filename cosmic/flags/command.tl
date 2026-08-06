--- The multi-command half of the flags family: dispatch argv[1] to one
--- of a program's subcommands, each with its own Spec, and render the
--- overview help. Shard of cosmic.flags; the public surface is
--- init.tl's. Same contract as parse: never prints, never exits.
local flags_parse = require("cosmic.flags.parse")
local types = require("cosmic.flags.types")

local type Spec = types.Spec
local type Parsed = types.Parsed
local type Command = types.Command
local type CommandSpec = types.CommandSpec
local type Dispatched = types.Dispatched

local function find_command(cspec: CommandSpec, name: string): Command
  for _, cmd in ipairs(cspec.commands or {}) do
    if cmd.name == name then
      return cmd
    end
  end
  return nil
end

local function command_names(cspec: CommandSpec): string
  local names: {string} = {}
  for _, cmd in ipairs(cspec.commands or {}) do
    names[#names + 1] = cmd.name
  end
  return table.concat(names, ", ")
end

--- Validate a command spec. nil when sound, else a message naming the
--- defect — the same never-throw shape as everything here.
local function validate_commands(cspec: CommandSpec): string
  local pname = cspec.name or "program"
  if not cspec.commands or #cspec.commands == 0 then
    return pname .. ": invalid spec: no commands declared"
  end
  local seen: {string: boolean} = {}
  for _, cmd in ipairs(cspec.commands) do
    if not cmd.name or #cmd.name == 0 then
      return pname .. ": invalid spec: command without a name"
    end
    if seen[cmd.name] then
      return pname .. ": invalid spec: duplicate command '" .. cmd.name .. "'"
    end
    seen[cmd.name] = true
    if not cmd.spec then
      return pname .. ": invalid spec: command '" .. cmd.name .. "' has no spec"
    end
  end
  return nil
end

--- The command's spec with its name defaulted to "<program> <command>",
--- copied rather than mutated — the caller's spec is data, not scratch.
local function qualified_spec(cspec: CommandSpec, cmd: Command): Spec
  if cmd.spec.name then
    return cmd.spec
  end
  return {
    name = (cspec.name or "program") .. " " .. cmd.name,
    summary = cmd.spec.summary or cmd.summary,
    usage = cmd.spec.usage,
    version = cmd.spec.version,
    options = cmd.spec.options,
  }
end

--- Dispatch a command line to one of a program's subcommands.
--- argv[1] selects the command; the rest parses against that command's
--- own Spec. `prog --help`/`prog help` and `prog help <command>` come
--- back as help requests (never printed here), --version likewise when
--- the spec carries a version. No command, an unknown command, or a
--- failed sub-parse is nil plus a one-line message naming the commands.
--- @param cspec CommandSpec The declared interface
--- @param argv {string} The argument list (typically the global arg)
--- @return Dispatched | nil The dispatch result, or nil on any error
--- @return string? Error message when the spec or command line is invalid
local function command(cspec: CommandSpec, argv: {string}): Dispatched | nil, string
  local invalid = validate_commands(cspec)
  if invalid then
    return nil, invalid
  end
  local pname = cspec.name or "program"
  local first = argv and argv[1]
  if not first then
    return nil, pname .. ": expected a command: " .. command_names(cspec)
    .. " (try --help)"
  end
  if first == "--help" or first == "-h" or first == "help" then
    local target: string = nil
    if first == "help" then
      target = argv[2]
    end
    if target then
      if not find_command(cspec, target) then
        return nil, pname .. ": unknown command '" .. target .. "': "
        .. command_names(cspec)
      end
      return {command = target, help = true, version = false}
    end
    return {help = true, version = false}
  end
  if cspec.version and first == "--version" then
    return {help = false, version = true}
  end
  local cmd = find_command(cspec, first)
  if not cmd then
    return nil, pname .. ": unknown command '" .. first .. "': "
    .. command_names(cspec) .. " (try --help)"
  end
  local rest: {string} = {}
  for i = 2, #argv do
    rest[#rest + 1] = argv[i]
  end
  local parsed, perr = flags_parse.parse(qualified_spec(cspec, cmd), rest)
  if not parsed then
    return nil, perr
  end
  local p = parsed as Parsed -- cast: record union after guard
  return {command = first, parsed = p, help = p.help, version = false}
end

--- Render help for a multi-command program: the overview (usage,
--- summary, aligned command list) or, given a command's name, that
--- command's own page. Returns text without a trailing newline.
--- @param cspec CommandSpec The declared interface
--- @param name? string A command's name, for its own page
--- @return string The rendered help text
local function command_help(cspec: CommandSpec, name?: string): string
  local pname = cspec.name or "program"
  if name then
    local cmd = find_command(cspec, name)
    if cmd then
      return flags_parse.help(qualified_spec(cspec, cmd))
    end
  end
  local lines: {string} = {
    "usage: " .. pname .. " <command> [options]",
  }
  if cspec.summary then
    lines[#lines + 1] = ""
    lines[#lines + 1] = cspec.summary
  end
  local width = 0
  for _, cmd in ipairs(cspec.commands or {}) do
    if #cmd.name > width then
      width = #cmd.name
    end
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "commands:"
  for _, cmd in ipairs(cspec.commands or {}) do
    local row = "  " .. cmd.name .. string.rep(" ", width - #cmd.name)
    local desc = cmd.summary or (cmd.spec and cmd.spec.summary)
    if desc then
      row = row .. "  " .. desc
    end
    lines[#lines + 1] = row
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "run '" .. pname .. " help <command>' for command options"
  return table.concat(lines, "\n")
end

local record CommandModule
  command: function(cspec: CommandSpec, argv: {string}): Dispatched | nil, string
  command_help: function(cspec: CommandSpec, name?: string): string
end

local M: CommandModule = {
  command = command,
  command_help = command_help,
}

return M
