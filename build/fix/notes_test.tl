--- What `cosmic fix` notes of a fixed file beside fixing it
--- (build/fix/fix_test.tl holds the fixing), against a standard library
--- of the test's own, built by [`build.docs_fixture`].

local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local fix = require("build.fix")
local fixture = require("build.docs_fixture")
local links = require("build.links")
local near = require("build.fix.near")
local SyntaxNode = require("build.syntax_node")
local tree_checks = require("build.tree_checks")

--- The standard library's one function, [`Proc.find`], in a database of its own under `tmp`.
local function library_of(tmp: string): Sqlite.Handle
  assert(Fs.mkdirs(tmp .. "/library"))
  return fixture.database(tmp .. "/library", {
    ["cosmic/proc.tl"] = table.concat({
      "local record Proc",
      "end",
      "",
      "--- Where a program would run from, as `which` or `command -v` finds it.",
      "function Proc.find(name: string): string",
      "  return name",
      "end",
      "",
      "return Proc",
      "",
    }, "\n"),
  })
end

--- [`fix.notes`] reads each fixed file's exported functions and notes the
--- one the standard library already has, prefixed with its file and
--- line; a test file, and a file outside the tree, earn nothing.
local function test_notes_name_what_the_library_already_has(tmp: string)
  local source = table.concat({
    "local record Paths",
    "end",
    "",
    "--- Where a program is.",
    "function Paths.which(name: string): string",
    "  return name",
    "end",
    "",
    "return Paths",
    "",
  }, "\n")
  -- The tree is reached through a link, as a macOS temporary directory
  -- is (/var is /private/var): the root and each file must be resolved
  -- alike.
  assert(Fs.mkdirs(tmp .. "/real/tools/paths"))
  assert(Fs.symlink(tmp .. "/real", tmp .. "/tree"))
  assert(Fs.write(tmp .. "/tree/tools/paths/init.tl", source))
  assert(Fs.write(tmp .. "/tree/tools/paths_test.tl", source))
  assert(Fs.write(tmp .. "/outside.tl", source))
  local library = library_of(tmp)
  local notes = fix.notes(tmp .. "/tree", {
    tmp .. "/tree/tools/paths/init.tl",
    tmp .. "/tree/tools/paths_test.tl",
    tmp .. "/outside.tl",
  }, { library })
  assert(#notes == 1, table.concat(notes, "\n"))
  assert(notes[1]:find(tmp .. "/tree/tools/paths/init.tl:5: Paths.which: Proc.find (cosmic.proc) " ..
      "stands in for `which`", 1, true) == 1, notes[1])
end

--- A file written with a class and an optional type is read by the new checker's tree, and a function of its exported
--- record is noted.
local function test_a_file_with_a_class_is_noted(tmp: string)
  assert(Fs.mkdirs(tmp .. "/tree/tools"))
  assert(Fs.write(tmp .. "/tree/tools/paths.tl", table.concat({
    "local class Stream",
    "  --- Reads.",
    "  function read(self, max: integer?): string?",
    "    return nil",
    "  end",
    "end",
    "",
    "local record Paths",
    "end",
    "",
    "--- Where a program is.",
    "function Paths.which(name: string): string?",
    "  return name",
    "end",
    "",
    "return Paths",
    "",
  }, "\n")))
  local notes = fix.notes(tmp .. "/tree", { tmp .. "/tree/tools/paths.tl" }, { library_of(tmp) })
  assert(#notes == 1, table.concat(notes, "\n"))
  local note = assert(notes[1])
  assert(note:find(tmp .. "/tree/tools/paths.tl:12: Paths.which: Proc.find (cosmic.proc) ", 1, true) == 1, note)
end

--- What a run keeps of a file's parse for the phases after it: its links' facts, its notes' candidates and its plurals, read
--- off the text as written, and the same file's notes by [`fix.notes`].
local function test_a_run_keeps_what_the_phases_after_the_parse_read(tmp: string)
  local text = table.concat({
    "local class Stream",
    "  --- Reads.",
    "  function read(self, max: integer?): string?",
    "    return nil",
    "  end",
    "end",
    "",
    "local record Paths",
    "end",
    "",
    "--- Where a program is.",
    "function Paths.which(name: string): string?",
    "  return #name .. \" tests\"",
    "end",
    "",
    "return Paths",
    "",
  }, "\n")
  local chunk = assert(SyntaxNode.parse(text, "build/paths.tl"))
  local facts: mut {string: links.Facts} = {}
  local ready: mut {string: {near.Candidate}} = {}
  local plurals: {string: tree_checks.Plurals} = {}
  fix.read_off("./build/paths.tl", chunk, text, facts, ready, plurals)
  assert(assert(facts["./build/paths.tl"]).source == text)
  local candidates = assert(ready["./build/paths.tl"])
  assert(#candidates == 1, #candidates)
  local candidate = assert(candidates[1])
  assert(candidate.source_symbol == "Paths.which" and candidate.line == 12 and candidate.text == "Where a program is.")
  local sites = assert(plurals["build/paths.tl"]).sites
  assert(#sites == 1)
  assert(assert(sites[1])[1] == "13")
  assert(Fs.mkdirs(tmp .. "/tree/build"))
  assert(Fs.write(tmp .. "/tree/build/paths.tl", text))
  local file = tmp .. "/tree/build/paths.tl"
  local noted = fix.notes(tmp .. "/tree", { file }, { library_of(tmp) })
  assert(#noted == 1, table.concat(noted, "\n"))
  assert(assert(noted[1]):find("build/paths.tl:12: Paths.which: Proc.find (cosmic.proc) ", 1, true) ~= nil, noted[1])
end
