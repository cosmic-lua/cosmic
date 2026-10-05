--- `cosmic sandbox --database`, `--modules` and `--closure` run as this
--- program: each runs the program on a sealed database, so what it may
--- `require` is the sealed modules and nothing else of this program, and a
--- database the run seals is removed with it. The command
--- line's own reading is in `sandbox_test.tl`, and the rest of the verb's
--- in `sandbox_tool_test.tl`. They start a sandboxed child, so a host that
--- gives no sandbox skips them where it could have given one (Test.skip),
--- and off Linux they return.
---
--- They seal through [`Store.seal`], and [`Store.closure`] for the closure
--- of a main of the tree's: both read the store's modules, which the grant
--- of o/cosmic.db and the program's own database give.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local Store = require("cosmic.store")
local Test = require("cosmic.test")
local sys = require("cosmic.sys")
local confine = require("build.confine")
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
--- root caller's child runs as must reach the database sealed beneath
--- TMPDIR. Skips the test, where the host refused the sandbox the start
--- asked for.
local function cosmic(dir: string, words: {string}): Ran
  searchable.open(dir)
  local started = this_program.program(words, {
    cwd = dir, stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(120),
  })
  local result = assert(Child.run(started.argv, started.options))
  local ran: Ran = { code = result.code or -1, out = result.stdout or "", err = result.stderr or "" }
  if ran.code == 125 and (ran.err:find("Landlock", 1, true) or ran.err:find("seccomp", 1, true) or
      ran.err:find("not implemented", 1, true) or ran.err:find("only Linux gives", 1, true)) then
    if confine.sandbox_platform() then Test.skip(ran.err) end
  end
  return ran
end

