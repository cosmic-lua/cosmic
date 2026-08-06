--- Shared type definitions for the flags module family: the option and
--- spec vocabulary `parse` consumes, and the command vocabulary
--- `command` dispatches over. Types only — behavior lives in the
--- sibling shards, assembled by init.tl.
local record flags_types

  --- One option declaration.
  record Option
    --- Long name, without dashes (e.g. "output" for --output). Required.
    long: string
    --- Optional single-letter short alias, without the dash.
    short: string
    --- Value placeholder shown in help (e.g. "FILE"). Its presence
    --- makes the option take a required value; absent means boolean.
    arg: string
    --- One-line description shown in help.
    help: string
    --- Default value, applied when the option is absent (valued only).
    default: string
    --- Reject the command line when the option is absent (valued only).
    required: boolean
  end

  --- A program's declared interface.
  record Spec
    --- Program name, used in error messages and help (default "program").
    name: string
    --- One-line description shown in help.
    summary: string
    --- Usage tail shown after the name (default "[options]").
    usage: string
    --- Version string; when set, --version is recognized automatically.
    version: string
    --- The declared options, in help-display order.
    options: {Option}
  end

  --- A successful parse.
  record Parsed
    --- Boolean options by long name; every declared flag is present
    --- (false when absent), so lookups never need a nil check.
    flags: {string: boolean}
    --- Valued options by long name, with defaults applied.
    values: {string: string}
    --- Positional (non-option) arguments, in order.
    args: {string}
    --- True when --help / -h was given.
    help: boolean
    --- True when --version was given (specs with a version only).
    version: boolean
  end

  --- One subcommand of a multi-command program.
  record Command
    --- Name as typed on the command line. Required, unique.
    name: string
    --- One-line description shown in the command list.
    summary: string
    --- The command's own interface. Its `name` defaults to
    --- "<program> <command>", so errors and help name the full invocation.
    spec: Spec
  end

  --- A multi-command program's declared interface.
  record CommandSpec
    --- Program name, used in error messages and help (default "program").
    name: string
    --- One-line description shown in the overview help.
    summary: string
    --- Version string; when set, --version is recognized at the top level.
    version: string
    --- The commands, in help-display order.
    commands: {Command}
  end

  --- A successful dispatch.
  record Dispatched
    --- The selected command's name; nil on a bare help/version request.
    command: string
    --- The command's own parse; nil on a help/version request.
    parsed: Parsed
    --- True when help was requested — bare (`prog --help`, `prog help`),
    --- per-command (`prog help add`), or by the command's own --help;
    --- `command` says which page command_help should render.
    help: boolean
    --- True when --version was given at the top level.
    version: boolean
  end
end

return flags_types
