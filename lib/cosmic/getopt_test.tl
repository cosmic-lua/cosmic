#!/usr/bin/env cosmic
local getopt = require("cosmic.getopt")

local function test_short_options_no_args()
  local parser = getopt.new({"-h", "-v"}, "hv", nil)
  local opts: {string} = {}
  while true do
    local opt = parser:next()
    if not opt then break end
    table.insert(opts, opt)
  end
  assert(#opts == 2, "expected 2 options, got " .. #opts)
  assert(opts[1] == "h", "expected first option 'h', got '" .. opts[1] .. "'")
  assert(opts[2] == "v", "expected second option 'v', got '" .. opts[2] .. "'")
end
test_short_options_no_args()

local function test_short_option_with_required_arg()
  local parser = getopt.new({"-o", "output.txt"}, "o:", nil)
  local opt, optarg = parser:next()
  assert(opt == "o", "expected option 'o', got '" .. tostring(opt) .. "'")
  assert(optarg == "output.txt", "expected arg 'output.txt', got '" .. tostring(optarg) .. "'")
  local next_opt = parser:next()
  assert(next_opt == nil, "expected no more options")
end
test_short_option_with_required_arg()

local function test_short_option_with_attached_arg()
  local parser = getopt.new({"-ooutput.txt"}, "o:", nil)
  local opt, optarg = parser:next()
  assert(opt == "o", "expected option 'o'")
  assert(optarg == "output.txt", "expected arg 'output.txt', got '" .. tostring(optarg) .. "'")
end
test_short_option_with_attached_arg()

local function test_combined_short_options()
  local parser = getopt.new({"-hv"}, "hv", nil)
  local opts: {string} = {}
  while true do
    local opt = parser:next()
    if not opt then break end
    table.insert(opts, opt)
  end
  assert(#opts == 2, "expected 2 options from combined -hv")
  assert(opts[1] == "h", "expected 'h' first")
  assert(opts[2] == "v", "expected 'v' second")
end
test_combined_short_options()

local function test_long_options()
  local parser = getopt.new({"--help", "--verbose"}, "hv", {
    {name = "help", has_arg = "none", short = "h"},
    {name = "verbose", has_arg = "none", short = "v"},
  })
  local opts: {string} = {}
  while true do
    local opt = parser:next()
    if not opt then break end
    table.insert(opts, opt)
  end
  assert(#opts == 2, "expected 2 long options")
  assert(opts[1] == "help", "expected 'help', got '" .. opts[1] .. "'")
  assert(opts[2] == "verbose", "expected 'verbose', got '" .. opts[2] .. "'")
end
test_long_options()

local function test_long_option_with_equals_arg()
  local parser = getopt.new({"--output=file.txt"}, "o:", {
    {name = "output", has_arg = "required", short = "o"},
  })
  local opt, optarg = parser:next()
  assert(opt == "output", "expected 'output', got '" .. tostring(opt) .. "'")
  assert(optarg == "file.txt", "expected 'file.txt', got '" .. tostring(optarg) .. "'")
end
test_long_option_with_equals_arg()

local function test_long_option_with_separate_arg()
  local parser = getopt.new({"--output", "file.txt"}, "o:", {
    {name = "output", has_arg = "required", short = "o"},
  })
  local opt, optarg = parser:next()
  assert(opt == "output", "expected 'output'")
  assert(optarg == "file.txt", "expected 'file.txt', got '" .. tostring(optarg) .. "'")
end
test_long_option_with_separate_arg()

local function test_remaining_args()
  local parser = getopt.new({"-v", "file1.txt", "file2.txt"}, "v", nil)
  while true do
    local opt = parser:next()
    if not opt then break end
  end
  local remaining = parser:remaining()
  assert(#remaining == 2, "expected 2 remaining args, got " .. #remaining)
  assert(remaining[1] == "file1.txt", "expected 'file1.txt'")
  assert(remaining[2] == "file2.txt", "expected 'file2.txt'")
end
test_remaining_args()

local function test_double_dash_stops_parsing()
  local parser = getopt.new({"-v", "--", "-h", "file.txt"}, "vh", nil)
  local opts: {string} = {}
  while true do
    local opt = parser:next()
    if not opt then break end
    table.insert(opts, opt)
  end
  assert(#opts == 1, "expected 1 option before --, got " .. #opts)
  assert(opts[1] == "v", "expected 'v'")
  local remaining = parser:remaining()
  assert(#remaining == 2, "expected 2 remaining after --, got " .. #remaining)
  assert(remaining[1] == "-h", "expected '-h' as remaining")
  assert(remaining[2] == "file.txt", "expected 'file.txt' as remaining")
end
test_double_dash_stops_parsing()

local function test_unknown_options()
  local parser = getopt.new({"-x", "-y", "-v"}, "v", nil)
  while true do
    local opt = parser:next()
    if not opt then break end
  end
  local unknown = parser:unknown()
  assert(#unknown == 2, "expected 2 unknown options, got " .. #unknown)
end
test_unknown_options()

local function test_repeated_options()
  local parser = getopt.new({"-e", "foo", "-e", "bar", "-e", "baz"}, "e:", nil)
  local excludes: {string} = {}
  while true do
    local opt, optarg = parser:next()
    if not opt then break end
    if opt == "e" then
      table.insert(excludes, optarg)
    end
  end
  assert(#excludes == 3, "expected 3 excludes, got " .. #excludes)
  assert(excludes[1] == "foo", "expected 'foo'")
  assert(excludes[2] == "bar", "expected 'bar'")
  assert(excludes[3] == "baz", "expected 'baz'")
end
test_repeated_options()

local function test_mixed_short_and_long()
  local parser = getopt.new({"-v", "--output", "out.txt", "-h"}, "vho:", {
    {name = "verbose", has_arg = "none", short = "v"},
    {name = "output", has_arg = "required", short = "o"},
    {name = "help", has_arg = "none", short = "h"},
  })
  local results: {{string, string}} = {}
  while true do
    local opt, optarg = parser:next()
    if not opt then break end
    table.insert(results, {opt, optarg or ""})
  end
  assert(#results == 3, "expected 3 options")
  assert(results[1][1] == "v", "expected 'v' first")
  assert(results[2][1] == "output", "expected 'output' second")
  assert(results[2][2] == "out.txt", "expected 'out.txt' as output arg")
  assert(results[3][1] == "h", "expected 'h' third")
end
test_mixed_short_and_long()

local function test_empty_args()
  local parser = getopt.new({}, "hv", nil)
  local opt = parser:next()
  assert(opt == nil, "expected nil for empty args")
  local remaining = parser:remaining()
  assert(#remaining == 0, "expected no remaining args")
  local unknown = parser:unknown()
  assert(#unknown == 0, "expected no unknown options")
end
test_empty_args()

local function test_only_positional_args()
  local parser = getopt.new({"file1.txt", "file2.txt"}, "hv", nil)
  local opt = parser:next()
  assert(opt == nil, "expected nil when no options present")
  local remaining = parser:remaining()
  assert(#remaining == 2, "expected 2 positional args")
  assert(remaining[1] == "file1.txt", "expected 'file1.txt'")
  assert(remaining[2] == "file2.txt", "expected 'file2.txt'")
end
test_only_positional_args()

local function test_long_option_without_short()
  local parser = getopt.new({"--config", "app.json"}, "", {
    {name = "config", has_arg = "required"},
  })
  local opt, optarg = parser:next()
  assert(opt == "config", "expected 'config', got '" .. tostring(opt) .. "'")
  assert(optarg == "app.json", "expected 'app.json'")
end
test_long_option_without_short()
