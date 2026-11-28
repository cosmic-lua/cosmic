--- Worked examples for [`cosmic.patch`], shown by `cosmic docs` under the
--- symbol each one demonstrates and run by `cosmic test` like any
--- other test -- see doc/design.md's `examples` table.

local Diff = require("cosmic.diff")
local Fs = require("cosmic.fs")
local Patch = require("cosmic.patch")

local record Example end

--- A git patch applied to a directory. `strip = 1` drops the `a/` and `b/` of its names; a hunk that does not fit would leave every file as it was.
function Example.apply()
  local dir = assert(Fs.mkdtemp("cosmic-patch-example-"))
  assert(Fs.write(dir .. "/greeting.txt", "hello\nworld\n"))
  local text = table.concat({
    "diff --git a/greeting.txt b/greeting.txt",
    "--- a/greeting.txt",
    "+++ b/greeting.txt",
    "@@ -1,2 +1,2 @@",
    " hello",
    "-world",
    "+cosmic",
    "",
  }, "\n")
  local entries = assert(Diff.parse(text, { strip = 1 }))
  local result = assert(Patch.apply(dir, entries))
  print(result.applied, assert(Fs.read(dir .. "/greeting.txt")))
  assert(result.applied and result.written)
  assert(assert(Fs.read(dir .. "/greeting.txt")) == "hello\ncosmic\n")
  -- the same patch undone
  assert(assert(Patch.apply(dir, entries, { reverse = true })).applied)
  assert(assert(Fs.read(dir .. "/greeting.txt")) == "hello\nworld\n")
  -- a name that leaves the directory is a failure, and nothing is written
  local bad = assert(Diff.parse("--- a/../x\n+++ b/../x\n@@ -1 +1 @@\n-a\n+b\n", { strip = 1 }))
  local refused, why = Patch.apply(dir, bad)
  assert(refused == nil and why.message:find("leaves the root", 1, true) ~= nil)
  assert(Fs.remove_tree(dir))
end

return Example
