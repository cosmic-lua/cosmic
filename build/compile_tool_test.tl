--- `cosmic compile` run as this program: its exit status, the absence of
--- a summary, a `require` between the files named, and its help.
--- The Lua and the refusals themselves are in `compile_test.tl`.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local this_program = require("build.this_program")

--- The program itself, which its tests start.
Test.policy{ profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" } } }

local record Ran
  code: integer
  out: string
  err: string
end

local function cosmic(dir: string, words: {string}): Ran
  local started = this_program.program(words, {
    cwd = dir, stdout = "capture", stderr = "capture",
    timeout_ns = Clock.seconds(30),
  })
  local result = assert(Child.run(started.argv, started.options))
  return { code = result.code, out = result.stdout or "", err = result.stderr or "" }
end

local function test_it_prints_the_lua_and_no_summary(tmp: string)
  assert(Fs.write(tmp .. "/n.tl", "local n: integer = 7\nreturn n\n"))
  local ran = cosmic(tmp, { "compile", "n.tl" })
  assert(ran.code == 0, ran.err)
  assert(ran.out:find("return n", 1, true), ran.out)
  assert(ran.err == "", ran.err)
end

local function test_a_syntax_error_exits_2_naming_file_and_line(tmp: string)
  assert(Fs.write(tmp .. "/bad.tl", "local a = 1\nlocal = 2\n"))
  local ran = cosmic(tmp, { "compile", "bad.tl" })
  assert(ran.code == 2, ran.code)
  assert(ran.out == "" and ran.err:find("bad.tl:2:", 1, true), ran.err)
  assert(not ran.err:find("compile: FAIL", 1, true), ran.err)
end

--- A file named on the command line is the module its path names, so a
--- `require` of another is typed from that file: a wrong use is a type
--- error about its type, not a module that is not found.
local function test_a_require_of_a_named_file_is_typed_from_it(tmp: string)
  assert(Fs.write(tmp .. "/lib.tl", "return { n = 1 }\n"))
  assert(Fs.write(tmp .. "/main.tl", "local lib = require(\"lib\")\nlocal s: string = lib.n\nreturn s\n"))
  local ran = cosmic(tmp, { "compile", "--errors", "-o", "out", "lib.tl", "main.tl" })
  assert(ran.code == 0, ran.err)
  assert(ran.err:find("main.tl:2:", 1, true) and not ran.err:find("not found", 1, true), ran.err)
  assert(Fs.exists(tmp .. "/out/lib.lua") == true and Fs.exists(tmp .. "/out/main.lua") == true)
end

local function test_help_names_the_verb_and_its_options(tmp: string)
  local ran = cosmic(tmp, { "compile", "--help" })
  assert(ran.code == 0, ran.err)
  assert(ran.out:find("cosmic compile", 1, true) and ran.out:find("--errors", 1, true), ran.out)
end

--- A run from another directory with `--root` gives what a run at the root does.
local function test_a_run_from_another_directory_with_root_gives_the_same(tmp: string)
  assert(Fs.write(tmp .. "/lib.tl", "return { n = 1 }\n"))
  assert(Fs.write(tmp .. "/main.tl", "local lib = require(\"lib\")\nlocal s: string = lib.n\nreturn s\n"))
  assert(Fs.mkdirs(tmp .. "/elsewhere"))
  local here = cosmic(tmp, { "compile", "-o", "out", "lib.tl", "main.tl" })
  local there = cosmic(tmp .. "/elsewhere", { "compile", "--root", "..", "-o", "../out2", "../lib.tl", "../main.tl" })
  assert(here.code == 0 and there.code == 0, here.err .. there.err)
  assert(here.err:find("1 type error", 1, true) and there.err:find("1 type error", 1, true), there.err)
  assert(Fs.read(tmp .. "/out/main.lua") == Fs.read(tmp .. "/out2/main.lua"))
  local without = cosmic(tmp .. "/elsewhere", { "compile", "-o", "o3", "../lib.tl" })
  assert(without.code == 2 and without.err:find("pass --root", 1, true), without.err)
end
