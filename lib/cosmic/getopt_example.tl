--- Examples for the cosmic.getopt module.
--- Demonstrates one-shot parsing of short and long options, positional
--- arguments, and unknown-option reporting.

-- Example_parse_short demonstrates classic short-option parsing:
-- in the optstring "vo:", -v is a flag and -o requires an argument.
-- Everything that is not an option lands in result.args.
local function Example_parse_short()
  local check = require("cosmic.check")
  local getopt = require("cosmic.getopt")
  local result = check.must(getopt.parse(
      {"-v", "-o", "out.txt", "input.txt"}, "vo:"))
  for _, opt in ipairs(result.opts) do
    print(opt.opt .. "=" .. tostring(opt.arg))
  end
  print(result.args[1])
  -- Output:
  -- v=nil
  -- o=out.txt
  -- input.txt
end

-- Example_parse_long demonstrates long options declared as LongOpt
-- records. A long option with a short alias reports as that short
-- letter, so --verbose and -v are indistinguishable to the caller.
local function Example_parse_long()
  local check = require("cosmic.check")
  local getopt = require("cosmic.getopt")
  local longopts: {getopt.LongOpt} = {
    {name = "verbose", has_arg = "none", short = "v"},
    {name = "output", has_arg = "required", short = "o"},
  }
  local result = check.must(getopt.parse(
      {"--verbose", "--output=out.txt", "file.txt"}, "vo:", longopts))
  for _, opt in ipairs(result.opts) do
    print(opt.opt .. "=" .. tostring(opt.arg))
  end
  print(result.args[1])
  -- Output:
  -- v=nil
  -- o=out.txt
  -- file.txt
end

-- Example_unknown_and_missing demonstrates the error channels: options
-- not in the optstring collect in result.unknown (dashes included),
-- and options whose required argument is absent collect in
-- result.missing (as the bare option letter).
local function Example_unknown_and_missing()
  local check = require("cosmic.check")
  local getopt = require("cosmic.getopt")
  local result = check.must(getopt.parse({"-x", "-o"}, "vo:"))
  print(result.unknown[1])
  print(result.missing[1])
  -- Output:
  -- -x
  -- o
end

-- Suppress unused warnings for examples
local _ = {Example_parse_short, Example_parse_long, Example_unknown_and_missing}
