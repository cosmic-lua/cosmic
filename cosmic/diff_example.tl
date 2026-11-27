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

--- A patch read back into files and hunks; `strip` drops leading path components as `patch -p` does.
function Example.parse()
  local text = "diff --git a/f.txt b/f.txt\n--- a/f.txt\n+++ b/f.txt\n@@ -1,2 +1,2 @@\n one\n-two\n+2\n"
  local files = assert(Diff.parse(text, { strip = 1 }))
  local file = assert(files[1])
  assert(file.kind == "modify" and file.old_name == "f.txt" and file.new_name == "f.txt")
  assert(#file.hunks == 1)
  local _, failure = Diff.parse("--- a\n+++ b\n@@ -1,2 +1,2 @@\n one\n")
  assert(failure ~= nil and failure.line == 3)
end

--- A patch applied to text that has moved: the result says how far each hunk sat from its header, and rejects a
--- hunk it cannot place instead of changing the text.
function Example.apply()
  local old = "a\nb\nc\nd\ne\n"
  local hunks = Diff.lines(old, "a\nb\nC\nd\ne\n", { context = 1 })
  local moved = Diff.apply("new first line\n" .. old, hunks)
  assert(moved.text == "new first line\na\nb\nC\nd\ne\n")
  assert(assert(moved.placed[1]).offset == 1)
  local other = Diff.apply("x\ny\nz\n", hunks)
  assert(other.text == nil and #other.rejects == 1)
  -- `fuzz` lets context lines at the ends of a hunk differ.
  local drifted = Diff.apply("a\nb\nc\nD\ne\n", hunks, { fuzz = 1 })
  assert(drifted.text == "a\nb\nC\nD\ne\n")
  assert(assert(drifted.placed[1]).fuzz == 1)
end

--- A patch that undoes another.
function Example.reverse()
  local hunks = Diff.lines("a\n", "b\n")
  local back = Diff.reverse(hunks)
  assert(Diff.apply("b\n", back).text == "a\n")
  assert(Diff.apply("b\n", hunks, { reverse = true }).text == "a\n")
end

return Example
