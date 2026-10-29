--- What a module that declares `lua` ([`cosmic.test`]) and requires
--- [`build.standalone`] starts: this program running a file `--standalone`,
--- on a sealed database of the module's import closure
--- ([`build.test_key`]'s `sealed_for`), which carries what `cosmic -e` loads and
--- what `cosmic --standalone` loads beyond it (build/test_inputs.tl's
--- `lua_loads` and `standalone_loads`) -- so a file that reaches for any
--- other module of the program fails rather than running what no key of
--- its test holds. build/lua_children_test.tl holds what one that
--- declares `lua` alone starts, and how a worker is known to be sandboxed,
--- where only the sealed database narrows what a child reads.

local Child = require("cosmic.child")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local sys = require("cosmic.sys")
local Test = require("cosmic.test")
local _ = require("build.standalone")
local test_inputs = require("build.test_inputs")
local confine = require("build.confine")
local this_program = require("build.this_program")
local Clock = require("cosmic.clock")

Test.policy{ profiles = { "cosmic" } }

--- Whether this worker is sandboxed, which is what narrows what its children
--- run: the runner marks every worker it holds with the module's name in
--- the variable build.confine's `held_variable` names (set for a `lua`
--- module's worker too). On Linux a worker without the mark was given no
--- sandbox, so the test is skipped, saying so; off Linux there is none to
--- give, and it returns unchecked.
local function sandboxed(): boolean
  if Env.get(confine.held_variable) ~= nil then return true end
  if assert(sys.uname()).sysname == "Linux" then
    Test.skip("this worker is not sandboxed, so no sealed database of its closure narrows what " ..
        "its children run")
  end
  return false
end

--- Runs `words` after this program, past its launcher, and answers
--- whether it exited 0, and what it wrote to stdout and stderr.
local function run(words: {string}): boolean, string, string
  local started = this_program.program(words, { stdout = "capture", stderr = "capture",
    timeout_ns = Clock.seconds(30) })
  local result = assert(Child.run(started.argv, started.options))
  return result.ok, result.stdout or "", result.stderr or ""
end

--- A Teal file runs standalone, checked by the new checker: typed against a module of the
--- standard library the test module requires, and running it. One that
--- requires a module outside the closure is refused, where the worker is
--- sandboxed: the checker, which types it from the rows the artifact carries,
--- finds no such module.
local function test_a_standalone_file_runs_on_what_it_loads(tmp: string)
  local good = tmp .. "/good.tl"
  assert(Fs.write(good, "local Child = require(\"cosmic.child\")\n" ..
      "local ok = type(Child.run) == \"function\"\n" ..
      "return function(argv: {string}): integer\n" ..
      "  print(ok, argv[1])\n  return 0\nend\n"))
  local ok, out, err = run({ "--standalone", good, "word" })
  assert(ok and out == "true\tword\n", out .. err)
  local bad = tmp .. "/bad.tl"
  assert(Fs.write(bad, "local Zip = require(\"cosmic.zip\")\nprint(Zip ~= nil)\n"))
  if not sandboxed() then return end
  ok, out, err = run({ "--standalone", bad })
  assert(not ok and err:find("the project has no module `cosmic.zip`", 1, true) ~= nil, out .. err)
end

--- Every name in `standalone_loads` is loaded in this worker, which loads
--- its harness and this module's closure. It is a smoke check only: the
--- harness already loads some of them, so it cannot show that
--- build.standalone's own requires reach each one. That is held by
--- [`test_a_standalone_file_runs_on_what_it_loads`], in a sandboxed worker, whose child can load only the sealed
--- database: the closure, `lua_loads` and `standalone_loads`. (A file cannot list what it loaded: it may not read
--- `package`.)
local function test_standalone_loads_are_loaded_in_this_worker()
  for _, name in ipairs(test_inputs.standalone_loads) do
    assert(package.loaded[name] ~= nil, name .. " is in standalone_loads but " ..
        "build.standalone's closure does not hold it")
  end
end
