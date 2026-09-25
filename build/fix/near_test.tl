local near = require("build.fix.near")
local Store = require("cosmic.store")
local analyzer = require("build.analyzer")
local teal = require("build.teal")
local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local fixture = require("build.docs_fixture")

--- Lines as one source file's text.
local function joined(...: string): string
  return table.concat({ ... }, "\n") .. "\n"
end

--- What `near.known` offers from the database the tree `files` builds
--- to, as `build.docs_fixture` makes it with the build's own code, and
--- each entry by the name it was written as, which must all be there.
local function known_of(dir: string, files: {string: string},
                        wanted: {string}): {near.Known}, {string: near.Known}
  local found = assert(near.known({ fixture.database(dir, files) }))
  local by_source: {string: near.Known} = {}
  for _, entry in ipairs(found) do by_source[entry.source_symbol] = entry end
  for _, name in ipairs(wanted) do
    assert(by_source[name] ~= nil, name .. " is not among what the build offers")
  end
  return found, by_source
end

--- A few of the standard library's own functions, and a raw binding.
local function standard(dir: string): {near.Known}
  return (known_of(dir, {
    ["cosmic/proc.tl"] = joined(
      "local record Proc",
      "end",
      "",
      "--- Where a program would run from, as `which` or `command -v` finds it.",
      "function Proc.find(name: string): string",
      "  return name",
      "end",
      "",
      "return Proc"),
    ["cosmic/fs.tl"] = joined(
      "local record Fs",
      "end",
      "",
      "--- Creates a directory and every missing directory above it, as",
      "--- `mkdir -p` does.",
      "function Fs.mkdirs(path: string): boolean",
      "  return path ~= \"\"",
      "end",
      "",
      "--- Closes a descriptor.",
      "function Fs.close(fd: integer)",
      "end",
      "",
      "return Fs"),
    ["cosmic/json.tl"] = joined(
      "local record Json",
      "end",
      "",
      "--- Any JSON value; see `decode_object` or `decode_array`.",
      "function Json.decode(text: string): any",
      "  return text",
      "end",
      "",
      "return Json"),
    ["cosmic/stream.tl"] = joined(
      "local record Stream",
      "end",
      "",
      "--- Ends the stream; the writer's `close` flushes first.",
      "function Stream.close(s: Stream)",
      "end",
      "",
      "return Stream"),
    ["cosmic/sys.d.tl"] = joined(
      "local record syscalls",
      "  --- mkdir(2).",
      "  mkdir: function(path: string, mode: integer): boolean",
      "end",
      "",
      "return syscalls"),
  }, { "Proc.find", "Fs.mkdirs", "Fs.close", "Json.decode", "Stream.close",
       "syscalls.mkdir" }))
end

--- A function named for what another module's function stands in for
--- earns a note naming that function.
local function test_a_name_another_module_stands_in_for_is_noted(dir: string)
  local notes = near.notes("tools.paths", {
    { source_symbol = "Paths.which", text = "Finds a program.", line = 7 },
    { source_symbol = "Paths.mkdir", text = "Makes a directory.", line = 9 },
  }, standard(dir))
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
local function test_references_and_known_names_are_not_noted(dir: string)
  local known = standard(dir)
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
  local sourced = known_of(dir, { ["cosmic/rand.tl"] = joined(
    "local record Rand",
    "  record Source",
    "  end",
    "end",
    "",
    "--- Bytes from the system, unlike a `Source`.",
    "function Rand.entropy(count: integer): string",
    "  return tostring(count)",
    "end",
    "",
    "return Rand") }, { "Rand.Source", "Rand.entropy" })
  assert(#near.notes("cosmic.store", {
    { source_symbol = "Store.source", text = "A module's source.", line = 3 },
  }, sourced) == 0)
end

--- Only a command or C call is taken as what a function stands in for:
--- documentation backticks keywords, fields and examples as well.
local function test_only_a_command_is_a_stand_in(dir: string)
  local keyworded = known_of(dir, { ["cosmic/json.tl"] = joined(
    "local record Json",
    "end",
    "",
    "--- Any value; narrow it with `is`, then `finish` the reader.",
    "function Json.decode(text: string): any",
    "  return text",
    "end",
    "",
    "return Json") }, { "Json.decode" })
  assert(#near.notes("tools.m", {
    { source_symbol = "M.is", text = "Whether.", line = 1 },
    { source_symbol = "M.finish", text = "Ends.", line = 2 },
  }, keyworded) == 0)
  -- cosmic.removed names removed functions as examples, not stand-ins.
  local removed = known_of(dir, { ["cosmic/removed.tl"] = joined(
    "local record module",
    "end",
    "",
    "--- What replaced a removed name, as for (`os`, `getenv`).",
    "function module.message(name: string, field: string): string",
    "  return name .. field",
    "end",
    "",
    "return module") }, { "module.message" })
  assert(#near.notes("tools.m", {
    { source_symbol = "M.getenv", text = "A variable.", line = 1 },
  }, removed) == 0)
end

--- A name another function backticks as its own parameter is not what
--- it stands in for, even a command's name.
local function test_a_parameter_is_not_a_stand_in(dir: string)
  local list = known_of(dir, { ["cosmic/fs.tl"] = joined(
    "local record Fs",
    "end",
    "",
    "--- Every entry of a directory; `sort` orders them by name.",
    "function Fs.list(path: string, sort?: boolean): {string}",
    "  return {}",
    "end",
    "",
    "return Fs") }, { "Fs.list" })
  assert(#near.notes("cosmic.stream", {
    { source_symbol = "Stream.sort", text = "Sorts lines.", line = 3 },
  }, list) == 0)
end

--- Two doc comments in nearly the same words are noted; short ones
--- are not compared, and a function is never compared with itself.
local function test_nearly_the_same_words_are_noted(dir: string)
  local long = known_of(dir, { ["cosmic/proc.tl"] = joined(
    "local record Proc",
    "end",
    "",
    "--- Where the program name would run from, searched along the PATH",
    "--- directories in order, first executable file wins.",
    "function Proc.find(name: string): string",
    "  return name",
    "end",
    "",
    "return Proc") }, { "Proc.find" })
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
  local short = known_of(dir, { ["cosmic/proc.tl"] = joined(
    "local record Proc",
    "end",
    "",
    "--- Where it runs.",
    "function Proc.find(name: string): string",
    "  return name",
    "end",
    "",
    "return Proc") }, { "Proc.find" })
  assert(#near.notes("tools.x", {
    { source_symbol = "X.find", text = "Where it runs.", line = 1 },
  }, short) == 0)
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
      local found = assert(analyzer.analyze(built, source, file))
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
