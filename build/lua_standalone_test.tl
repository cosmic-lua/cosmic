--- What a module that declares `standalone` beside `lua`
--- ([`cosmic.test`]) starts: this program running a file `--standalone`,
--- held to the module's import closure, what `cosmic -e` loads and what
--- `cosmic --standalone` loads beyond it (build/test_inputs.tl's
--- `lua_loads` and `standalone_loads`) -- so a file that reaches for any
--- other module of the program fails rather than running what no key of
--- its test holds. build/lua_children_test.tl holds what one that
--- declares `lua` alone starts.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local closure_store = require("build.closure_store")
local test_inputs = require("build.test_inputs")
local this_program = require("build.this_program")
local Clock = require("cosmic.clock")

-- TODO: declare this with [`Test.policy`] once a policy field says `lua` (the TODO
-- above [`Test.needs_of`] in cosmic/test.tl).
Test.needs{ lua = true, standalone = true }

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
--- requires a module outside the closure is refused: the checker, which
--- types it from rows the hold does not let through, finds no such module.
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
  ok, out, err = run({ "--standalone", bad })
  assert(not ok and err:find("module not found: 'cosmic.zip'", 1, true), out .. err)
end

--- A file runs standalone having loaded nothing of the tree beyond
--- `lua_loads`, `standalone_loads` and what the test module's closure
--- holds: every one of them a held child may load. One added to that
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

--- What a closure store carries beside a module is what a held process
--- may load beside it.
local function test_what_a_store_carries_beside_a_module_a_child_may_load()
  local function flat(by: {string:{string}}): string
    local lines: {string} = {}
    for name, besides in pairs(by) do
      lines[#lines + 1] = name .. "=" .. table.concat(besides, ",")
    end
    table.sort(lines)
    return table.concat(lines, " ")
  end
  assert(flat(closure_store.loaded_beside) == flat(test_inputs.loaded_beside),
    flat(closure_store.loaded_beside))
end
