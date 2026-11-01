--- What a module that declares `lua` ([`cosmic.test`]) alone starts:
--- this program running a chunk, which a sandboxed worker runs from an
--- sealed database of the module's import closure and what `cosmic -e`
--- loads (build/test_inputs.tl's `lua_loads`) in the program's place
--- (build/test_key.tl's `sealed_for`), and each process it starts in turn
--- inherits that -- so a child that reaches for any other module of the
--- program, runs a verb, or runs a file `--standalone`, finds none rather
--- than running what no key of its test holds. build/lua_standalone_test.tl
--- holds what one that requires build.standalone starts. An unsandboxed
--- run, which has no artifact to give, holds a child to nothing: what
--- narrows the program is asserted only in a sandboxed worker, and skipped
--- (`sandboxed`) where a Linux run gave none.

local Child = require("cosmic.child")
local Env = require("cosmic.env")
local Test = require("cosmic.test")
local stand_in = require("build.stand_in")
local test_child = require("build.test_child")
local test_inputs = require("build.test_inputs")
local _ = require("build.standalone") -- the checker `-e` types its chunk with: loaded here, as a child's is
local confine = require("build.confine")
local this_program = require("build.this_program")
local Clock = require("cosmic.clock")

Test.policy{ profiles = { "cosmic" } }

--- Runs `words` after this program, past its launcher, and answers
--- whether it exited 0, and what it wrote to stdout and stderr.
local function run(words: {string}): boolean, string, string
  local started = this_program.program(words, { stdout = "capture", stderr = "capture",
    timeout_ns = Clock.seconds(30) })
  local result = assert(Child.run(started.argv, started.options))
  return result.ok, result.stdout or "", result.stderr or ""
end

--- Ends the running test as skipped ([`Test.skip`]) where this worker is
--- not sandboxed, which is what narrows what its children run: the runner
--- marks every worker it holds with the module's name in the variable
--- build.confine's `held_variable` names (set for a `lua` module's worker
--- too). On Linux a worker without the mark was given no sandbox; off
--- Linux there is none to give.
local function skip_unless_sandboxed()
  if Env.get(confine.held_variable) ~= nil then return end
  Test.skip("this worker is not sandboxed, so no sealed database of its closure narrows what " ..
      "its children run")
end

--- The child of the test below: the names of the modules loaded when `-e` runs a chunk. A chunk of a project cannot
--- read `package`, so it is registered here, as part of the tree.
test_child.register("loaded", function(_args: {string}): integer
  local names: mut {string} = {}
  for name in pairs(package.loaded) do names[#names + 1] = tostring(name) end
  table.sort(names, function(a: string, b: string): boolean return a < b end)
  print(table.concat(names, " "))
  return 0
end)

--- A chunk runs, and loads nothing of the tree beyond `lua_loads`, `standalone_loads` and what the test module's
--- closure holds, which holds the checker `-e` types the chunk with ([`build.test_inputs`]'s closure for a module that
--- declares `lua`): every one of them a child's artifact carries. One added to that way fails here first.
local function test_a_chunk_runs_on_what_e_loads(tmp: string)
  local ok, out, err = run(test_child.words(tmp, "build.lua_children_test", "loaded"))
  assert(ok, err)
  local allowed: mut {string:boolean} = { ["cosmic.sys"] = true }
  for _, list in ipairs({ test_inputs.lua_loads, test_inputs.standalone_loads }) do
    for _, name in ipairs(list) do allowed[name] = true end
  end
  for name in pairs(package.loaded) do
    if name is string then allowed[name] = true end
  end
  for name in out:gmatch("%S+") do
    if name:find("^build%.") or name:find("^cosmic%.") or name:find("^cmd%.") then
      assert(allowed[name], name .. " is loaded by -e but not in lua_loads: " .. out)
    end
  end
end

--- A module of the test's closure loads; one outside it is not found in the artifact a child runs, where a `tool`
--- test's child would load it: the checker refuses the chunk that requires it, naming the module.
local function test_a_module_outside_the_closure_is_not_found()
  local ok, _, err = run({ "-e", "local Child = require('cosmic.child') local This = require('build.this_program') " ..
      "print(type(Child), type(This))" })
  assert(ok, err)
  skip_unless_sandboxed()
  ok, _, err = run({ "-e", "local Zip = require('cosmic.zip') print(Zip)" })
  assert(not ok and err:find("no module `cosmic.zip`", 1, true), err)
end

--- A verb runs no module the key does not hold: it fails to find them.
local function test_a_verb_is_not_found()
  skip_unless_sandboxed()
  local ok, _, err = run({ "test", "--help" })
  assert(not ok and err:find("no module", 1, true), err)
  ok, _, err = run({ "help" })
  assert(not ok and err:find("no module", 1, true), err)
end

--- What a child starts in turn runs the same artifact, given an
--- environment of its own or not.
local function test_a_grandchild_runs_the_same_artifact()
  skip_unless_sandboxed()
  local chunk = [[
local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local relaunch = assert(Proc.relaunch())
local argv: mut {string} = {}
for _, word in ipairs(relaunch.argv) do argv[#argv + 1] = word end
argv[#argv + 1] = "-e"
argv[#argv + 1] = "local Zip = require('cosmic.zip') print(Zip)"
local result = assert(Child.run(argv, { env = relaunch.env, fds = relaunch.fds,
  stdout = "capture", stderr = "capture" }))
Fs.put(Fs.stdout, tostring(result.ok) .. " " .. (result.stderr or ""))
]]
  local ok, out, err = run({ "-e", chunk })
  assert(ok, out .. err)
  assert(out:find("^false ") and out:find("no module `cosmic.zip`", 1, true), out)
end

--- The compiler's identity is no row of the artifact a child runs, as its
--- key leaves it out where the closure holds no reader of it beyond what
--- `lua` adds (build.test_inputs' `compiler_sought`); a row every key
--- holds still reads.
local function test_the_compilers_identity_is_not_in_what_a_child_runs()
  skip_unless_sandboxed()
  for _, row in ipairs({ "compiler", "compiled_by" }) do
    local ok, out, err = run({ "-e", "print(require('cosmic.store').meta('" .. row .. "'))" })
    assert(ok and out == "nil\n", row .. ": " .. out .. err)
  end
  local ok, out, err = run({ "-e", "print(require('cosmic.store').meta('main'))" })
  assert(ok and out == "cmd.cosmic.main\n", out .. err)
end

--- A stand-in (build/stand_in.tl), built of the closure, runs its main
--- module, which it carries under a name of its own: started by the test,
--- and by a child of it in turn.
local function test_a_stand_in_runs(tmp: string)
  local probe = assert(stand_in.build(tmp .. "/stand-in"))
  local direct = assert(Child.run({ probe, "print ran" }, { stdout = "capture",
    stderr = "capture", timeout_ns = Clock.seconds(30) }))
  assert(direct.ok and direct.stdout == "ran\n", tostring(direct.stdout) ..
      tostring(direct.stderr))
  local ok, out, err = run({ "-e", 'local Child = require("cosmic.child") local Fs = require("cosmic.fs") ' ..
      'local program = ... if program == nil then return 2 end ' ..
      'local r = assert(Child.run({ program, "print ran" }, { stdout = "capture", stderr = "capture" })) ' ..
      'Fs.put(Fs.stdout, (r.stdout or "") .. (r.stderr or "")) local status = 1 if r.ok then status = 0 end return status', probe })
  assert(ok and out == "ran\n", out .. err)
end
