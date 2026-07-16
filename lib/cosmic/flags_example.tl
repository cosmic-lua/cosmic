--- Examples for the cosmic.flags module.
--- Demonstrates declaring a program's options once and getting
--- parsing, error messages, and rendered help from the one spec.

-- Example_parse demonstrates the common flow: declare a spec, parse
-- argv, and read flags (booleans), values (with defaults applied),
-- and positional args from the result.
local function Example_parse()
  local flags = require("cosmic.flags")
  local spec: flags.Spec = {
    name = "greet",
    options = {
      {long = "verbose", short = "v", help = "print more detail"},
      {long = "output", short = "o", arg = "FILE",
        help = "write to FILE", default = "-"},
    },
  }
  local parsed = flags.parse(spec, {"-v", "alice"})
  if parsed is flags.Parsed then
    print(parsed.flags["verbose"], parsed.values["output"], parsed.args[1])
  end
  -- Output:
  -- true	-	alice
end

-- Example_errors demonstrates that parse never prints or exits: bad
-- command lines come back as nil plus a one-line message.
local function Example_errors()
  local flags = require("cosmic.flags")
  local spec: flags.Spec = {
    name = "greet",
    options = {{long = "count", arg = "N", help = "repeat", required = true}},
  }
  local _, err = flags.parse(spec, {"--nope"})
  print(err)
  local _, err2 = flags.parse(spec, {})
  print(err2)
  -- Output:
  -- greet: unknown option: --nope (try --help)
  -- greet: missing required option: --count (try --help)
end

-- Example_help demonstrates the rendered help text, including the
-- automatic --help entry and default/required annotations.
local function Example_help()
  local flags = require("cosmic.flags")
  local spec: flags.Spec = {
    name = "greet",
    summary = "Greet people",
    usage = "[options] <name>",
    options = {
      {long = "verbose", short = "v", help = "print more detail"},
      {long = "count", arg = "N", help = "repeat N times", default = "1"},
    },
  }
  print(flags.help(spec))
  -- Output:
  -- usage: greet [options] <name>
  --
  -- Greet people
  --
  -- options:
  --   -v, --verbose  print more detail
  --       --count N  repeat N times (default: 1)
  --   -h, --help     show this help
end

-- Suppress unused warnings for examples
local _ = {Example_parse, Example_errors, Example_help}
