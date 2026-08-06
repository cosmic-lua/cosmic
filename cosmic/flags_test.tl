--- Tests for cosmic.flags.
local check = require("cosmic.check")
local flags = require("cosmic.flags")

local spec: flags.Spec = {
  name = "greet",
  summary = "Greet people from the command line",
  version = "1.2.3",
  usage = "[options] <name...>",
  options = {
    {long = "verbose", short = "v", help = "print more detail"},
    {long = "output", short = "o", arg = "FILE", help = "write to FILE", default = "-"},
    {long = "count", arg = "N", help = "repeat N times", required = true},
  },
}

-- Parse a command line that must succeed.
local function must(s: flags.Spec, argv: {string}): flags.Parsed
  return (check.must(flags.parse(s, argv)))
end

local function test_short_and_long_forms()
  local p = must(spec, {"-v", "--output", "out.txt", "--count", "3", "alice", "bob"})
  assert(p.flags["verbose"] == true)
  assert(p.values["output"] == "out.txt")
  assert(p.values["count"] == "3")
  assert(#p.args == 2 and p.args[1] == "alice" and p.args[2] == "bob")
  assert(p.help == false and p.version == false)
end
test_short_and_long_forms()

local function test_defaults_and_absent_flags()
  local p = must(spec, {"--count", "1"})
  assert(p.values["output"] == "-", "default not applied")
  assert(p.flags["verbose"] == false, "absent flag should be false, not nil")
  assert(#p.args == 0)
end
test_defaults_and_absent_flags()

local function test_repeated_valued_option_keeps_last()
  local p = must(spec, {"--count", "1", "-o", "a", "-o", "b"})
  assert(p.values["output"] == "b", "got: " .. p.values["output"])
end
test_repeated_valued_option_keeps_last()

local function test_missing_required_option()
  local p, err = flags.parse(spec, {"-v"})
  assert(not p, "expected failure")
  assert(err and err:find("greet: missing required option: --count", 1, true),
    "got: " .. tostring(err))
end
test_missing_required_option()

local function test_unknown_option()
  local p, err = flags.parse(spec, {"--count", "1", "--nope"})
  assert(not p, "expected failure")
  assert(err and err:find("greet: unknown option: --nope", 1, true),
    "got: " .. tostring(err))
end
test_unknown_option()

local function test_missing_value()
  local p, err = flags.parse(spec, {"--output"})
  assert(not p, "expected failure")
  assert(err and err:find("greet: option requires a value: --output", 1, true),
    "got: " .. tostring(err))
end
test_missing_value()

local function test_auto_help()
  -- --help must work even though the required --count is absent.
  local p = must(spec, {"--help"})
  assert(p.help == true)
  local p2 = must(spec, {"-h"})
  assert(p2.help == true)
end
test_auto_help()

local function test_auto_version()
  local p = must(spec, {"--version"})
  assert(p.version == true)
  local unversioned: flags.Spec = {name = "x", options = {}}
  local p2, err = flags.parse(unversioned, {"--version"})
  assert(not p2, "expected --version to be unknown without spec.version")
  assert(err and err:find("unknown option", 1, true), "got: " .. tostring(err))
end
test_auto_version()

-- FIX 13: a spec with NO version string that declares its own --version
-- boolean flag must not have that flag mirrored onto parsed.version too
-- (the doc says parsed.version is set for "specs with a version only").
local function test_user_declared_version_flag_not_mirrored()
  local custom: flags.Spec = {
    name = "x",
    options = {{long = "version", help = "print this program's own thing"}},
  }
  local p = must(custom, {"--version"})
  assert(p.flags["version"] == true, "the user's own --version flag should still parse")
  assert(p.version == false,
    "parsed.version must stay false: spec.version was never set")
end
test_user_declared_version_flag_not_mirrored()

local function test_spec_claims_help_name()
  local custom: flags.Spec = {
    name = "x",
    options = {{long = "help", short = "H", arg = "TOPIC", help = "topic help"}},
  }
  local p = must(custom, {"--help", "parsing"})
  assert(p.values["help"] == "parsing")
  assert(p.help == false, "user-claimed valued --help must not read as a help request")
end
test_spec_claims_help_name()

local function test_invalid_specs()
  local cases: {{flags.Spec, string}} = {
    {{name = "x", options = {{long = "a"}, {long = "a"}}}, "duplicate option --a"},
    {{name = "x", options = {{long = "a", short = "z"}, {long = "b", short = "z"}}},
      "duplicate short option -z"},
    {{name = "x", options = {{long = "a", short = "ab"}}}, "one letter"},
    {{name = "x", options = {{long = "a", default = "d"}}}, "boolean"},
    {{name = "x", options = {{long = "a", arg = "V", default = "d", required = true}}},
      "required and defaulted"},
    {{name = "x", options = {{long = ""}}}, "without a long name"},
  }
  for i, case in ipairs(cases) do
    local p, err = flags.parse(case[1], {})
    assert(not p, "case " .. tostring(i) .. " unexpectedly parsed")
    assert(err and err:find(case[2], 1, true),
      "case " .. tostring(i) .. " got: " .. tostring(err))
  end
end
test_invalid_specs()

local function test_help_rendering()
  local text = flags.help(spec)
  assert(text:find("usage: greet [options] <name...>", 1, true), text)
  assert(text:find("Greet people from the command line", 1, true), text)
  assert(text:find("-v, --verbose", 1, true), text)
  assert(text:find("-o, --output FILE", 1, true), text)
  assert(text:find("write to FILE (default: -)", 1, true), text)
  assert(text:find("--count N", 1, true), text)
  assert(text:find("repeat N times (required)", 1, true), text)
  assert(text:find("-h, --help", 1, true), text)
  assert(text:find("--version", 1, true), text)
  assert(not text:find("\n$"), "trailing newline")
end
test_help_rendering()

local function test_help_rows_align()
  local text = flags.help(spec)
  local verbose_col: number = nil
  local output_col: number = nil
  for line in text:gmatch("[^\n]+") do
    if line:find("print more detail", 1, true) then
      verbose_col = line:find("print more detail", 1, true)
    end
    if line:find("write to FILE", 1, true) then
      output_col = line:find("write to FILE", 1, true)
    end
  end
  assert(verbose_col and output_col, "option rows missing from help output")
  assert(verbose_col == output_col, "descriptions are not column-aligned")
end
test_help_rows_align()

-- flags.command: dispatch on argv[1], each command its own Spec.
local function make_cspec(): flags.CommandSpec
  return {
    name = "todo",
    summary = "manage a todo list",
    version = "1.0",
    commands = {
      {name = "add", summary = "add a task", spec = {
          usage = "<text...>",
          options = {},
        }},
      {name = "list", summary = "list tasks", spec = {
          options = {
            {long = "all", short = "a", help = "include done tasks"},
          },
        }},
    },
  }
end

local function test_command_dispatches_with_options()
  local d = check.must(flags.command(make_cspec(), {"list", "--all"}))
  assert(d.command == "list", "command: " .. tostring(d.command))
  assert(d.parsed.flags["all"] == true, "sub-option should parse")
  assert(not d.help and not d.version, "plain dispatch is not help/version")

  local d2 = check.must(flags.command(make_cspec(), {"add", "buy", "milk"}))
  assert(d2.command == "add", "command: " .. tostring(d2.command))
  assert(#d2.parsed.args == 2 and d2.parsed.args[1] == "buy",
    "positionals reach the subcommand")
end
test_command_dispatches_with_options()

local function test_command_errors_name_the_commands()
  local d, err = flags.command(make_cspec(), {})
  assert(d == nil, "no command is an error")
  assert(err:find("add, list", 1, true), "error names the commands: " .. err)

  local d2, err2 = flags.command(make_cspec(), {"frob"})
  assert(d2 == nil, "unknown command is an error")
  assert(err2:find("unknown command 'frob'", 1, true), "got: " .. err2)

  -- A sub-parse failure carries the qualified program name, so the
  -- reader knows which command's options were wrong.
  local d3, err3 = flags.command(make_cspec(), {"list", "--bogus"})
  assert(d3 == nil, "unknown sub-option is an error")
  assert(err3:find("todo list:", 1, true), "qualified name: " .. err3)
end
test_command_errors_name_the_commands()

local function test_command_help_and_version_forms()
  for _, argv in ipairs({{"--help"}, {"-h"}, {"help"}}) do
    local d = check.must(flags.command(make_cspec(), argv))
    assert(d.help and d.command == nil, "bare help request")
  end

  local d = check.must(flags.command(make_cspec(), {"help", "list"}))
  assert(d.help and d.command == "list", "help for one command")

  local bad, err = flags.command(make_cspec(), {"help", "frob"})
  assert(bad == nil and err:find("unknown command", 1, true),
    "help for an unknown command is an error")

  local sub = check.must(flags.command(make_cspec(), {"list", "--help"}))
  assert(sub.help and sub.command == "list",
    "a command's own --help propagates")

  local v = check.must(flags.command(make_cspec(), {"--version"}))
  assert(v.version and not v.help, "top-level --version")
end
test_command_help_and_version_forms()

local function test_command_validates_the_spec()
  local none, err = flags.command({name = "x", commands = {}}, {"y"})
  assert(none == nil and err:find("no commands", 1, true), "got: " .. tostring(err))

  local dup, err2 = flags.command({name = "x", commands = {
        {name = "a", spec = {options = {}}},
        {name = "a", spec = {options = {}}},
      }}, {"a"})
  assert(dup == nil and err2:find("duplicate command", 1, true),
    "got: " .. tostring(err2))
end
test_command_validates_the_spec()

local function test_command_help_renders_overview_and_page()
  local overview = flags.command_help(make_cspec())
  assert(overview:find("usage: todo <command>", 1, true), "usage line")
  assert(overview:find("add", 1, true) and overview:find("list tasks", 1, true),
    "command list with summaries")
  assert(overview:find("todo help <command>", 1, true), "help pointer")

  local page = flags.command_help(make_cspec(), "list")
  assert(page:find("usage: todo list", 1, true),
    "per-command page carries the qualified name: " .. page)
  assert(page:find("--all", 1, true), "per-command page lists its options")
end
test_command_help_renders_overview_and_page()
