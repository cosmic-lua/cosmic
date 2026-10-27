--- What `-e` loads and runs: the child most tests start is this program running a chunk, so every module
--- [`build.dispatch`] requires ahead of it is paid by each of them, and a chunk is checked Teal, refused as a file is.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Test = require("cosmic.test")
local test_child = require("build.test_child")
local this_program = require("build.this_program")

--- The program itself, started with `-e`.
Test.policy{ profiles = { "cosmic" } }

--- The child of the test below: the names of the modules loaded when `-e` runs a chunk (the test module's own are among them).
test_child.register("loaded", function(_args: {string}): integer
  local names: mut {string} = {}
  for name in pairs(package.loaded) do names[#names + 1] = tostring(name) end
  table.sort(names, function(a: string, b: string): boolean return a < b end)
  print(table.concat(names, " "))
  return 0
end)

--- The modules of the verbs ([`build.verb_list`]) and what only they read: `-e` loads the checker it
--- checks its chunk with, and none of these.
local verbs <const>: {string} = {
  "build.test", "build.fix", "build.embed", "build.databases", "build.lsp", "build.migrate", "build.sql",
  "build.cache", "build.json", "build.hash", "build.codec", "build.archive", "build.fetch", "build.time",
  "build.rand", "build.compile", "build.docs", "build.todos", "build.bom", "build.refresh", "build.release",
  "build.sandbox", "build.verb_list", "cosmic.cli", "cosmic.flags",
}

--- `-e` loads no verb and no help: it loads the checker and what the logger reads, and the module that
--- answers a chunk. A module required at dispatch's top level for a verb's sake is loaded by every child a
--- test starts, and fails this.
local function test_e_loads_none_of_the_verbs(tmp: string)
  local started = this_program.program(test_child.words(tmp, "build.dispatch_tool_test", "loaded"),
    { env = {}, cwd = tmp, stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(30) })
  local r = assert(Child.run(started.argv, started.options))
  assert(r.ok, tostring(r.stdout) .. tostring(r.stderr))
  local loaded = " " .. (r.stdout or "") .. " "
  for _, name in ipairs({ "build.dispatch", "build.exit_status", "build.standalone" }) do
    assert(loaded:find(" " .. name .. " ", 1, true), name .. " is not among " .. loaded)
  end
  for _, name in ipairs(verbs) do
    assert(not loaded:find(" " .. name .. " ", 1, true), name .. " is loaded before -e's chunk runs: " .. loaded)
  end
end

--- Runs `-e` with `chunk` and `args` and answers the child's result.
local function evaluate(tmp: string, chunk: string, args?: {string}): Child.Result
  local words: mut {string} = { "-e", chunk }
  for _, word in ipairs(args or {}) do words[#words + 1] = word end
  local started = this_program.program(words, { env = {}, cwd = tmp, stdout = "capture",
    stderr = "capture", timeout_ns = Clock.seconds(30) })
  local result = assert(Child.run(started.argv, started.options))
  return result
end

--- Whether the child's stderr holds `text`.
local function says(r: Child.Result, text: string): boolean
  return (r.stderr or ""):find(text, 1, true) ~= nil
end

--- The one-liner of the command-line guide takes the library as a file does, by a literal `require`.
local function test_e_runs_a_chunk_that_requires_the_library(tmp: string)
  local r = evaluate(tmp, 'local Json = require("cosmic.json") local text = Json.encode({ 1, 2 }) print(text)')
  assert(r.ok and r.stdout == "[1,2]\n", tostring(r.stdout) .. tostring(r.stderr))
end

--- The words after the chunk are its `...`, and what it returns is the exit code.
local function test_e_hands_the_words_to_the_chunk_and_exits_with_what_it_returns(tmp: string)
  local r = evaluate(tmp, 'print(select("#", ...), ...) return 3', { "a", "b" })
  assert(r.code == 3 and r.stdout == "2\ta\tb\n", tostring(r.code) .. tostring(r.stdout) .. tostring(r.stderr))
end

--- A chunk the checker refuses does not run at all: nothing it prints, and the checker's own message, with
--- its code and position, as for a file.
local function test_e_refuses_a_chunk_the_checker_refuses_and_runs_none_of_it(tmp: string)
  local r = evaluate(tmp, 'print("ran") local x: integer = "a" print(x)')
  assert(r.code == 1 and r.stdout == "", tostring(r.code) .. tostring(r.stdout))
  assert(says(r, "-e:1:") and says(r, "not_assignable") and says(r, "cosmic help -e"), tostring(r.stderr))
end

--- Lua is not Teal: a parameter with no type, and a name no declaration gives (the globals Lua has and
--- cosmic removed), are refused with the messages a file gets.
local function test_e_refuses_lua_that_teal_does_not_take(tmp: string)
  local untyped = evaluate(tmp, "local function f(x) return x end print(f(1))")
  assert(untyped.code == 1 and says(untyped, "param_untyped"), tostring(untyped.stderr))
  local removed = evaluate(tmp, "os.exit(3)")
  assert(removed.code == 1 and says(removed, "unknown_variable"), tostring(removed.stderr))
end

--- Nothing is pre-bound for a one-liner: it requires what it uses. It may require the tool's own modules beside the
--- library's, and a module the program holds none of is refused where the chunk is checked.
local function test_e_binds_no_module_and_requires_what_the_program_holds(tmp: string)
  local unbound = evaluate(tmp, "print(Json)")
  assert(unbound.code == 1 and says(unbound, "unknown_variable"), tostring(unbound.stderr))
  local own = evaluate(tmp, 'local Status = require("build.exit_status") print(Status.status(7))')
  assert(own.code == 0 and own.stdout == "7\n", tostring(own.stdout) .. tostring(own.stderr))
  local absent = evaluate(tmp, 'local Missing = require("build.nothing_like_this") print(Missing)')
  assert(absent.code == 1 and absent.stdout == "" and says(absent, "build.nothing_like_this"),
    tostring(absent.stdout) .. tostring(absent.stderr))
end

--- A one-liner is a program outside the tree: it may not hand the library to text by the modules that hold the tool's own
--- tables ([`build.project_refusals`]), and what it may do beside them still runs.
local function test_e_is_refused_what_a_project_is_refused_and_runs_the_near_misses(tmp: string)
  local globals = evaluate(tmp, 'local Globals = require("cosmic.internal.globals") print("ran") return 0')
  assert(globals.code == 1 and globals.stdout == "" and says(globals, "cosmic.internal.globals"),
    tostring(globals.stdout) .. tostring(globals.stderr))
  -- the owner's repro: the globals handed to a chunk of text by `load`
  local handed = evaluate(tmp, 'local G=require("cosmic.internal.globals") local f=load("return 1","=x","t",G.table()) if f then f() end')
  assert(handed.code == 1 and says(handed, "cosmic.internal.globals"), tostring(handed.stdout) .. tostring(handed.stderr))
  local underscore = evaluate(tmp, 'local f = _G.load print("ran") return 0')
  assert(underscore.code == 1 and underscore.stdout == "", tostring(underscore.stdout) .. tostring(underscore.stderr))
  local packaged = evaluate(tmp, 'print("ran") return #package.searchers')
  assert(packaged.code == 1 and packaged.stdout == "" and says(packaged, "`package`"), tostring(packaged.stdout) .. tostring(packaged.stderr))
  local bytecode = evaluate(tmp, 'print("ran") local f = load("return 1", "=x", "b", {}) return 0')
  assert(bytecode.code == 1 and bytecode.stdout == "" and says(bytecode, "`load` takes the mode"),
    tostring(bytecode.stdout) .. tostring(bytecode.stderr))
  local text = evaluate(tmp, 'local f = load("return 7", "=x", "t", {}) if f == nil then return 1 end print(f()) return 0')
  assert(text.code == 0 and text.stdout == "7\n", tostring(text.stdout) .. tostring(text.stderr))
  local public = evaluate(tmp, 'local Fs = require("cosmic.fs") print(Fs.dirname("/a/b")) return 0')
  assert(public.code == 0 and public.stdout == "/a\n", tostring(public.stdout) .. tostring(public.stderr))
end

--- An empty chunk runs and exits 0; a chunk that returns what is no exit status exits 2.
local function test_e_answers_an_empty_chunk_and_a_bad_status(tmp: string)
  local empty = evaluate(tmp, "")
  assert(empty.code == 0 and empty.stdout == "", tostring(empty.stderr))
  local bad = evaluate(tmp, "return 256")
  assert(bad.code == 2 and says(bad, "not an exit status"), tostring(bad.stderr))
end

--- With no chunk at all it is a usage error.
local function test_e_without_a_chunk_is_a_usage_error(tmp: string)
  local started = this_program.program({ "-e" }, { env = {}, cwd = tmp, stdout = "capture",
    stderr = "capture", timeout_ns = Clock.seconds(30) })
  local r = assert(Child.run(started.argv, started.options))
  assert(r.code == 2 and says(r, "usage: cosmic -e"), tostring(r.stderr))
end
