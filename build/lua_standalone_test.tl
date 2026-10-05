--- What a module that declares `lua` ([`cosmic.test`]) and requires
--- [`build.standalone`] starts: this program running a file `--standalone`,
--- from an artifact of the module's import closure
--- ([`build.closure_artifact`]), which carries what `cosmic -e` loads and
--- what `cosmic --standalone` loads beyond it (build/test_inputs.tl's
--- `lua_loads` and `standalone_loads`) -- so a file that reaches for any
--- other module of the program fails rather than running what no key of
--- its test holds. build/lua_children_test.tl holds what one that
--- declares `lua` alone starts, and how a worker is known to be sandboxed,
--- where only the artifact narrows what a child reads.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local _ = require("build.standalone")
local Store = require("cosmic.store")
local closure_store = require("build.closure_store")
local test_inputs = require("build.test_inputs")
local this_program = require("build.this_program")
local Clock = require("cosmic.clock")

Test.policy{ profiles = { "cosmic" } }

--- Whether this worker is sandboxed, which shows it the tree at /tree.
local function sandboxed(): boolean
  local there, _ = Fs.exists("/tree/o/cosmic.db")
  return there == true
end

--- Runs `words` after this program, past its launcher, and answers
--- whether it exited 0, and what it wrote to stdout and stderr.
local function run(words: {string}): boolean, string, string
  local started = this_program.program(words, { stdout = "capture", stderr = "capture",
    timeout_ns = Clock.seconds(30) })
  local result = assert(Child.run(started.argv, started.options))
  return result.ok, result.stdout or "", result.stderr or ""
end

--- A Teal file runs standalone, checked by the compiler, which build.teal
--- loads beside it (`loaded_beside`): typed against a module of the
--- standard library the test module requires, and running it. One that
--- requires a module outside the closure is refused, where the worker is
--- sandboxed: the checker, which types it from the rows the artifact carries,
--- finds no such module.
local function test_a_standalone_file_runs_on_what_it_loads(tmp: string)
  local good = tmp .. "/good.tl"
  assert(Fs.write(good, "local Child = require(\"cosmic.child\")\n" ..
      "local ok = type(Child.run) == \"function\"\n" ..
      "return function(argv: {integer:string}): integer\n" ..
      "  print(ok, argv[1])\n  return 0\nend\n"))
  local ok, out, err = run({ "--standalone", good, "word" })
  assert(ok and out == "true\tword\n", out .. err)
  local bad = tmp .. "/bad.tl"
  assert(Fs.write(bad, "local Zip = require(\"cosmic.zip\")\nprint(Zip ~= nil)\n"))
  if not sandboxed() then return end
  ok, out, err = run({ "--standalone", bad })
  assert(not ok and err:find("module not found: 'cosmic.zip'", 1, true), out .. err)
end

--- A file runs standalone having loaded nothing of the tree beyond
--- `lua_loads`, `standalone_loads` and what the test module's closure
--- holds: every one of them its artifact carries. One added to that
--- way fails here first.
local function test_a_standalone_file_runs_on_what_standalone_loads(tmp: string)
  local file = tmp .. "/loaded.tl"
  assert(Fs.write(file, "local t: {string} = {}\n" ..
      "for name in pairs(package.loaded) do t[#t + 1] = tostring(name) end\n" ..
      "table.sort(t)\nprint(table.concat(t, ' '))\n"))
  local ok, out, err = run({ "--standalone", file })
  assert(ok, err)
  local allowed: {string:boolean} = { ["cosmic.sys"] = true }
  for _, name in ipairs(test_inputs.lua_loads) do allowed[name] = true end
  for _, name in ipairs(test_inputs.standalone_loads) do allowed[name] = true end
  for name in pairs(package.loaded) do
    if name is string then allowed[name] = true end
  end
  local seen = 0
  for name in out:gmatch("%S+") do
    if name:find("^build%.") or name:find("^cosmic%.") or name:find("^cmd%.") then
      seen = seen + 1
      assert(allowed[name], name .. " is loaded by --standalone but not in " ..
          "standalone_loads: " .. out)
    end
  end
  assert(seen > 0, out)
end

--- Every name in `standalone_loads` is loaded in this worker, which loads
--- its harness and this module's closure. It is a smoke check only: the
--- harness already loads some of them, so it cannot show that
--- build.standalone's own requires reach each one. That is held by
--- [`test_a_standalone_file_runs_on_what_standalone_loads`], whose child may
--- load only the closure, `lua_loads` and `standalone_loads`.
local function test_standalone_loads_are_loaded_in_this_worker()
  for _, name in ipairs(test_inputs.standalone_loads) do
    assert(package.loaded[name] ~= nil, name .. " is in standalone_loads but " ..
        "build.standalone's closure does not hold it")
  end
end

--- What a closure store carries beside a module is what a child's
--- artifact carries of it: the compiler build.teal loads as bytecode.
local function test_what_a_store_carries_beside_a_module_is_found_by_this_worker()
  for name, besides in pairs(closure_store.loaded_beside) do
    assert(package.loaded[name] ~= nil, name .. " is in no closure of this module")
    for _, beside in ipairs(besides) do
      assert(Store.bytecode(beside) ~= nil, beside .. " is not carried beside " .. name)
    end
  end
end
