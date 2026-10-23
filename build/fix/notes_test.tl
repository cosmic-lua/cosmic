--- What `cosmic fix` notes of a fixed file beside fixing it
--- (build/fix/fix_test.tl holds the fixing), against a standard library
--- of the test's own, built by [`build.docs_fixture`].

local Fs = require("cosmic.fs")
local ast = require("build.ast")
local Sqlite = require("cosmic.sqlite")
local fix = require("build.fix")
local fixture = require("build.docs_fixture")
local GrammarMode = require("build.grammar_mode")
local near = require("build.fix.near")
local teal = require("build.teal")
local tree_checks = require("build.tree_checks")

local built = assert(teal.load())

--- The checkers that read the files for the notes.
local MODES: {GrammarMode.Mode} = { "teal", "new" }

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
--- line; a test file, and a file outside the tree, earn nothing. The
--- new checker's reading ([`build.syntax_analyzer`]) notes the same.
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
  for _, mode in ipairs(MODES) do
    local notes = fix.notes(built, tmp .. "/tree", {
      tmp .. "/tree/tools/paths/init.tl",
      tmp .. "/tree/tools/paths_test.tl",
      tmp .. "/outside.tl",
    }, { library }, nil, mode)
    assert(#notes == 1, mode .. ": " .. table.concat(notes, "\n"))
    assert(notes[1]:find(tmp .. "/tree/tools/paths/init.tl:5: Paths.which: Proc.find (cosmic.proc) " ..
        "stands in for `which`", 1, true) == 1, notes[1])
  end
end

--- A file written in the new grammar (a class, an optional type) is read by the new checker's tree, and a function of
--- its exported record is noted as the fork's reading notes it.
local function test_a_file_in_the_new_grammar_is_noted_by_the_new_checker(tmp: string)
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
  local notes = fix.notes(built, tmp .. "/tree", { tmp .. "/tree/tools/paths.tl" }, { library_of(tmp) }, nil, "new")
  assert(#notes == 1, table.concat(notes, "\n"))
  local note = assert(notes[1])
  assert(note:find(tmp .. "/tree/tools/paths.tl:12: Paths.which: Proc.find (cosmic.proc) ", 1, true) == 1, note)
end

--- What a run keeps of a file's parse for the phases after it: its notes' candidates and, for a file the tree checks
--- read, its plurals. In the new grammar mode both are read off the new checker's tree of the fixed text, and agree with the
--- fork's reading of the same file.
local function test_a_run_keeps_the_candidates_and_plurals_of_a_file_in_either_mode()
  local text = table.concat({
    "local record Paths",
    "end",
    "",
    "--- Where a program is.",
    "function Paths.which(name: string): string",
    "  return #name .. \" tests\"",
    "end",
    "",
    "return Paths",
    "",
  }, "\n")
  local result = assert(fix.source(built, text, "build/paths.tl"))
  local function kept(mode: GrammarMode.Mode): string
    local ready: {string: {near.Candidate}} = {}
    local plurals: {string: tree_checks.Plurals} = {}
    fix.read_off("build/paths.tl", result, mode, {}, ready, plurals)
    local candidates = assert(ready["build/paths.tl"])
    assert(#candidates == 1, mode)
    local candidate = assert(candidates[1])
    local sites = assert(plurals["build/paths.tl"]).sites
    assert(#sites == 1, mode)
    return candidate.source_symbol .. "|" .. tostring(candidate.line) .. "|" .. candidate.text .. "|" ..
      table.concat(assert(sites[1]), "|")
  end
  local forked, new = kept("teal"), kept("new")
  assert(forked == new, forked .. " against " .. new)
  assert(new:find("Paths.which|5|Where a program is.|6|tests|", 1, true) == 1, new)
end

--- The kept reading follows the mode: given a fixed text whose fork parse says nothing (an empty file's), the fork's mode
--- keeps no candidate and no plural and the new grammar mode keeps those of the text itself, which only its reader reads.
local function test_the_kept_reading_is_the_new_checkers_in_the_new_mode()
  local text = table.concat({
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
  local result: fix.Fixed = { source = text, changed = false,
    parsed = assert(ast.parse(built, "return 1\n", "build/paths.tl")) }
  local function kept(mode: GrammarMode.Mode): integer, integer
    local ready: {string: {near.Candidate}} = {}
    local plurals: {string: tree_checks.Plurals} = {}
    fix.read_off("build/paths.tl", result, mode, {}, ready, plurals)
    local candidates = ready["build/paths.tl"]
    local counted = plurals["build/paths.tl"]
    return candidates ~= nil and #candidates or -1, counted ~= nil and #counted.sites or -1
  end
  local forked_candidates, forked_sites = kept("teal")
  assert(forked_candidates == 0 and forked_sites == 0, tostring(forked_candidates) .. " " .. tostring(forked_sites))
  local new_candidates, new_sites = kept("new")
  assert(new_candidates == 1 and new_sites == 1, tostring(new_candidates) .. " " .. tostring(new_sites))
end
