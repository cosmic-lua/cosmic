--- Shared type definitions for the flags module family: the flag and
--- spec vocabulary `parse` consumes, and the command vocabulary
--- `command` dispatches over. Types only — behavior lives in the
--- sibling shards, assembled by init.tl.
local record flags_types

  --- One flag declaration (#991: was `Option` — rule 7 reserves the
  --- Options spelling for kwargs records, and `Spec.options` beside
  --- `Parsed.flags` meant different things one record apart).
  record Flag
    --- Long name, without dashes (e.g. "output" for --output). Required.
    long: string
    --- Optional single-letter short alias, without the dash.
    short: string
    --- Value placeholder shown in help (e.g. "FILE"). Its presence
    --- makes the flag take a value; absent means a boolean switch.
    arg: string
    --- The value may be omitted (`--docs` and `--docs=QUERY` both
    --- parse; the attached form needs `=`). An omitted value reads as
    --- "" in Parsed.values, so presence is still visible.
    arg_optional: boolean
    --- Every occurrence is collected, in order, into Parsed.lists
    --- (valued flags only; without this, the last occurrence wins).
    repeated: boolean
    --- One-line description shown in help.
    help: string
    --- Default value, applied when the flag is absent (valued only).
    default: string
    --- Reject the command line when the flag is absent (valued only).
    required: boolean
  end

  --- A program's declared interface. (Named-rule-7 exemption, recorded
  --- in D20: a CLI interface declaration is not a kwargs bag.)
  record Spec
    --- Program name, used in help (default "program"). Error strings
    --- are NOT prefixed with it (#991) — callers add their own context.
    name: string
    --- One-line description shown in help.
    summary: string
    --- Usage tail shown after the name (default "[options]").
    usage: string
    --- Version string; when set, --version is recognized automatically.
    version: string
    --- The declared flags, in help-display order (#991: was `options`).
    flags: {Flag}
  end

  --- A successful parse.
  record Parsed
    --- Boolean switches by long name (#991: was `flags`); every
    --- declared switch is present (false when absent), so lookups
    --- never need a nil check.
    switches: {string: boolean}
    --- Valued flags by long name, with defaults applied. A `repeated`
    --- flag's last occurrence lands here too; the full list is in
    --- `lists`. An `arg_optional` flag given bare reads as "".
    values: {string: string}
    --- Every occurrence of each `repeated` flag, in order; the list is
    --- present (possibly empty) for every declared repeated flag.
    lists: {string: {string}}
    --- Positional (non-flag) arguments, in order.
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
    --- "<program> <command>", so help names the full invocation.
    spec: Spec
  end

  --- A multi-command program's declared interface.
  record CommandSpec
    --- Program name, used in help (default "program").
    name: string
    --- One-line description shown in the overview help.
    summary: string
    --- Version string; when set, --version is recognized at the top level.
    version: string
    --- The commands, in help-display order.
    commands: {Command}
  end

  --- A successful dispatch. The nils are typed away (#991): `parsed`
  --- is ALWAYS present — on a help/version request it is an empty
  --- Parsed whose help/version field is set, so `d.parsed.args` never
  --- crashes a help path. Only `command` may be nil, and only on a
  --- bare overview request (`prog --help`, `prog --version`), where
  --- there is genuinely no command to name.
  record Dispatched
    --- The selected command's name; nil only on a bare help/version
    --- request (it says which page command_help should render).
    command: string
    --- The command's own parse; never nil.
    parsed: Parsed
    --- True when help was requested — bare (`prog --help`, `prog
    --- help`), per-command (`prog help add`), or by the command's own
    --- --help; `command` says which page command_help should render.
    help: boolean
    --- True when --version was given at the top level.
    version: boolean
  end
end

return flags_types
