-- test _cli.parse: one case per flag family, asserting the Options
-- fields parse_args produces from a given argv.

local parse = require("_cli.parse")

local function test_script_path()
  _G.arg = {[0] = "cosmic", [1] = "foo.lua", [2] = "bar", [3] = "baz"}
  local opts = parse.parse_args()
  assert(opts.script == "foo.lua", "got: " .. tostring(opts.script))
  assert(opts.script_args[0] == "foo.lua", "got: " .. tostring(opts.script_args[0]))
  assert(opts.script_args[1] == "bar", "got: " .. tostring(opts.script_args[1]))
  assert(opts.script_args[2] == "baz", "got: " .. tostring(opts.script_args[2]))
end

local function test_execute_flag()
  _G.arg = {[0] = "cosmic", [1] = "-e", [2] = "print(1)"}
  local opts = parse.parse_args()
  assert(#opts.execute == 1, "got: " .. tostring(#opts.execute))
  assert(opts.execute[1] == "print(1)", "got: " .. tostring(opts.execute[1]))
  assert(opts.script == nil, "-e alone should not set a script")
end

local function test_load_flag()
  _G.arg = {[0] = "cosmic", [1] = "-l", [2] = "cosmic.json"}
  local opts = parse.parse_args()
  assert(#opts.load == 1, "got: " .. tostring(#opts.load))
  assert(opts.load[1] == "cosmic.json", "got: " .. tostring(opts.load[1]))
end

local function test_double_dash_separator()
  -- `--` ends option parsing; everything after it is the script and
  -- its own args, verbatim.
  _G.arg = {[0] = "cosmic", [1] = "--", [2] = "script.lua", [3] = "a", [4] = "b"}
  local opts = parse.parse_args()
  assert(opts.script == "script.lua", "got: " .. tostring(opts.script))
  assert(opts.script_args[1] == "a", "got: " .. tostring(opts.script_args[1]))
  assert(opts.script_args[2] == "b", "got: " .. tostring(opts.script_args[2]))
end

local function test_optional_arg_flag()
  -- `--examples` takes an optional argument; bare, it parses to the
  -- empty string (present, no value) rather than nil.
  _G.arg = {[0] = "cosmic", [1] = "--examples"}
  local opts = parse.parse_args()
  assert(opts.examples == "", "got: " .. tostring(opts.examples))
end

local function test_diff_flag()
  _G.arg = {[0] = "cosmic", [1] = "--diff", [2] = "old-cosmic"}
  local opts = parse.parse_args()
  assert(opts.diff == "old-cosmic", "got: " .. tostring(opts.diff))
  assert(opts.script == nil, "--diff must not leave its binary as a script")
end

local function test_diff_requires_binary()
  _G.arg = {[0] = "cosmic", [1] = "--diff"}
  local opts = parse.parse_args()
  assert(opts.diff == "", "bare --diff should retain its command marker")
  assert(opts.error == "cosmic-lua: --diff: usage: --diff <binary>",
    "got: " .. tostring(opts.error))
end

local function test_max_lines_flag()
  -- `--max-lines` is an integer option for `--check lint`; absent, it
  -- stays nil so the 500 default lives at the one place that already
  -- held it rather than being duplicated here.
  _G.arg = {[0] = "cosmic", [1] = "--check", [2] = "lint",
    [3] = "--max-lines", [4] = "10", [5] = "foo.tl"}
  local opts = parse.parse_args()
  assert(opts.check_kind == "lint", "got: " .. tostring(opts.check_kind))
  assert(opts.max_lines == 10, "got: " .. tostring(opts.max_lines))
  assert(opts.check_files[1] == "foo.tl", "got: " .. tostring(opts.check_files[1]))

  _G.arg = {[0] = "cosmic", [1] = "--check", [2] = "lint", [3] = "foo.tl"}
  local opts_absent = parse.parse_args()
  assert(opts_absent.max_lines == nil,
    "got: " .. tostring(opts_absent.max_lines))
end
