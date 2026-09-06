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
