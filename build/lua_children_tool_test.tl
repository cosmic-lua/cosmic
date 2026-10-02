--- The core's side of the hold a `lua` module's worker hands what its
--- tests start (core/store.c's `hold_children`), driven by hand: a
--- process started with COSMIC_TEST_CHILD_HOLD in its environment puts
--- it up before any of its Lua runs, or, given one it cannot put up,
--- runs none. It declares `tool` because it starts this program with an
--- environment it chooses, which a `lua` module's children cannot be
--- given; build/lua_children_test.tl holds what a `lua` module starts.

local Child = require("cosmic.child")
local _ = require("cosmic.proc")
local Test = require("cosmic.test")
local test_inputs = require("build.test_inputs")
local this_program = require("build.this_program")
local Time = require("cosmic.time")

Test.needs{ tool = true }

--- Runs `chunk` by `-e` in this program, past its launcher, with
--- COSMIC_TEST_CHILD_HOLD set to `hold`, or unset for nil, and answers
--- whether it exited 0, its exit code, and what it wrote to stdout and
--- stderr.
local function run(hold: string | nil, chunk: string): boolean, integer, string, string
  local env = this_program.environment()
  env["COSMIC_TEST_CHILD_HOLD"] = hold
  local started = this_program.program({ "-e", chunk }, { env = env, stdout = "capture",
    stderr = "capture", timeout_ns = Time.seconds(30) })
  local result = assert(Child.run(started.argv, started.options))
  return result.ok, result.code or -1, result.stdout or "", result.stderr or ""
end

--- A hold as the worker writes it: `module`, the `meta` keys a held
--- worker reads, and the names `cosmic -e` loads and this module has
--- loaded (cosmic.child and cosmic.proc among them), but not cosmic.zip.
local function hold_of(module: string): string
  local names: {string} = {}
  for _, name in ipairs(test_inputs.lua_loads) do names[#names + 1] = name end
  for name in pairs(package.loaded) do
    if name is string then names[#names + 1] = name end
  end
  assert(package.loaded["cosmic.zip"] == nil)
  return module .. " boot_hash,image_hash,main,runtime_basis " .. table.concat(names, " ")
end

--- A hold it cannot parse stops the process before its chunk runs,
--- saying why, rather than running it unheld.
local function test_a_hold_naming_no_module_runs_nothing()
  local ok, code, out, err = run("nomodule", "print('ran')")
  assert(not ok and code == 2, err)
  assert(out == "", out)
  assert(err:find("names no module", 1, true), err)
end

--- A hold given by hand holds the process to the names it lists, naming
--- the module it gives in the refusal, and is handed on to what that
--- process starts, whatever environment it gives it; an empty one holds
--- nothing.
local function test_a_hold_given_by_hand_holds_and_is_handed_on()
  local ok, _, out, err = run(hold_of("hand.module"), "print(require('cosmic.fs') ~= nil)")
  assert(ok and out == "true\n", err)
  ok, _, out, err = run(hold_of("hand.module"), "require('cosmic.zip')")
  assert(not ok and err:find("hand.module declares lua = true", 1, true), err)
  -- Its child, given no hold of its own, is held all the same.
  local chunk = [[
local Child = require('cosmic.child')
local Proc = require('cosmic.proc')
local relaunch = assert(Proc.relaunch())
local argv = { table.unpack(relaunch.argv) }
argv[#argv + 1] = '-e'
argv[#argv + 1] = "require('cosmic.zip')"
local result = assert(Child.run(argv, { env = relaunch.env, fds = relaunch.fds,
  stdout = 'capture', stderr = 'capture' }))
print(tostring(result.ok) .. ' ' .. (result.stderr or ''))
]]
  ok, _, out, err = run(hold_of("hand.module"), chunk)
  assert(ok, err)
  assert(out:find("^false ") and out:find("hand.module declares lua = true", 1, true), out)
  ok, _, out, err = run("", "require('cosmic.zip')")
  assert(ok, err)
end

--- An uncaught error whose message names a held module and a line
--- prints no line of it: the source the core prints beneath such an
--- error (core/main.c's `source_position`) is read past the searcher,
--- and a held process reads no row its key does not hold, the one a
--- message names included. A module opens with its doc comment, so
--- line 1 of cosmic.zip is one it would print.
local function test_an_error_naming_a_held_module_prints_none_of_it()
  local ok, _, _, err = run(hold_of("hand.module"), "error('cosmic.zip:1: boom', 0)")
  assert(not ok and err:find("cosmic.zip:1: boom", 1, true), err)
  assert(not err:find("cosmic: at ", 1, true), err)
end
