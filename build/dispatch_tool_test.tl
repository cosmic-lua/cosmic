--- What `-e` loads and runs: the child most tests start is this program running a chunk, so every module
--- [`build.dispatch`] requires ahead of it is paid by each of them, and a chunk is checked Teal, refused as a file is.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local tool_fixture = require("build.tool_fixture")
local test_child = require("build.test_child")

--- The program itself, started with `-e`.
Test.policy{ profiles = { "cosmic" } }

--- Prints the names of the modules loaded, on one line.
local function print_loaded()
  local names: mut {string} = {}
  for name in pairs(package.loaded) do names[#names + 1] = tostring(name) end
  table.sort(names, function(a: string, b: string): boolean return a < b end)
  print(table.concat(names, " "))
end

--- The child of the test below: the names of the modules loaded when `-e` runs a chunk (the test module's own are among them).
test_child.register("loaded", function(_args: {string}): integer
  print_loaded()
  return 0
end)

--- The child of [`test_a_verb_loads_its_own_cli_module_alone`]: runs `cosmic rand int 1 1` in this process, then
--- prints the names of the modules loaded.
test_child.register("verb_loaded", function(_args: {string}): integer
  local code = require("build.dispatch").main({ "rand", "int", "1", "1" })
  print_loaded()
  return code
end)

--- The modules of the verbs ([`build.verb_list`]) and what only they read: `-e` loads the checker it
--- checks its chunk with, and none of these.
local verbs <const>: {string} = {
  "build.test", "build.fix", "build.embed", "build.databases", "build.lsp", "build.sql",
  "build.cache", "build.json", "build.hash", "build.codec", "build.archive", "build.fetch", "build.time",
  "build.rand", "build.compile", "build.docs", "build.todos", "build.bom", "build.refresh", "build.release",
  "build.sandbox", "build.verb_list", "cosmic.cli", "cosmic.flags",
}

--- `-e` loads no verb and no help: it loads the checker and what the logger reads, and the module that
--- runs a chunk. A module required at dispatch's top level for a verb's sake is loaded by every child a
--- test starts, and fails this.
local function test_e_loads_none_of_the_verbs(tmp: string)
  local started = Test.cosmic(test_child.words(tmp, "build.dispatch_tool_test", "loaded"),
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

--- A verb's command line loads that verb's module of [`cosmic.cli`] alone: [`cosmic.cli`] loads every verb's.
local function test_a_verb_loads_its_own_cli_module_alone(tmp: string)
  local started = Test.cosmic(test_child.words(tmp, "build.dispatch_tool_test", "verb_loaded"),
    { env = {}, cwd = tmp, stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(30) })
  local r = assert(Child.run(started.argv, started.options))
  assert(r.ok, tostring(r.stdout) .. tostring(r.stderr))
  local loaded = " " .. ((r.stdout or ""):gsub("\n", " ")) .. " "
  local clis: mut {string} = {}
  for name in loaded:gmatch("%S+") do
    if name == "cosmic.cli" or name:sub(1, 11) == "cosmic.cli." then clis[#clis + 1] = name end
  end
  assert(#clis == 1 and clis[1] == "cosmic.cli.rand", "`cosmic rand` loads " .. table.concat(clis, ", "))
end

--- Runs `-e` with `chunk` and `args` and returns the child's result.
local function evaluate(tmp: string, chunk: string, args?: {string}): Child.Result
  local words: mut {string} = { "-e", chunk }
  for _, word in ipairs(args or {}) do words[#words + 1] = word end
  local started = Test.cosmic(words, { env = {}, cwd = tmp, stdout = "capture",
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
  local r = evaluate(tmp, 'local Json = require("cosmic.json") print(assert(Json.encode({ 1, 2 })))')
  assert(r.ok and r.stdout == "[1,2]\n", tostring(r.stdout) .. tostring(r.stderr))
end

--- A chunk requires a module of the working directory's tree, as a file at its root does: the module is checked with
--- the chunk, its errors told under its own file.
local function test_e_requires_a_module_of_the_working_directory(tmp: string)
  assert(Fs.write(tmp .. "/util.tl", "local record U\nend\nfunction U.twice(n: integer): integer return n * 2 end\nreturn U\n"))
  local r = evaluate(tmp, 'local U = require("util") print(U.twice(21))')
  assert(r.ok and r.stdout == "42\n", tostring(r.stdout) .. tostring(r.stderr))
  assert(Fs.write(tmp .. "/util.tl", "local record U\nend\nfunction U.twice(n: integer): integer return \"x\" end\nreturn U\n"))
  local broken = evaluate(tmp, 'local U = require("util") print(U.twice(21))')
  assert(broken.code == 4 and says(broken, "util.tl:3:"), tostring(broken.stderr))
  -- A module the binary carries is the binary's, whatever file of its name the tree has.
  assert(Fs.mkdirs(tmp .. "/build"))
  assert(Fs.write(tmp .. "/build/exit_status.tl", "local record E\nend\nreturn E\n"))
  local own = evaluate(tmp, 'local E = require("build.exit_status") print(E.uncompiled)')
  assert(own.ok and own.stdout == "4\n", tostring(own.stdout) .. tostring(own.stderr))
end

--- The words after the chunk are its `...`, and what it returns is the exit code.
local function test_e_hands_the_words_to_the_chunk_and_exits_with_what_it_returns(tmp: string)
  local r = evaluate(tmp, 'print(select("#", ...), ...) return 3', { "a", "b" })
  assert(r.code == 3 and r.stdout == "2\ta\tb\n", tostring(r.code) .. tostring(r.stdout) .. tostring(r.stderr))
end

--- The child's result for `words`, run in `tmp`.
local function ran(tmp: string, words: {string}): Child.Result
  local started = Test.cosmic(words, { env = { COSMIC_STANDALONE = "1" }, cwd = tmp, stdout = "capture",
    stderr = "capture", timeout_ns = Clock.seconds(30) })
  return (assert(Child.run(started.argv, started.options)))
end

--- `eval`, `version` and `run` are verbs as `cosmic help` lists them, each the same as its short form.
local function test_eval_version_and_run_are_typed_by_their_names(tmp: string)
  local e = ran(tmp, { "eval", 'print(...) return 3', "a" })
  assert(e.code == 3 and e.stdout == "a\n", tostring(e.code) .. tostring(e.stdout) .. tostring(e.stderr))
  local named, short = ran(tmp, { "version" }), ran(tmp, { "--version" })
  assert(named.code == 0 and named.stdout == short.stdout and (named.stdout or ""):find("^cosmic %x+\n$") ~= nil,
    tostring(named.stdout) .. tostring(named.stderr))
  assert(Fs.write(tmp .. "/hi.tl", 'print("hi " .. tostring(arg[1]))\n'))
  local runs: {{string}} = { { "run", "hi.tl", "x" }, { "run", "./hi.tl", "x" }, { "run", "--standalone", "hi.tl", "x" } }
  for _, words in ipairs(runs) do
    local r = ran(tmp, words)
    assert(r.code == 0 and r.stdout == "hi x\n", table.concat(words, " ") .. ": " .. tostring(r.stderr))
  end
  local refused: {{string}} = { { "run" }, { "run", "--bogus" } }
  for _, words in ipairs(refused) do
    local r = ran(tmp, words)
    assert(r.code == 2 and says(r, "run takes a file to run"), table.concat(words, " ") .. ": " .. tostring(r.stderr))
  end
end

--- A chunk the checker refuses does not run at all: nothing it prints, and the checker's own message, with
--- its code and position, as for a file.
local function test_e_refuses_a_chunk_the_checker_refuses_and_runs_none_of_it(tmp: string)
  local r = evaluate(tmp, 'print("ran") local x: integer = "a" print(x)')
  assert(r.code == 4 and r.stdout == "", tostring(r.code) .. tostring(r.stdout))
  assert(says(r, "-e:1:") and says(r, "not_assignable") and says(r, "cosmic help -e"), tostring(r.stderr))
end

--- Lua is not Teal: a parameter with no type, and a name no declaration gives (the globals Lua has and
--- cosmic removed), are refused with the messages a file gets.
local function test_e_refuses_lua_that_teal_does_not_take(tmp: string)
  local untyped = evaluate(tmp, "local function f(x) return x end print(f(1))")
  assert(untyped.code == 4 and says(untyped, "param_untyped"), tostring(untyped.stderr))
  local removed = evaluate(tmp, "os.exit(3)")
  assert(removed.code == 4 and says(removed, "unknown_variable"), tostring(removed.stderr))
end

--- A one-liner reads a capitalized library name (`Json`) as its module with no require; any other name no declaration
--- gives is refused. It may require the tool's own modules beside the library's, and a module the program holds none of
--- is refused where the chunk is checked.
local function test_e_binds_no_module_and_requires_what_the_program_holds(tmp: string)
  local implied = evaluate(tmp, 'print(Json.quote("x"))')
  assert(implied.code == 0 and implied.stdout == '"x"\n', tostring(implied.stdout) .. tostring(implied.stderr))
  local unbound = evaluate(tmp, "print(Nosuch.x)")
  assert(unbound.code == 4 and says(unbound, "unknown_variable"), tostring(unbound.stderr))
  local own = evaluate(tmp, 'local Status = require("build.exit_status") print(Status.status(7))')
  assert(own.code == 0 and own.stdout == "7\n", tostring(own.stdout) .. tostring(own.stderr))
  local absent = evaluate(tmp, 'local Missing = require("build.nothing_like_this") print(Missing)')
  assert(absent.code == 4 and absent.stdout == "" and says(absent, "build.nothing_like_this"),
    tostring(absent.stdout) .. tostring(absent.stderr))
end

--- A one-liner is a program outside the tree: it may not hand the library to text by the modules that hold the tool's own
--- tables ([`build.project_refusals`]), and what it may do beside them still runs.
local function test_e_is_refused_what_a_project_is_refused_and_runs_the_near_misses(tmp: string)
  local globals = evaluate(tmp, 'local Globals = require("cosmic.internal.globals") print("ran") return 0')
  assert(globals.code == 4 and globals.stdout == "" and says(globals, "cosmic.internal.globals"),
    tostring(globals.stdout) .. tostring(globals.stderr))
  -- the owner's repro: the globals handed to a chunk of text by `load`
  local handed = evaluate(tmp, 'local G=require("cosmic.internal.globals") local f=load("return 1","=x","t",G.table()) if f then f() end')
  assert(handed.code == 4 and says(handed, "cosmic.internal.globals"), tostring(handed.stdout) .. tostring(handed.stderr))
  local underscore = evaluate(tmp, 'local f = _G.load print("ran") return 0')
  assert(underscore.code == 4 and underscore.stdout == "", tostring(underscore.stdout) .. tostring(underscore.stderr))
  local packaged = evaluate(tmp, 'print("ran") return #package.searchers')
  assert(packaged.code == 4 and packaged.stdout == "" and says(packaged, "`package`"), tostring(packaged.stdout) .. tostring(packaged.stderr))
  local bytecode = evaluate(tmp, 'print("ran") local f = load("return 1", "=x", "b", {}) return 0')
  assert(bytecode.code == 4 and bytecode.stdout == "" and says(bytecode, "`load` takes the mode"),
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

--- A chunk that returns a table prints it as JSON and exits 0, as an agent's snippet hands back what it returns; one
--- that is not JSON exits 2.
local function test_e_prints_a_returned_table_as_json(tmp: string)
  local answer = evaluate(tmp, 'return { n = 1, seen = { "a", "b" } }')
  assert(answer.code == 0 and answer.stdout == '{"n":1,"seen":["a","b"]}\n', tostring(answer.stdout) ..
      tostring(answer.stderr))
  local null = evaluate(tmp, 'return require("cosmic.json").null')
  assert(null.code == 0 and null.stdout == "null\n", tostring(null.stdout) .. tostring(null.stderr))
  local no_json = evaluate(tmp, "return { f = print }")
  assert(no_json.code == 2 and no_json.stdout == "" and says(no_json, "not JSON"), tostring(no_json.stderr))
end

--- A `load` with no mode is text alone in a project, by the core and not by this check alone (core/surface.c's `load_with`
--- forces the mode "t" and a chunk's own environment where none is passed): the bytecode of a function does not load.
local function test_e_load_with_no_mode_does_not_load_bytecode(tmp: string)
  local dumped = evaluate(tmp, 'local f, why = load((string.dump(function(...: any): any return (...) end))) ' ..
      'if f ~= nil then print("loaded") return 1 end print(why) return 0')
  assert(dumped.code == 0 and (dumped.stdout or ""):find("binary chunk", 1, true) ~= nil,
    tostring(dumped.code) .. tostring(dumped.stdout) .. tostring(dumped.stderr))
  local named = evaluate(tmp, 'local f, why = load((string.dump(function(...: any): any return (...) end)), "=x") ' ..
      'if f ~= nil then print("loaded") return 1 end print(why) return 0')
  assert(named.code == 0 and (named.stdout or ""):find("binary chunk", 1, true) ~= nil,
    tostring(named.code) .. tostring(named.stdout) .. tostring(named.stderr))
end

--- With no chunk at all it is a usage error.
local function test_e_without_a_chunk_is_a_usage_error(tmp: string)
  local started = Test.cosmic({ "-e" }, { env = {}, cwd = tmp, stdout = "capture",
    stderr = "capture", timeout_ns = Clock.seconds(30) })
  local r = assert(Child.run(started.argv, started.options))
  assert(r.code == 2 and says(r, "usage: cosmic -e"), tostring(r.stderr))
end

--- A test's child runs from a closure store, which records no boot hash: no build names the sources it checks the chunk
--- against, so a kept compile would outlive an edit of them. It keeps none, and checks the chunk on every run. (A
--- binary that records one keeps it: build/standalone_cache_tool_test.tl.)
local function test_e_keeps_no_compile_where_the_program_records_no_boot_hash(tmp: string)
  local Store = require("cosmic.store")
  assert(Store.meta("boot_hash") == nil, "a test's closure store records a boot hash")
  local chunk = 'local exit_status = require("build.exit_status") print(exit_status.uncompiled) return 0'
  for round = 1, 2 do
    local dir = tmp .. "/prof-" .. tostring(round)
    local env = { XDG_CACHE_HOME = tmp .. "/cache", COSMIC_PROFILE = dir }
    local started = Test.cosmic({ "-e", chunk }, { env = env, cwd = tmp, stdout = "capture",
      stderr = "capture", timeout_ns = Clock.seconds(30) })
    local r = assert(Child.run(started.argv, started.options))
    assert(r.ok and r.stdout == "4\n", tostring(round) .. tostring(r.stdout) .. tostring(r.stderr))
    assert(tool_fixture.loaded(dir)["build.pipeline"] == true, ("run %d of the chunk loaded no checker"):format(round))
  end
  local kept, _ = Fs.list(tmp .. "/cache/cosmic/standalone")
  assert(kept == nil or #kept == 0, "a compile is kept")
end
