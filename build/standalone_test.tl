--- `cosmic --standalone`: one file checked, compiled and run against
--- the binary's own standard library, with no tree around it. Every
--- compile here is in-process; the runs of this program itself are in
--- `standalone_tool_test.tl`.

local Test = require("cosmic.test")
local Store = require("cosmic.store")
local standalone = require("build.standalone")
-- The new checker types a file against the declarations the tool carries, which only a worker that holds the tool's database
-- ("cosmic") has.
Test.policy{ profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" } } }

-- A fixture below requires [`cosmic.zip`], [`cosmic.tar`] or
-- [`cosmic.archive`], which a standalone compile types from the store:
-- required here, each is in this test's closure, so the store the
-- worker is held to answers it.
local type _ = require("cosmic.zip")
local type _tar = require("cosmic.tar")
local type _archive = require("cosmic.archive")
local type _json = require("cosmic.json")
-- What a refusal says to write instead is [`cosmic.removed`]'s, which
-- build.removed_fix reads: required here, it
-- is in this test's closure, which the worker lets it load and its key
-- holds.
local _ = require("cosmic.removed")

--- [`standalone.compile`] with its cache in the test's own directory, not this user's: a read of that one is no input a
--- verdict can hold.
local function compile(tmp: string, file: string, source: string): standalone.Main?, string
  return standalone.compile(file, source, { XDG_CACHE_HOME = tmp .. "/cache" })
end

local function test_a_record_with_main_is_an_entry_point()
  local function main(): integer
    return 7
  end
  assert(standalone.entry({ main = main }) == main) -- checked: compare_disjoint
  assert(standalone.entry(main) == main) -- checked: compare_disjoint
  assert(standalone.entry({ other = main }) == nil)
  assert(standalone.entry(42) == nil)
end

local function test_a_file_compiles_against_the_standard_library_and_runs(tmp: string)
  local chunk = assert(compile(tmp, "x.tl", [[
local Fs = require("cosmic.fs")
return function(argv: {string}): integer
  return #argv + Fs.stdout
end
]]))
  local main = assert(standalone.entry(chunk()))
  assert(main({ "a", "b" }) == 3)
  -- a record with `main` is an entry point as well
  local record_chunk = assert(compile(tmp, "record.tl", [[
local record Script
  main: function({string}): integer
end
function Script.main(argv: {string}): integer
  return #argv
end
return Script
]]))
  local entry = assert(standalone.entry(record_chunk()))
  assert(entry({ "a" }) == 1)
end

--- The modules `name` requires as its top level runs, read from the source the store holds: a line at the margin that
--- binds a `require` of a literal name (`local X = require("m")`, or a field of it). A `local type` require loads nothing.
local function loaded_at_top(name: string): {string}
  local source = assert(Store.source(name))
  local out: mut {string} = {}
  for line in source:gmatch("[^\n]+") do
    if line:match("^local type ") == nil then
      local required = line:match("^local [%w_, ]+= require%(\"([%w_.]+)\"%)")
      if required ~= nil then out[#out + 1] = required end
    end
  end
  return out
end

--- A file this binary compiled cleanly before runs from the cache, so loading [`build.standalone`] loads no checker
--- ([`build.pipeline`], about a hundred modules): it costs a cached run more than the rest of it. (A process that lists
--- what it loaded cannot run here: `package.loaded` is a view, and a standalone file may not read `package`.)
-- TODO: hold a cached run of `cosmic --standalone` to loading no checker by what the process loaded, not by the lines of
-- the sources, once a test can start a process that lists what it loaded without loading the checker first (`-e` does).
local function test_loading_standalone_loads_no_checker()
  local seen: mut {string:boolean} = {}
  local stack: mut {string} = { "build.standalone" }
  while #stack > 0 do
    local name = assert(table.remove(stack))
    if seen[name] == nil then
      seen[name] = true
      assert(name ~= "build.pipeline", "build.standalone loads the checker as it loads")
      for _, required in ipairs(loaded_at_top(name)) do stack[#stack + 1] = required end
    end
  end
end

--- The refusals a file alone meets, in the checker's words: the place, the code and what to write instead.
local function test_the_checker_refuses_a_file_with_a_place_a_code_and_the_replacement(tmp: string)
  local chunk, trouble = compile(tmp, "bad.tl", "local x: integer = \"no\"\nreturn x\n")
  assert(chunk == nil and trouble:find("bad.tl:1:", 1, true) == 1 and trouble:find("(not_assignable)", 1, true) ~= nil, trouble)
  -- only the standard library can be required
  chunk, trouble = compile(tmp, "work.tl", 'local w = require("build.work")\nreturn w\n')
  assert(chunk == nil and trouble:find("work.tl:1:11: the project has no module `build.work` (require_unknown)", 1, true) ~= nil,
    trouble)
  -- a removed library is told what to write instead, for the field used
  chunk, trouble = compile(tmp, "old.tl", 'return function(): integer\n  io.stderr:write("x")\n  return 0\nend\n')
  assert(chunk == nil and trouble:find("old.tl:2:3: `io` is not declared (unknown_variable): io.stderr is not available: " ..
      "use Fs.stderr, a descriptor: Fs.put(Fs.stderr, text), which answers a result to discard on purpose: " ..
      'local _, _ = Fs.put(Fs.stderr, text .. "\\n")', 1, true) ~= nil, trouble)
  -- a float into an integer accumulator is told how to hold it
  chunk, trouble = compile(tmp, "acc.tl", "local peak = 0\npeak = peak + 1.5\nreturn peak\n")
  assert(chunk == nil and trouble:find("acc.tl:2:8: `peak + 1.5` is `number`, where `integer` is wanted in the assignment to " ..
      "`peak` (not_assignable)", 1, true) ~= nil, trouble)
  -- a field a record lacks
  chunk, trouble = compile(tmp, "stat.tl",
    'local Fs = require("cosmic.fs")\nlocal st = assert(Fs.stat("."))\nreturn st.type\n')
  assert(chunk == nil and trouble:find("stat.tl:3:8: ", 1, true) ~= nil and trouble:find("(field_unknown)", 1, true) ~= nil,
    trouble)
end

--- A file run alone has no marker to add, so its refusal never speaks of one.
local function test_a_refusal_of_a_file_alone_speaks_of_no_marker(tmp: string)
  local variables = { XDG_CACHE_HOME = tmp .. "/cache" }
  local code, trouble = standalone.code("bad.tl", "local n: integer = \"no\"\nreturn n\n", variables)
  assert(code == nil and trouble:find("(not_assignable)", 1, true) ~= nil, tostring(trouble))
  assert(trouble:find("marker", 1, true) == nil, trouble)
  assert(trouble:find("1 error of not_assignable in its bodies on line 1; follow the fix above", 1, true) ~= nil, trouble)
end

--- The modules a file requires are read by the checker that compiles it ([`standalone.requires`], which `cosmic sandbox --closure`
--- takes its closure from).
local function test_the_requires_of_a_file_are_read_by_the_checker_that_compiles_it()
  local source = 'local Fs = require("cosmic.fs")\nlocal Hash = require("cosmic.hash")\n' ..
    "local function f(x: string?): string?\n  return x\nend\nreturn function(): integer\n  return #(f(Hash.sha256) or \"\") + Fs.stdout\nend\n"
  local read = assert(standalone.requires("x.tl", source))
  assert(#read == 2 and read[1] == "cosmic.fs" and read[2] == "cosmic.hash", table.concat(read, ","))
  local grammar = 'local Json = require("cosmic.json")\nlocal words: mut {string} = {}\n' ..
    "return function(): integer\n  words[#words + 1] = Json.encode(1)\n  return #words\nend\n"
  local read_new = assert(standalone.requires("n.tl", grammar))
  assert(#read_new == 1 and read_new[1] == "cosmic.json", table.concat(read_new, ","))
  -- a file that does not parse is told in the checker's words
  local broken, broken_trouble = standalone.requires("b.tl", "local x = (\n")
  assert(broken == nil and broken_trouble:find("b.tl:", 1, true) == 1, tostring(broken_trouble))
end

--- What a file run reads to tell whether a file runs alone: its requires by their tokens, and only the literal forms.
local function test_the_requires_a_file_run_reads_are_the_literal_ones()
  local read = assert(standalone.literal_requires(
    'local Fs = require("cosmic.fs")\nlocal type J = require "cosmic.json"\n' ..
      '-- require("in.a.comment")\nlocal s = "require(\\"in.a.string\\")"\nlocal t = x.require("a.field")\n'))
  assert(#read == 2 and read[1] == "cosmic.fs" and read[2] == "cosmic.json", table.concat(read, ","))
  assert(standalone.literal_requires('local name = "m"\nlocal M = require(name)\n') == nil)
  assert(standalone.literal_requires('local ok = pcall(require, "m")\n') == nil)
  assert(standalone.literal_requires('local M = require("m" .. "n")\n') == nil)
  assert(standalone.literal_requires('local s = "unterminated\n') == nil)
end

--- A file runs alone where it requires only what the binary carries and is no program's main and no test.
local function test_a_file_runs_alone_where_it_needs_only_the_standard_library()
  local carried = 'local Fs = require("cosmic.fs")\nlocal Json = require("cosmic.json")\nreturn Fs, Json\n'
  assert(standalone.runs_alone("script.tl", carried))
  assert(standalone.runs_alone("/home/u/tools/script.tl", carried))
  assert(not standalone.runs_alone("script.tl", 'local M = require("lib.m")\nreturn M\n'))
  assert(not standalone.runs_alone("script.tl", 'local M = require(arg[1])\nreturn M\n'))
  assert(not standalone.runs_alone("cmd/hi/main.tl", carried))
  assert(not standalone.runs_alone("/p/cmd/hi/main.tl", carried))
  assert(not standalone.runs_alone("script_test.tl", carried))
  assert(standalone.runs_alone("cmd/hi/other.tl", carried))
end

--- What a file returns is held to a declaration, as its tree holds it: a table no declaration describes is refused, as
--- `cosmic fix` refuses it. A chunk of `-e` returns its exit code, which nothing describes.
local function test_a_file_returns_what_a_declaration_describes(tmp: string)
  local undeclared = "local function helper(): integer\n  return 1\nend\nreturn { main = helper }\n"
  local refused, trouble = compile(tmp, "u.tl", undeclared)
  assert(refused == nil and trouble:find("(export_not_declared)", 1, true) ~= nil, tostring(trouble))
  local chunk = standalone.compile("-e", "return 3\n", { XDG_CACHE_HOME = tmp .. "/cache" }, true)
  assert(chunk ~= nil and chunk() == 3)
end

--- A file is an entry point: a function it returns that cannot take the command line's words is refused before it runs.
--- A chunk of `-e` is called by nothing, so it is not held so.
local function test_a_file_returns_what_takes_the_command_line(tmp: string)
  local refused, trouble = compile(tmp, "n.tl", "return function(n: integer): integer\n  return n\nend\n")
  assert(refused == nil and trouble:find("(entry_signature)", 1, true) ~= nil, tostring(trouble))
  local taken, _ = compile(tmp, "w.tl", "return function(argv: {string}): integer\n  return #argv\nend\n")
  assert(taken ~= nil)
  local chunk = standalone.compile("-e", "return function(n: integer): integer\n  return n\nend\n",
    { XDG_CACHE_HOME = tmp .. "/cache" }, true)
  assert(chunk ~= nil)
end
