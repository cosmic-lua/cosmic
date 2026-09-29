--- What `cosmic fix` notes of a fixed file beside fixing it
--- (build/fix/fix_test.tl holds the fixing), against a standard library
--- of the test's own, built by `build.docs_fixture`.

local Fs = require("cosmic.fs")
local fix = require("build.fix")
local fixture = require("build.docs_fixture")
local teal = require("build.teal")

local built = assert(teal.load())

--- `fix.notes` reads each fixed file's exported functions and notes the
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
  assert(Fs.mkdirs(tmp .. "/library"))
  local library = fixture.database(tmp .. "/library", {
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
  local notes = fix.notes(built, tmp .. "/tree", {
    tmp .. "/tree/tools/paths/init.tl",
    tmp .. "/tree/tools/paths_test.tl",
    tmp .. "/outside.tl",
  }, { library })
  assert(#notes == 1, table.concat(notes, "\n"))
  assert(notes[1]:find(tmp .. "/tree/tools/paths/init.tl:5: Paths.which: Proc.find (cosmic.proc) " ..
    "stands in for `which`", 1, true) == 1, notes[1])
end
