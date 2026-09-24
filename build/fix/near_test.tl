local near = require("build.fix.near")
local Store = require("cosmic.store")
local positions = require("build.positions")
local teal = require("build.teal")
local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")

local known: {near.Known} = {
  { kind = "function", module = "cosmic.proc", symbol = "find", source_symbol = "Proc.find",
    signature = "function Proc.find(name: string): string",
    text = "Where a program would run from, as `which` or `command -v` finds it." },
  { kind = "function", module = "cosmic.fs", symbol = "mkdirs", source_symbol = "Fs.mkdirs",
    signature = "function Fs.mkdirs(path: string): boolean", text = "Creates a directory and every missing directory above it, as\n`mkdir -p` does." },
  { kind = "function", module = "cosmic.json", symbol = "decode", source_symbol = "Json.decode",
    signature = "function Json.decode(text: string): any", text = "Any JSON value; see `decode_object` or `decode_array`." },
  { kind = "function", module = "cosmic.stream", symbol = "close", source_symbol = "Stream.close",
    signature = "function Stream.close(s: Stream)", text = "Ends the stream; the writer's `close` flushes first." },
  { kind = "function", module = "cosmic.sys", symbol = "mkdir", source_symbol = "syscalls.mkdir",
    signature = "mkdir: function(path: string, mode: integer): boolean", text = "mkdir(2)." },
  { kind = "record", module = "cosmic.rand", symbol = "Source", source_symbol = "Source",
    signature = "record Source", text = "" },
  { kind = "function", module = "cosmic.fs", symbol = "close", source_symbol = "Fs.close",
    signature = "function Fs.close(fd: integer)", text = "Closes a descriptor." },
}

--- A function named for what another module's function stands in for
--- earns a note naming that function.
local function test_a_name_another_module_stands_in_for_is_noted()
  local notes = near.notes("tools.paths", {
    { source_symbol = "Paths.which", text = "Finds a program.", line = 7 },
    { source_symbol = "Paths.mkdir", text = "Makes a directory.", line = 9 },
  }, known)
  assert(#notes == 2, tostring(#notes))
  assert(notes[1]:find("^7: Paths.which: Proc.find %(cosmic.proc%) stands in for `which`"),
    notes[1])
  assert(notes[2]:find("^9: Paths.mkdir: Fs.mkdirs %(cosmic.fs%) stands in for `mkdir`"),
    notes[2])
end

--- A sibling in the same module names the function it refers to, not
--- a command; a name another public symbol already carries means that
--- symbol; and a function whose own documentation names the other knows
--- of it already. None is noted.
local function test_references_and_known_names_are_not_noted()
  assert(#near.notes("cosmic.json", {
    { source_symbol = "Json.decode_object", text = "An object.", line = 3 },
  }, known) == 0)
  assert(#near.notes("tools.io", {
    { source_symbol = "Io.close", text = "Closes it.", line = 3 },
  }, known) == 0)
  assert(#near.notes("tools.paths", {
    { source_symbol = "Paths.which", text = "Proc.find, with a default.", line = 3 },
  }, known) == 0)
  assert(#near.notes("tools.paths", {
    { source_symbol = "Paths.which", text = "Like `find`, with a default.", line = 3 },
  }, known) == 0)
  -- A bare verb that happens to be the other's name names nothing.
  assert(#near.notes("tools.paths", {
    { source_symbol = "Paths.which", text = "Finds the program on the PATH.", line = 3 },
  }, known) == 1)
  -- A name a public type carries is taken too.
  local sourced: {near.Known} = { known[6], { kind = "function", module = "cosmic.rand",
    symbol = "entropy", source_symbol = "Rand.entropy",
    signature = "function Rand.entropy(count: integer): string",
    text = "Bytes from the system, unlike a `Source`." } }
  assert(#near.notes("cosmic.store", {
    { source_symbol = "Store.source", text = "A module's source.", line = 3 },
  }, sourced) == 0)
end

