--- End to end: unsandboxed, a test stands on what it declares, as a
--- sandboxed one does, whatever it reads beyond it: none is assumed,
--- one that reads outside the tree or starts a process as much as any.
--- Nothing holds it to its declaration there, so what it reads that it
--- does not declare moves nothing; a Linux leg's sandbox, which refuses
--- it such a read, is what fails it.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local this_program = require("build.this_program")
local Test = require("cosmic.test")

--- The program itself, which its tests start.
Test.needs{ tool = true }

--- Runs `cosmic test` on `root` with `words` after it -- `suite`, which
--- names every test there, unless others are given.
local function run(root: string, output: string, env: {string:string}, fails?: boolean,
                   words?: {string}): string
  local fd = assert(Fs.open_write(output))
  local args: {string} = { "test" }
  for _, word in ipairs(words or { "suite" }) do args[#args + 1] = word end
  local started = this_program.program(args, {
    cwd = root, env = env, stdout = fd, stderr = fd,
    process_group = true, timeout_ms = 60000,
  })
  local result, trouble = Child.run(started.argv, started.options)
  assert(Fs.close(fd))
  local text = assert(Fs.read(output))
  assert(result ~= nil and result.ok == not fails, tostring(trouble) .. text)
  return text
end

--- A test that reads outside its tree is keyed by what it declares of
--- it -- a host file by its contents, a variable by its value -- and
--- stands until one of those changes; `--all` and COSMIC_TEST_ALL=1 run
--- it whatever stands, while naming it runs nothing more.
--- COSMIC_SANDBOX=must, which every key holds, keys it apart. A read it does not
--- declare is trusted, not keyed: a file it reads undeclared changes,
--- and it stands.
local function test_an_unsandboxed_test_stands_on_what_it_declares(tmp: string)
  local root = tmp .. "/project"
  assert(Fs.mkdirs(root .. "/suite"))
  assert(Fs.mkdirs(tmp .. "/outside"))
  assert(Fs.write(tmp .. "/outside/f", "out\n"))
  assert(Fs.write(tmp .. "/outside/undeclared", "one\n"))
  local source = [[
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")

Test.needs { host = { "$OUTSIDE/f" }, env = { "FLAVOUR" } }

local function test_reads_outside()
  local outside = assert(Env.get("OUTSIDE"))
  assert(Fs.read(outside .. "/f") == "out\n")
  assert(Fs.read(outside .. "/undeclared") ~= nil)
  assert(Env.get("FLAVOUR") ~= "sour")
end

local function test_plain()
  assert(1 + 1 == 2)
end
]]
  assert(Fs.write(root .. "/suite/outside_test.tl", source))
  local env = this_program.environment()
  env.COSMIC_TEST_SANDBOX = "0"
  env.OUTSIDE = tmp .. "/outside"
  env.COSMIC_TEST_ALL = nil
  env.COSMIC_SANDBOX = nil
  env.FLAVOUR = "sweet"
  local function said(name: string, words: {string}, wanted: string, fails?: boolean)
    local text = run(root, tmp .. "/" .. name .. ".out", env, fails, words)
    assert(text:find(wanted, 1, true), name .. ": " .. text)
    assert(not text:find("assumed", 1, true), name .. ": " .. text)
  end
  said("first", {}, "2 ran, 0 stood")
  said("second", {}, "0 ran, 2 stood")
  said("all", { "--all" }, "2 ran, 0 stood")
  said("named", { "suite/outside_test.tl:test_reads_outside" }, "0 ran, 1 stood")
  env.COSMIC_TEST_ALL = "1"
  said("variable", {}, "2 ran, 0 stood")
  env.COSMIC_TEST_ALL = nil
  env.COSMIC_SANDBOX = "must"
  said("must", {}, "2 ran, 0 stood")
  env.COSMIC_SANDBOX = nil
  said("unheld", {}, "0 ran, 2 stood")
  -- Undeclared, a read is trusted: its change moves no key.
  assert(Fs.write(tmp .. "/outside/undeclared", "two\n"))
  said("undeclared", {}, "0 ran, 2 stood")
  -- Declared, a host file is keyed by its contents, and a variable by
  -- its value.
  assert(Fs.write(tmp .. "/outside/f", "changed\n"))
  said("host", {}, "1 of 2 failed", true)
  assert(Fs.write(tmp .. "/outside/f", "out\n"))
  said("restored", {}, "0 ran, 2 stood")
  env.FLAVOUR = "sour"
  said("sour", {}, "1 of 2 failed", true)
  said("failed", {}, "1 of 2 failed", true)
  env.FLAVOUR = "sweet"
  said("sweet", {}, "0 ran, 2 stood")
end
