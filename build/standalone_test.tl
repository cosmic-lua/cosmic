--- `cosmic --standalone`: one file checked, compiled and run against
--- the binary's own standard library, with no tree around it. Every
--- compile here is in-process; the runs of this program itself are in
--- `standalone_tool_test.tl`.

local standalone = require("build.standalone")
-- A fixture below requires [`cosmic.zip`], which a standalone compile
-- types from the store: required here, it is in this test's closure,
-- so the store the worker is held to answers it.
local type _ = require("cosmic.zip")
local type _json = require("cosmic.json")
-- What a refusal says to write instead is [`cosmic.removed`]'s, which
-- build.teal loads by no `require` a parse records: required here, it
-- is in this test's closure, which the worker lets it load and its key
-- holds.
local _ = require("cosmic.removed")

--- [`standalone.compile`] with its cache in the test's own directory, not
--- this user's: a read of that one is no input a verdict can hold.
local function compile(tmp: string, file: string, source: string): standalone.Main | nil, string
  return standalone.compile(file, source, { XDG_CACHE_HOME = tmp .. "/cache" })
end

local function test_a_file_compiles_against_the_standard_library(tmp: string)
  local chunk = assert(compile(tmp, "x.tl", [[
local Fs = require("cosmic.fs")
return function(argv: {string}): integer
  return #argv + Fs.stdout
end
]]))
  local main = assert(standalone.entry(chunk()))
  assert(main({ "a", "b" }) == 3)
end

local function test_only_the_standard_library_can_be_required(tmp: string)
  local chunk, trouble = compile(tmp, "x.tl", 'local w = require("build.work")\nreturn w\n')
  assert(chunk == nil)
  assert(trouble:find("x.tl:1:", 1, true) ~= nil, trouble)
  assert(trouble:find("build.work", 1, true) ~= nil, trouble)
end

local function test_a_type_error_is_reported_with_its_place(tmp: string)
  local chunk, trouble = compile(tmp, "bad.tl", "local x: integer = \"no\"\nreturn x\n")
  assert(chunk == nil)
  assert(trouble:find("bad.tl:1:", 1, true) ~= nil, trouble)
end

--- A standalone file reaching for a removed library is told, for the
--- field it used, what to write instead.
local function test_a_removed_field_names_its_replacement(tmp: string)
  local chunk, trouble = compile(tmp, "old.tl",
    'return function(): integer\n  io.stderr:write("x")\n  return 0\nend\n')
  assert(chunk == nil)
  assert(trouble:find("old.tl:2:3: unknown variable: io -- io.stderr is not available: " ..
    "use Fs.stderr, a descriptor: Fs.put(Fs.stderr, text)", 1, true) ~= nil, trouble)
end

--- A float assigned to a variable inferred an integer from `= 0` is
--- told to write `0.0` or annotate `number`.
local function test_an_integer_accumulator_names_the_fix(tmp: string)
  local chunk, trouble = compile(tmp, "acc.tl",
    "local peak = 0\npeak = peak + 1.5\nreturn peak\n")
  assert(chunk == nil)
  assert(trouble:find("acc.tl:2:", 1, true) ~= nil, trouble)
  assert(trouble:find("peak is an integer, inferred from 'local peak = 0' at line 1; " ..
    "write 'local peak = 0.0' or 'local peak: number = 0' to hold a number", 1, true) ~= nil, trouble)
end

--- A member a `cosmic.*` module no longer has is told, under the alias
--- the file gave the module, what to write instead.
local function test_a_removed_member_names_its_replacement(tmp: string)
  local chunk, trouble = compile(tmp, "old.tl",
    'local Digest = require("cosmic.hash")\nreturn Digest.hex("x")\n')
  assert(chunk == nil)
  assert(trouble:find("old.tl:2:15: invalid key 'hex' in record 'Digest' of type Digest " ..
    "-- Digest.hex was removed: use Codec.hex(digest)", 1, true) ~= nil, trouble)
end

--- A boolean passed where a parameter now takes a record is told what to
--- write, under the alias the file gave the module; one passed where the
--- record is not the module's own is told nothing more.
local function test_a_boolean_for_a_record_argument_names_the_record(tmp: string)
  local chunk, trouble = compile(tmp, "old.tl",
    'local Sqlite = require("cosmic.sqlite")\nreturn Sqlite.open("x.db", true)\n')
  assert(chunk == nil)
  assert(trouble:find("old.tl:2:28: argument 2: got boolean, expected Sqlite.OpenOptions " ..
    "-- Sqlite.OpenOptions replaced a boolean argument: Sqlite.open(path, opts) takes a table: " ..
    "{ writable = true } for the old `true`", 1, true) ~= nil, trouble)
  chunk, trouble = compile(tmp, "other.tl",
    'local Sqlite = require("cosmic.sqlite")\nreturn Sqlite.run(true, "x")\n')
  assert(chunk == nil)
  assert(trouble:find("replaced a boolean argument", 1, true) == nil, trouble)