--- Only a command or C call is taken as what a function stands in for:
--- documentation backticks keywords, fields and examples as well.
local function test_only_a_command_is_a_stand_in()
  local keyworded: {near.Known} = { { kind = "function", module = "cosmic.json",
    symbol = "decode", source_symbol = "Json.decode",
    signature = "function Json.decode(text: string): any",
    text = "Any value; narrow it with `is`, then `finish` the reader." } }
  assert(#near.notes("tools.m", {
    { source_symbol = "M.is", text = "Whether.", line = 1 },
    { source_symbol = "M.finish", text = "Ends.", line = 2 },
  }, keyworded) == 0)
  -- cosmic.removed names removed functions as examples, not stand-ins.
  local removed: {near.Known} = { { kind = "function", module = "cosmic.removed",
    symbol = "message", source_symbol = "module.message",
    signature = "function module.message(name: string, field: string): string",
    text = "What replaced a removed name, as for (`os`, `getenv`)." } }
  assert(#near.notes("tools.m", {
    { source_symbol = "M.getenv", text = "A variable.", line = 1 },
  }, removed) == 0)
end

--- A name another function backticks as its own parameter is not what
--- it stands in for.
local function test_a_parameter_is_not_a_stand_in()
  assert(#near.notes("cosmic.stream", {
    { source_symbol = "Stream.skip", text = "Skips bytes.", line = 3 },
  }, { { kind = "function", module = "cosmic.fs", symbol = "walk", source_symbol = "Fs.walk",
    signature = "function Fs.walk(root: string, skip?: function(string): boolean)",
    text = "Every file under a root; `skip` may refuse a directory." } }) == 0)
end

--- Two doc comments in nearly the same words are noted; short ones
--- are not compared, and a function is never compared with itself.
local function test_nearly_the_same_words_are_noted()
  local long: {near.Known} = {
    { kind = "function", module = "cosmic.proc", symbol = "find", source_symbol = "Proc.find",
      signature = "function Proc.find(name: string): string",
      text = "Where the program name would run from, searched along the PATH " ..
        "directories in order, first executable file wins." },
  }
  local notes = near.notes("cosmic.proc", {
    { source_symbol = "Proc.locate", line = 12,
      text = "Where the program name would run from: searched along PATH " ..
        "directories in order, the first executable file wins." },
    { source_symbol = "Proc.find", line = 20,
      text = "Where the program name would run from, searched along the PATH " ..
        "directories in order, first executable file wins." },
  }, long)
  assert(#notes == 1, tostring(#notes))
  assert(notes[1]:find("^12: Proc.locate: Proc.find %(cosmic.proc%) is documented in nearly"),
    notes[1])
  assert(#near.notes("tools.x", {
    { source_symbol = "X.find", text = "Where it runs.", line = 1 },
  }, { { kind = "function", module = "cosmic.proc", symbol = "find", source_symbol = "Proc.find",
    signature = "function Proc.find(name: string): string", text = "Where it runs." } }) == 0)
end

--- The standard library as it stands earns no note against itself, so a
--- note on a fixed file is about what that file adds.
local function test_the_standard_library_earns_no_note()
  local all = assert(near.known(Store.databases()))
  assert(#all > 100, tostring(#all))
  local built = assert(teal.load())
  local by_module: {string: boolean} = {}
  for _, entry in ipairs(all) do by_module[entry.module] = true end
  local noted: {string} = {}
  for module in pairs(by_module) do
    local file = module:gsub("%.", "/") .. ".tl"
    local source = Fs.read(file)
    if source ~= nil then
      local found = assert(positions.analyze(built, source, file))
      local candidates: {near.Candidate} = {}
      for _, entry in ipairs(found.docs) do
        if entry.exported and (entry.kind == "function" or entry.kind == "method") and
            entry.text ~= "" then
          candidates[#candidates + 1] = { source_symbol = entry.source_symbol,
            text = entry.text, line = entry.line }
        end
      end
      for _, note in ipairs(near.notes(module, candidates, all)) do
        noted[#noted + 1] = file .. ":" .. note
      end
    end
  end
  assert(#noted == 0, table.concat(noted, "\n"))
end

--- A database built before the `docs` table existed offers nothing,
--- rather than failing every fix.
local function test_a_database_without_docs_offers_nothing()
  local bare = assert(Sqlite.memory())
  local found, trouble = near.known({ bare })
  assert(found ~= nil and #found == 0, trouble)
end
