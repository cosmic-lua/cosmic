--- `cosmic --standalone`: one file checked, compiled and run against
--- the binary's own standard library, with no tree around it.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local standalone = require("build.standalone")

local function test_a_file_compiles_against_the_standard_library()
  local chunk = assert(standalone.compile("x.tl", [[
local Fs = require("cosmic.fs")
return function(argv: {string}): integer
  return #argv + Fs.stdout
end
]]))
  local main = assert(standalone.entry(chunk()))
  assert(main({ "a", "b" }) == 3)
end

local function test_only_the_standard_library_can_be_required()
  local chunk, trouble = standalone.compile("x.tl", 'local w = require("build.work")\nreturn w\n')
  assert(chunk == nil)
  assert(trouble:find("x.tl:1:", 1, true) ~= nil, trouble)
  assert(trouble:find("build.work", 1, true) ~= nil, trouble)
end

local function test_a_type_error_is_reported_with_its_place()
  local chunk, trouble = standalone.compile("bad.tl", "local x: integer = \"no\"\nreturn x\n")
  assert(chunk == nil)
  assert(trouble:find("bad.tl:1:", 1, true) ~= nil, trouble)
end

local function test_a_record_with_main_is_an_entry_point()
  local function main(): integer
    return 7
  end
  assert(standalone.entry({ main = main }) == main)
  assert(standalone.entry(main) == main)
  assert(standalone.entry({ other = main }) == nil)
  assert(standalone.entry(42) == nil)
end

--- End to end, from a directory holding no tree: the file gets its own
--- path at argv[0] and what follows it, its exit code is the process's,
--- and nothing is written beside it -- no `o/`.
local function test_a_run_writes_nothing_and_passes_its_arguments(tmp: string)
  local script = tmp .. "/script.tl"
  assert(Fs.write(script, [[
local Fs = require("cosmic.fs")
local record Script
  main: function({string}): integer
end
Script.main = function(argv: {string}): integer
  Fs.put(Fs.stdout, argv[0] .. "|" .. table.concat(argv, ",") .. "\n")
  return 5
end
return Script
]]))
  local cosmic = assert(Proc.executable())
  local result = assert(Child.run({ cosmic, "--standalone", script, "one", "two" }, {
    cwd = tmp, stdout = "capture", stderr = "capture", timeout_ms = 30000,
  }))
  assert(result.code == 5, tostring(result.stderr))
  assert(result.stdout == script .. "|one,two\n", tostring(result.stdout))
  local names = assert(Fs.list(tmp))
  assert(#names == 1 and names[1] == "script.tl", "a standalone run wrote beside the file")
end

local function test_a_run_without_a_file_is_a_usage_error()
  local cosmic = assert(Proc.executable())
  local result = assert(Child.run({ cosmic, "--standalone" }, {
    stdout = "capture", stderr = "capture", timeout_ms = 30000,
  }))
  assert(result.code == 2)
  assert(tostring(result.stderr):find("usage", 1, true) ~= nil)
end