end

--- What `cosmic.json` handed to the tool, or dropped, is told where it
--- went or what to write instead: a function, a type, and a function
--- with a replacement in the library.
local function test_a_moved_json_member_names_its_new_home(tmp: string)
  local chunk, trouble = compile(tmp, "old.tl",
    'local Json = require("cosmic.json")\nreturn Json.describe({})\n')
  assert(chunk == nil)
  assert(trouble:find("old.tl:2:13: invalid key 'describe' in record 'Json' of type Json " ..
    "-- Json.describe was removed: moved to build.json_query, which only `cosmic json` calls; " ..
    "`cosmic json --shape file` prints a document's shape", 1, true) ~= nil, trouble)
  chunk, trouble = compile(tmp, "step.tl",
    'local Json = require("cosmic.json")\n' ..
    'local function f(step: Json.Step): integer\n  return step and 1 or 0\nend\nreturn f\n')
  assert(chunk == nil)
  assert(trouble:find("step.tl:2:24: unknown type Json.Step -- Json.Step was removed: " ..
    "moved to build.json_query", 1, true) ~= nil, trouble)
  chunk, trouble = compile(tmp, "lines.tl",
    'local Json = require("cosmic.json")\nreturn Json.encode_lines({})\n')
  assert(chunk == nil)
  assert(trouble:find("Json.encode_lines was removed: use Json.encode(value) for each value", 1, true) ~= nil,
    trouble)
end

--- A `<const>` binding, and a second alias of it, are the module still.
local function test_a_removed_member_is_named_through_const_and_alias(tmp: string)
  local chunk, trouble = compile(tmp, "old.tl",
    'local Zip <const> = require("cosmic.zip")\nlocal Z = Zip\n' ..
    'return Z.list("a.zip")\n')
  assert(chunk == nil)
  assert(trouble:find("old.tl:3:10: invalid key 'list' in record 'Z' of type Zip " ..
    "-- Z.list was removed: use Archive.list(path)", 1, true) ~= nil, trouble)
end

--- A type a `cosmic.*` module no longer declares is told its new name,
--- under the alias the file gave the module; a type the module never
--- declared is told nothing more.
local function test_a_renamed_type_names_its_replacement(tmp: string)
  local chunk, trouble = compile(tmp, "old.tl",
    'local Z <const> = require("cosmic.zip")\n' ..
    'local function f(r: Z.ZipReader): integer\n  return r and 1 or 0\nend\n' ..
    'return f\n')
  assert(chunk == nil)
  assert(trouble:find("module not found", 1, true) == nil, trouble)
  assert(trouble:find("old.tl:2:21: unknown type Z.ZipReader " ..
    "-- Z.ZipReader was removed: use Zip.Reader", 1, true) ~= nil, trouble)
  chunk, trouble = compile(tmp, "new.tl",
    'local Zip = require("cosmic.zip")\n' ..
    'local function f(r: Zip.Nothing): integer\n  return r and 1 or 0\nend\n' ..
    'return f\n')
  assert(chunk == nil)
  assert(trouble:find("module not found", 1, true) == nil, trouble)
  assert(trouble:find("unknown type Zip.Nothing", 1, true) ~= nil, trouble)
  assert(trouble:find("was removed", 1, true) == nil, trouble)
  -- `list` is a removed function, never a type: nothing is offered.
  chunk, trouble = compile(tmp, "fn.tl",
    'local Zip = require("cosmic.zip")\n' ..
    'local function f(r: Zip.list): integer\n  return r and 1 or 0\nend\n' ..
    'return f\n')
  assert(chunk == nil)
  assert(trouble:find("module not found", 1, true) == nil, trouble)
  assert(trouble:find("unknown type Zip.list", 1, true) ~= nil, trouble)
  assert(trouble:find("was removed", 1, true) == nil, trouble)
end

--- A record of the file's own named like a module's alias is not that
--- module: no replacement is offered for its missing field.
local function test_a_shadowing_record_is_not_told_a_replacement(tmp: string)
  local chunk, trouble = compile(tmp, "old.tl",
    'local Zip = require("cosmic.zip")\nlocal record R\n  x: integer\nend\n' ..
    'local function f(Zip: R): integer\n  return Zip.list\nend\n' ..
    'return { f = f, zip = Zip }\n')
  assert(chunk == nil)
  assert(trouble:find("module not found", 1, true) == nil, trouble)
  assert(trouble:find("invalid key 'list' in record 'Zip' of type R", 1, true) ~= nil, trouble)
  assert(trouble:find("was removed", 1, true) == nil, trouble)
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