--- What a run left of the directories it seals into, under TMPDIR.
local function left_over(): {string}
  local found: {string} = {}
  for _, name in ipairs((assert(Fs.list((assert(sys.getenv("TMPDIR"))))))) do
    if name:find("^sandbox%-") then found[#found + 1] = name end
  end
  return found
end

--- A script that requires one module of this program and reports what a
--- `require` of another finds.
local SCRIPT <const> = [[
local Json = require("cosmic.json")
print("json", (Json.encode({ a = 1 })))
print("args", arg[0], arg[1], arg[2])
print("outside", (pcall(require, "cosmic.archive")))
return function(args: {integer:string}): integer
  print("main", args[1])
  return 3
end
]]

local function test_closure_runs_a_script_on_the_modules_it_requires(tmp: string)
  if not confine.sandbox_platform() then return end
  assert(Fs.write(tmp .. "/run.tl", SCRIPT))
  searchable.share(tmp .. "/run.tl")
  local program = (assert(Proc.executable()))
  local ran = cosmic(tmp, { "sandbox", "--closure", "--", program, "run.tl", "x", "y" })
  assert(ran.code == 3, ran.code .. ": " .. ran.out .. ran.err)
  assert(ran.out == 'json\t{"a":1}\nargs\trun.tl\tx\ty\noutside\tfalse\nmain\tx\n', ran.out)
  -- No cache or directory was made for it beforehand, and none is left.
  assert(#left_over() == 0, table.concat(left_over(), " "))
  local again = cosmic(tmp, { "sandbox", "--closure", "--", program, "run.tl" })
  assert(again.code == 3 and again.out:find("main\tnil", 1, true), again.out .. again.err)
end

--- The core's own modules ([`cosmic.sys`]) are no database's, and a require
--- only of a type is not carried.
local function test_closure_takes_the_cores_modules_and_leaves_type_requires_out(tmp: string)
  if not confine.sandbox_platform() then return end
  assert(Fs.write(tmp .. "/sys.tl", [[
local sys = require("cosmic.sys")
local type Archive = require("cosmic.archive")
local Fs = require("cosmic.fs")
local _: Archive = nil
print("sys", type(sys.getpid), type(Fs.read), (pcall(require, "cosmic." .. "archive")))
]]))
  searchable.share(tmp .. "/sys.tl")
  local ran = cosmic(tmp, { "sandbox", "--closure", "--", (assert(Proc.executable())), "sys.tl" })
  assert(ran.code == 0 and ran.out == "sys\tfunction\tfunction\tfalse\n", ran.code .. ran.out .. ran.err)
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

--- A database that [`Store.seal`] wrote runs as it names, with no command
--- (this program) or with it, and a relative path is the one `--cwd` names.
local function test_database_runs_a_sealed_file(tmp: string)
  if not confine.sandbox_platform() then return end
  local chunk = assert(load("return function(args) print('db', args[1], pcall(require, 'cosmic.fs')) " ..
      "return 4 end", "=main"))
  assert(Store.seal({}, tmp .. "/p.db", { extra = { name = "main", bytecode = string.dump(chunk),
    source = "", requires = {} } }))
  searchable.share(tmp .. "/p.db")
  local program = (assert(Proc.executable()))
  local ran = cosmic(tmp, { "sandbox", "--database", "p.db", "--", program, "a" })
  assert(ran.code == 4 and ran.out:find("^db\ta\tfalse"), ran.code .. ran.out .. ran.err)
  local bare = cosmic(tmp, { "sandbox", "--database=" .. tmp .. "/p.db" })
  assert(bare.code == 4 and bare.out:find("^db\tnil\tfalse"), bare.code .. bare.out .. bare.err)
  assert(#left_over() == 0, "--database seals nothing")
  -- Only this program runs on a database.
  local other = cosmic(tmp, { "sandbox", "--system", "--database", "p.db", "--", "true" })
  assert(other.code == 125 and other.err:find("is not this program", 1, true), other.code .. other.err)
  -- A path no one can search is refused, naming it.
  assert(Fs.mkdirs(tmp .. "/shut"))
  assert(Fs.write(tmp .. "/shut/p.db", (assert(Fs.read(tmp .. "/p.db")))))
  assert(sys.chmod(tmp .. "/shut", 0))
  local shut = cosmic(tmp, { "sandbox", "--database", tmp .. "/shut/p.db" })
  assert(sys.chmod(tmp .. "/shut", 448))
  assert(shut.code == 2 and shut.err:find("shut", 1, true), shut.code .. shut.err)
end

--- `--modules` seals exactly the modules it names, the first the main:
--- without the modules the main requires it cannot load, and with them it runs.
local function test_modules_seals_exactly_the_named_modules(tmp: string)
  if not confine.sandbox_platform() then return end
  local program = (assert(Proc.executable()))
  local main = "build.stand_in_probe"
  local alone = cosmic(tmp, { "sandbox", "--modules", main, "--", program, "exit 3" })
  assert(alone.code ~= 0 and alone.code < 125 and alone.err:find("cosmic.child", 1, true),
    alone.code .. alone.err)
  local names: {string} = { main }
  for _, name in ipairs(Store.closure({ main })) do
    if name ~= main then names[#names + 1] = name end
  end
  local whole = cosmic(tmp, { "sandbox", "--modules", table.concat(names, ","), "--", program,
    "exit 3" })
  assert(whole.code == 3, whole.code .. ": " .. whole.out .. whole.err)
  assert(#left_over() == 0, "the sealed database goes with the run")
  -- The core's own module needs no database; as the main it has none to run.
  local core = cosmic(tmp, { "sandbox", "--modules", "cosmic.fs,cosmic.env,cosmic.sys", "--", program })
  assert(core.code ~= 125 and core.err:find("not a function", 1, true), core.code .. core.err)
  local own = cosmic(tmp, { "sandbox", "--modules", "cosmic.sys,cosmic.fs,cosmic.env", "--", program })
  assert(own.code == 2 and own.err:find("cosmic.sys", 1, true), own.code .. own.err)
  local missing = cosmic(tmp, { "sandbox", "--modules", "nowhere.module", "--", program })
  assert(missing.code == 2 and missing.err:find("nowhere.module", 1, true), missing.code .. missing.err)
end
