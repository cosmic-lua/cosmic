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
