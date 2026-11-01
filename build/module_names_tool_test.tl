--- A module is required by its whole module path, the name the run time resolves: `b/m.tl` is `b.m`, and `require("m")` is
--- refused when the project is checked, naming the module it may have meant, where it used to pass the check and fail at run
--- time with "no module 'm' in the store" (build/driver.tl's `Driver.index`).

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local this_program = require("build.this_program")

--- The program itself, which builds the tree around the file it runs.
Test.policy{ profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" } } }

local MODULE <const> = "local record M\n  n: integer\nend\nlocal m: M = { n = 7 }\nreturn m\n"

--- Runs `file` in the project `files` (by name) makes under `tmp`, as this program.
local function run_in(tmp: string, name: string, files: {string:string}, file: string): Child.Result
  local root = tmp .. "/" .. name
  assert(Fs.mkdirs(root))
  for each, source in pairs(files) do
    assert(Fs.mkdirs(Fs.dirname(root .. "/" .. each)))
    assert(Fs.write(root .. "/" .. each, source))
  end
  local env = this_program.environment()
  env["COSMIC_BUILD_CACHE"] = "0"
  local started = this_program.program({ file }, { cwd = root, env = env, stdout = "capture", stderr = "capture",
    timeout_ns = Clock.seconds(60) })
  return (assert(Child.run(started.argv, started.options)))
end

local function test_a_module_required_by_its_whole_path_checks_and_runs(tmp: string)
  local result = run_in(tmp, "whole", { ["b/m.tl"] = MODULE,
    ["main.tl"] = 'local m = require("b.m")\nprint(m.n)\n' }, "main.tl")
  assert(result.code == 0 and result.stdout == "7\n", tostring(result.stdout) .. tostring(result.stderr))
end

local function test_the_bare_last_segment_of_a_module_is_refused_before_it_runs(tmp: string)
  local result = run_in(tmp, "bare", { ["b/m.tl"] = MODULE,
    ["main.tl"] = 'local m = require("m")\nprint(m.n)\n' }, "main.tl")
  local said = tostring(result.stdout) .. tostring(result.stderr)
  assert(result.code ~= 0 and result.stdout == "", said)
  assert(said:find("the project has no module `m`; did you mean `b.m` (b/m.tl)?", 1, true) ~= nil, said)
  assert(said:find("no module 'm' in the store", 1, true) == nil, said)
end

local function test_two_modules_ending_in_the_name_are_refused_and_both_named(tmp: string)
  local result = run_in(tmp, "two", { ["a/m.tl"] = MODULE, ["b/m.tl"] = MODULE,
    ["main.tl"] = 'local m = require("m")\nprint(m.n)\n' }, "main.tl")
  local said = tostring(result.stdout) .. tostring(result.stderr)
  assert(result.code ~= 0 and result.stdout == "", said)
  assert(said:find("did you mean one of `a.m` (a/m.tl), `b.m` (b/m.tl)?", 1, true) ~= nil, said)
end
