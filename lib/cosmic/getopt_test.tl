#!/usr/bin/env cosmic
local check = require("cosmic.check")
local getopt = require("cosmic.getopt")

-- Collect the option letters/names from a parse result, in order.
local function opt_names(r: getopt.Result): {string}
  local names: {string} = {}
  for _, o in ipairs(r.opts) do
    table.insert(names, o.opt)
  end
  return names
end

local function test_short_options_no_args()
  local r = check.must(getopt.parse({"-h", "-v"}, "hv"))
  local opts = opt_names(r)
  assert(#opts == 2, "expected 2 options, got " .. #opts)
  assert(opts[1] == "h", "expected first option 'h', got '" .. opts[1] .. "'")
  assert(opts[2] == "v", "expected second option 'v', got '" .. opts[2] .. "'")
end
test_short_options_no_args()

local function test_short_option_with_required_arg()
  local r = check.must(getopt.parse({"-o", "output.txt"}, "o:"))
  assert(#r.opts == 1, "expected 1 option")
  assert(r.opts[1].opt == "o", "expected option 'o', got '" .. tostring(r.opts[1].opt) .. "'")
  assert(r.opts[1].arg == "output.txt", "expected arg 'output.txt', got '" .. tostring(r.opts[1].arg) .. "'")
end
test_short_option_with_required_arg()

local function test_short_option_with_attached_arg()
  local r = check.must(getopt.parse({"-ooutput.txt"}, "o:"))
  assert(r.opts[1].opt == "o", "expected option 'o'")
  assert(r.opts[1].arg == "output.txt", "expected arg 'output.txt', got '" .. tostring(r.opts[1].arg) .. "'")
end
test_short_option_with_attached_arg()

local function test_combined_short_options()
  local r = check.must(getopt.parse({"-hv"}, "hv"))
  local opts = opt_names(r)
  assert(#opts == 2, "expected 2 options from combined -hv")
  assert(opts[1] == "h", "expected 'h' first")
  assert(opts[2] == "v", "expected 'v' second")
end
test_combined_short_options()

local function test_long_options_with_short_alias()
  -- When long options have short aliases, parse yields the short form
  local r = check.must(getopt.parse({"--help", "--verbose"}, "hv", {
        {name = "help", has_arg = "none", short = "h"},
        {name = "verbose", has_arg = "none", short = "v"},
      }))
  local opts = opt_names(r)
  assert(#opts == 2, "expected 2 long options")
  assert(opts[1] == "h", "expected 'h', got '" .. opts[1] .. "'")
  assert(opts[2] == "v", "expected 'v', got '" .. opts[2] .. "'")
end
test_long_options_with_short_alias()

local function test_long_option_with_equals_arg()
  -- Returns short alias 'o' since one is defined
  local r = check.must(getopt.parse({"--output=file.txt"}, "o:", {
        {name = "output", has_arg = "required", short = "o"},
      }))
  assert(r.opts[1].opt == "o", "expected 'o', got '" .. tostring(r.opts[1].opt) .. "'")
  assert(r.opts[1].arg == "file.txt", "expected 'file.txt', got '" .. tostring(r.opts[1].arg) .. "'")
end
test_long_option_with_equals_arg()

local function test_long_option_with_separate_arg()
  -- Returns short alias 'o' since one is defined
  local r = check.must(getopt.parse({"--output", "file.txt"}, "o:", {
        {name = "output", has_arg = "required", short = "o"},
      }))
  assert(r.opts[1].opt == "o", "expected 'o'")
  assert(r.opts[1].arg == "file.txt", "expected 'file.txt', got '" .. tostring(r.opts[1].arg) .. "'")
end
test_long_option_with_separate_arg()

local function test_remaining_args()
  local r = check.must(getopt.parse({"-v", "file1.txt", "file2.txt"}, "v"))
  assert(#r.args == 2, "expected 2 remaining args, got " .. #r.args)
  assert(r.args[1] == "file1.txt", "expected 'file1.txt'")
  assert(r.args[2] == "file2.txt", "expected 'file2.txt'")
end
test_remaining_args()

local function test_double_dash_stops_parsing()
  local r = check.must(getopt.parse({"-v", "--", "-h", "file.txt"}, "vh"))
  assert(#r.opts == 1, "expected 1 option before --, got " .. #r.opts)
  assert(r.opts[1].opt == "v", "expected 'v'")
  assert(#r.args == 2, "expected 2 remaining after --, got " .. #r.args)
  assert(r.args[1] == "-h", "expected '-h' as remaining")
  assert(r.args[2] == "file.txt", "expected 'file.txt' as remaining")
end
test_double_dash_stops_parsing()

local function test_unknown_options()
  local r = check.must(getopt.parse({"-x", "-y", "-v"}, "v"))
  assert(#r.unknown == 2, "expected 2 unknown options, got " .. #r.unknown)
  -- unknown options are spelled with their dashes
  assert(r.unknown[1] == "-x", "expected '-x', got '" .. r.unknown[1] .. "'")
  assert(r.unknown[2] == "-y", "expected '-y', got '" .. r.unknown[2] .. "'")
  -- the recognized option is still parsed
  assert(#r.opts == 1 and r.opts[1].opt == "v", "expected 'v' to still parse")
end
test_unknown_options()

local function test_missing_required_arg()
  -- A required argument that's absent lands in `missing` (not `unknown`),
  -- named without dashes.
  local r = check.must(getopt.parse({"-o"}, "o:"))
  assert(#r.missing == 1, "expected 1 missing option, got " .. #r.missing)
  assert(r.missing[1] == "o", "expected missing 'o', got '" .. r.missing[1] .. "'")
  assert(#r.unknown == 0, "a missing argument is not an unknown option")
  assert(#r.opts == 0, "the incomplete option is not reported as parsed")
end
test_missing_required_arg()

local function test_repeated_options()
  local r = check.must(getopt.parse({"-e", "foo", "-e", "bar", "-e", "baz"}, "e:"))
  local excludes: {string} = {}
  for _, o in ipairs(r.opts) do
    if o.opt == "e" then
      table.insert(excludes, o.arg)
    end
  end
  assert(#excludes == 3, "expected 3 excludes, got " .. #excludes)
  assert(excludes[1] == "foo", "expected 'foo'")
  assert(excludes[2] == "bar", "expected 'bar'")
  assert(excludes[3] == "baz", "expected 'baz'")
end
test_repeated_options()

local function test_mixed_short_and_long()
  -- All options return short form since short aliases are defined
  local r = check.must(getopt.parse({"-v", "--output", "out.txt", "-h"}, "vho:", {
        {name = "verbose", has_arg = "none", short = "v"},
        {name = "output", has_arg = "required", short = "o"},
        {name = "help", has_arg = "none", short = "h"},
      }))
  assert(#r.opts == 3, "expected 3 options")
  assert(r.opts[1].opt == "v", "expected 'v' first")
  assert(r.opts[2].opt == "o", "expected 'o' second")
  assert(r.opts[2].arg == "out.txt", "expected 'out.txt' as output arg")
  assert(r.opts[3].opt == "h", "expected 'h' third")
end
test_mixed_short_and_long()

local function test_empty_args()
  local r = check.must(getopt.parse({}, "hv"))
  assert(#r.opts == 0, "expected no options for empty args")
  assert(#r.args == 0, "expected no remaining args")
  assert(#r.unknown == 0, "expected no unknown options")
  assert(#r.missing == 0, "expected no missing options")
end
test_empty_args()

local function test_only_positional_args()
  local r = check.must(getopt.parse({"file1.txt", "file2.txt"}, "hv"))
  assert(#r.opts == 0, "expected no options when none present")
  assert(#r.args == 2, "expected 2 positional args")
  assert(r.args[1] == "file1.txt", "expected 'file1.txt'")
  assert(r.args[2] == "file2.txt", "expected 'file2.txt'")
end
test_only_positional_args()

local function test_long_option_without_short()
  local r = check.must(getopt.parse({"--config", "app.json"}, "", {
        {name = "config", has_arg = "required"},
      }))
  assert(r.opts[1].opt == "config", "expected 'config', got '" .. tostring(r.opts[1].opt) .. "'")
  assert(r.opts[1].arg == "app.json", "expected 'app.json'")
end
test_long_option_without_short()
