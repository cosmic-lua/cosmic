--- Worked examples for [`cosmic.diff`], shown by `cosmic docs` under the
--- symbol each one demonstrates and run by `cosmic test` like any
--- other test -- see doc/design.md's `examples` table.

local Diff = require("cosmic.diff")

local record Example end

--- The hunks between two texts: each holds its changed lines and the unchanged lines around them.
function Example.lines()
  local hunks = Diff.lines("one\ntwo\nthree\n", "one\n2\nthree\n")
  assert(#hunks == 1)
  local h = assert(hunks[1])
  assert(h.old_start == 1 and h.old_count == 3 and h.new_count == 3)
  local ops: mut {string} = {}
  for _, l in ipairs(h.lines) do ops[#ops + 1] = l.op end
  assert(table.concat(ops, " ") == "context del add context")
  assert(#Diff.lines("same\n", "same\n") == 0)
  -- `context` sets the lines kept around a change.
  local none = Diff.lines("a\nb\nc\n", "a\nB\nc\n", { context = 0 })
  assert(#assert(none[1]).lines == 2)
end

--- A diff as the text `diff -u` and `patch` read.
function Example.unified()
  local text = Diff.unified(Diff.lines("a\nb\nc\n", "a\nB\nc\n"), { old_name = "a/f.txt", new_name = "b/f.txt" })
  print(text)
  assert(text == "--- a/f.txt\n+++ b/f.txt\n@@ -1,3 +1,3 @@\n a\n-b\n+B\n c\n")
  -- Equal texts give no text at all.
  assert(Diff.unified(Diff.lines("x\n", "x\n")) == "")
  -- A last line with no newline is marked.
  local open = Diff.unified(Diff.lines("a\n", "a"))
  assert(open == "--- a\n+++ b\n@@ -1 +1 @@\n-a\n+a\n\\ No newline at end of file\n")
end

return Example
