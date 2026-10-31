--- What a main function returns is the program's exit status, and one it
--- cannot be is refused rather than passed on (core/check.h,
--- `cosmic_tostatus`), in programs built from a tree and run. A file of
--- its own rather than a case of build/embed_test.tl, which the CI
--- fixtures run as a timed workload.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local embed = require("build.embed")
local Test = require("cosmic.test")
local Clock = require("cosmic.clock")
local build_paths = require("build.paths")

--- The program itself, whose core the programs it builds run on.
--- `store`: [`embed.tree`] joins every `cosmic.*` module's rows.
Test.policy{
  profiles = { "cosmic" },
  grants = { { path = "o/bin", letters = "rx" }, { path = "o/cosmic.db", letters = "r" } },
}

--- `root`'s build directory ([`build.paths`]), made, with `root` made
--- first where it is not there yet.
local function build_dir(root: string): string
  assert(Fs.mkdirs(root))
  return (assert(build_paths.prepare(root)))
end

local function run_program(path: string, expression: string): Child.Result
  return (assert(Child.run({ path, expression }, {
    stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(30) })))
end

--- The one program every case runs, so the tree is built once: its main returns the value of the Lua expression
--- it is given, whatever type that is (a main's result is read at run time, whatever it is declared). Building
--- a program joins every `cosmic.*` module's rows, which a program of its own for each case would do nine times.
local MAIN <const> = [[
return function(args: {string}): any
  local chunk = assert(load("return " .. (args[1] or "nil"), "=status", "t"))
  return chunk()
end
]]

--- An exit keeps only the low byte, so 256 would read as success. It is
--- refused with exit 2, as are a negative number, a fraction, other text
--- and a boolean. Nil is 0, and a float with an integer's value, or text
--- naming one, is that integer.
local function test_a_main_that_returns_no_exit_status_is_refused(tmp: string)
  assert(Fs.mkdirs(tmp .. "/cmd/status"))
  assert(Fs.write(tmp .. "/cmd/status/main.tl", MAIN))
  assert(embed.tree(tmp, true))
  local program = build_dir(tmp) .. "/bin/status"
  for expression, code in pairs({ ["7"] = 7, ["3.0"] = 3, ["nil"] = 0, ["\"5\""] = 5 } as {string:integer}) do
    local r = run_program(program, expression)
    assert(r.code == code, "an exit status that fits is the program's own: " ..
        expression .. " exited " .. tostring(r.code) .. ": " .. tostring(r.stderr))
  end
  for _, expression in ipairs({ "256", "\"three\"", "1.5", "true", "-1" }) do
    local r = run_program(program, expression)
    assert(r.code == 2, expression .. " exited " .. tostring(r.code) .. ": " .. tostring(r.stderr))
    assert(tostring(r.stderr):find("returned no exit status", 1, true) ~= nil, tostring(r.stderr))
  end
end
