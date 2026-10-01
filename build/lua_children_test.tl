--- What a module that declares `lua` ([`cosmic.test`]) alone starts:
--- this program running a chunk, held to the module's import closure
--- and what `cosmic -e` loads (build/test_inputs.tl's `lua_loads`),
--- whatever environment it is given, and each process it starts in turn
--- -- so a child that reaches for any other module of the program, runs
--- a verb, or runs a file `--standalone`, fails, naming `lua`, rather
--- than running what no key of its test holds. build/lua_standalone_test.tl
--- holds what one that declares `standalone` beside it starts.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Store = require("cosmic.store")
local Test = require("cosmic.test")
local test_inputs = require("build.test_inputs")
local this_program = require("build.this_program")

Test.needs{ lua = true }

--- Runs `words` after this program, past its launcher, and answers
--- whether it exited 0, and what it wrote to stdout and stderr.
local function run(words: {string}): boolean, string, string
  local started = this_program.program(words, { stdout = "capture", stderr = "capture",
    timeout_ms = 30000 })
  local result = assert(Child.run(started.argv, started.options))
  return result.ok, result.stdout or "", result.stderr or ""
end

--- What refuses a module to a held process, as core/store.c's
--- `put_up_inherited` says it.
local REFUSED <const> = "build.lua_children_test declares lua = true"

--- A chunk runs, and loads nothing of the tree beyond `lua_loads` and
--- what it requires itself: the lean way dispatch takes to `-e`
--- (build/dispatch_tool_test.tl holds its count), every one of which
--- a held child may load. One added to that way fails here first.
local function test_a_chunk_runs_on_what_e_loads()
  local ok, out, err = run({ "-e", "local t = {} for name in pairs(package.loaded) do " ..
    "t[#t + 1] = name end table.sort(t) print(table.concat(t, ' '))" })
  assert(ok, err)
  local allowed: {string:boolean} = { ["cosmic.sys"] = true }
  for _, name in ipairs(test_inputs.lua_loads) do allowed[name] = true end
  for name in out:gmatch("%S+") do
    if name:find("^build%.") or name:find("^cosmic%.") or name:find("^cmd%.") then
      assert(allowed[name], name .. " is loaded by -e but not in lua_loads: " .. out)
    end
  end
end

--- A module of the test's closure loads; one outside it is refused,
--- naming `lua`, where a `tool` test's child would load it.
local function test_a_module_outside_the_closure_is_refused()
  local ok, _, err = run({ "-e", "require('cosmic.child') require('build.this_program')" })
  assert(ok, err)
  ok, _, err = run({ "-e", "require('cosmic.zip')" })
  assert(not ok and err:find(REFUSED, 1, true), err)
end

--- A verb runs no module the key does not hold: it fails, naming `lua`.
local function test_a_verb_is_refused()
  local ok, _, err = run({ "test", "--help" })
  assert(not ok and err:find(REFUSED, 1, true), err)
  ok, _, err = run({ "help" })
  assert(not ok and err:find(REFUSED, 1, true), err)
end

--- The hold reaches what a child starts in turn, given an environment
--- of its own that names none, or another: it is the core's to hand on,
--- not the environment's.
local function test_the_hold_reaches_a_grandchild_whatever_its_environment()
  local chunk = [[
local Child = require('cosmic.child')
local Proc = require('cosmic.proc')
local relaunch = assert(Proc.relaunch())
local failed = 0
for _, extra in ipairs({ {}, { COSMIC_TEST_CHILD_HOLD = '' },
                         { COSMIC_TEST_CHILD_HOLD = 'x , cosmic.zip' } }) do
  local env = {}
  for name, value in pairs(relaunch.env) do env[name] = value end
  for name, value in pairs(extra) do env[name] = value end
  local argv = { table.unpack(relaunch.argv) }
  argv[#argv + 1] = '-e'
  argv[#argv + 1] = "require('cosmic.zip')"
  local result = assert(Child.run(argv, { env = env, fds = relaunch.fds,
    stdout = 'capture', stderr = 'capture' }))
  if not result.ok and (result.stderr or ''):find('declares lua = true', 1, true) then
    failed = failed + 1
  else
    print(result.stderr)
  end
end
return failed == 3 and 0 or 1
]]
  local ok, out, err = run({ "-e", chunk })
  assert(ok, out .. err)
end

--- A file run `--standalone` is refused, naming `standalone`: the
--- checker it loads is none of `lua_loads`, so a module that declares
--- `lua` alone is keyed without it, and its child may not load it.
local function test_a_standalone_file_is_refused_without_standalone(tmp: string)
  local file = tmp .. "/file.tl"
  assert(Fs.write(file, "print('ran')\n"))
  local ok, out, err = run({ "--standalone", file })
  assert(not ok and out == "", out .. err)
  assert(err:find(REFUSED, 1, true) and err:find("declare standalone = true beside lua", 1,
    true), err)
end

--- The compiler's identity is refused to a child whose module's closure
--- holds no reader of it beyond what `lua` adds (build.test_inputs'
--- `compiler_sought`), as its key leaves it out: build.dispatch, which
--- reads it, is among `lua_loads` here, so a read the key does not hold
--- fails rather than being answered, here as in the child. A row every
--- key holds still reads.
local function test_the_compilers_identity_is_refused_to_a_child()
  local read, why = pcall(Store.meta, "compiler")
  assert(not read and tostring(why):find("Store.meta of \"compiler\" is held", 1, true),
    tostring(why))
  for _, row in ipairs({ "compiler", "compiled_by" }) do
    local ok, out, err = run({ "-e", "print(require('cosmic.store').meta('" .. row .. "'))" })
    assert(not ok and out == "" and err:find(REFUSED, 1, true) and
      err:find("does not hold that row", 1, true), row .. ": " .. out .. err)
  end
  local ok, out, err = run({ "-e", "print(require('cosmic.store').meta('main'))" })
  assert(ok and out == "cmd.cosmic.main\n", out .. err)
end
