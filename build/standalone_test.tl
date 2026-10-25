--- `cosmic --standalone`: one file checked, compiled and run against
--- the binary's own standard library, with no tree around it. Every
--- compile here is in-process; the runs of this program itself are in
--- `standalone_tool_test.tl`.

local Test = require("cosmic.test")
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
local _cli <const> = require("cosmic.cli")
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
  assert(standalone.entry({ main = main }) == main)
  assert(standalone.entry(main) == main)
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

--- The refusals a file alone meets, in the checker's words: the place, the code and what to write instead.
local function test_the_checker_refuses_a_file_with_a_place_a_code_and_the_replacement(tmp: string)
  local chunk, trouble = compile(tmp, "bad.tl", "local x: integer = \"no\"\nreturn x\n")
  assert(chunk == nil and trouble:find("bad.tl:1:", 1, true) == 1 and trouble:find("(not_assignable)", 1, true) ~= nil, trouble)
  -- only the standard library can be required
  chunk, trouble = compile(tmp, "work.tl", 'local w = require("build.work")\nreturn w\n')
  assert(chunk == nil and trouble:find("work.tl:1:11: the project has no module `build.work` (require_unknown)", 1, true) ~= nil,
    trouble)
  -- a removed library is told what to write instead, for the field and the member used
  chunk, trouble = compile(tmp, "old.tl", 'return function(): integer\n  io.stderr:write("x")\n  return 0\nend\n')
  assert(chunk == nil and trouble:find("old.tl:2:3: `io` is not declared (unknown_variable): io.stderr is not available: " ..
      "use Fs.stderr, a descriptor: Fs.put(Fs.stderr, text)", 1, true) ~= nil, trouble)
  chunk, trouble = compile(tmp, "hex.tl", 'local Digest = require("cosmic.hash")\nreturn Digest.hex("x")\n')
  assert(chunk == nil and trouble:find("hex.tl:2:8: `Hash` has no field `hex` (field_unknown): Digest.hex was removed: " ..
      "use Codec.hex(digest)", 1, true) ~= nil, trouble)
  chunk, trouble = compile(tmp, "cli.tl", 'local Cli = require("cosmic.cli")\nreturn Cli.options.test\n')
  assert(chunk == nil and trouble:find("Cli.options was removed: use Cli.verbs[verb].spec", 1, true) ~= nil, trouble)
  chunk, trouble = compile(tmp, "bool.tl", 'local Sqlite = require("cosmic.sqlite")\nreturn Sqlite.open("x.db", true)\n')
  assert(chunk == nil and trouble:find("bool.tl:2:28: `true` is `boolean`, where `Sqlite.OpenOptions?` is wanted as argument 2 " ..
      "of `Sqlite.open` (not_assignable): Sqlite.OpenOptions replaced a boolean argument", 1, true) ~= nil, trouble)
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

--- A file run alone has no ceilings to raise, so its refusal never speaks of a pin.
local function test_a_refusal_of_a_file_alone_speaks_of_no_pin(tmp: string)
  local variables = { XDG_CACHE_HOME = tmp .. "/cache" }
  local code, trouble = standalone.code("bad.tl", "local n: integer = \"no\"\nreturn n\n", variables)
  assert(code == nil and trouble:find("(not_assignable)", 1, true) ~= nil, tostring(trouble))
  assert(trouble:find("pin", 1, true) == nil, trouble)
  assert(trouble:find("1 error of not_assignable in its bodies; follow the fix above", 1, true) ~= nil, trouble)
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
