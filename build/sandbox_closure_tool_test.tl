--- `cosmic sandbox --closure` refuses a script that does not compile, is
--- not there or requires a module outside the store before any child
--- starts, so these cases need no sandbox and run wherever the program
--- does; the runs that start one are in `sandbox_seal_tool_test.tl`.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local Test = require("cosmic.test")
local sys = require("cosmic.sys")
local searchable = require("build.searchable")
local this_program = require("build.this_program")

Test.policy{
  profiles = { "cosmic" },
  grants = { { path = "o/bin", letters = "rx" }, { path = "o/cosmic.db", letters = "r" } },
}

local record Ran
  code: integer
  out: string
  err: string
end

--- Runs `cosmic <words>` in `dir`, which is made searchable, as the user a
--- root caller's child runs as must reach it.
local function cosmic(dir: string, words: {string}): Ran
  searchable.open(dir)
  local started = this_program.program(words, {
    cwd = dir, stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(120),
  })
  local result = assert(Child.run(started.argv, started.options))
  return { code = result.code or -1, out = result.stdout or "", err = result.stderr or "" }
end

--- What a run left of the directories it seals into, under TMPDIR.
local function left_over(): {string}
  local found: {string} = {}
  for _, name in ipairs((assert(Fs.list((assert(sys.getenv("TMPDIR"))))))) do
    if name:find("^sandbox%-") then found[#found + 1] = name end
  end
  return found
end

local function test_closure_refuses_a_script_that_does_not_compile_or_is_not_there(tmp: string)
  assert(Fs.write(tmp .. "/bad.tl", 'local x: integer = "no"\n'))
  assert(Fs.write(tmp .. "/mine.tl", 'local Mine = require("mine_module")\nprint(Mine)\n'))
  local program = (assert(Proc.executable()))
  local bad = cosmic(tmp, { "sandbox", "--closure", "--", program, "bad.tl" })
  assert(bad.code == 125 and bad.out == "" and bad.err:find("^cosmic: sandbox: bad.tl:1"), bad.code .. bad.err)
  local gone = cosmic(tmp, { "sandbox", "--closure", "--", program, "absent.tl" })
  assert(gone.code == 125 and gone.err:find("absent.tl", 1, true), gone.code .. gone.err)
  -- A module outside the store is refused before the child starts.
  local mine = cosmic(tmp, { "sandbox", "--closure", "--", program, "mine.tl" })
  assert(mine.code == 125 and mine.out == "" and mine.err:find("mine_module", 1, true), mine.code .. mine.err)
  assert(#left_over() == 0, "a refused script leaves nothing")
end
