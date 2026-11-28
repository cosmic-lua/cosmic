--- Worked examples for [`cosmic.merge`], shown by `cosmic docs` under the
--- symbol each one demonstrates and run by `cosmic test` like any
--- other test -- see doc/design.md's `examples` table.

local Merge = require("cosmic.merge")

local record Example end

--- Two edits of one text, in different places, merge without a conflict; a place both edit differently is written out with markers.
function Example.three()
  local clean = Merge.three("a\nb\nc\n", "a\nB\nc\n", "a\nb\nC\n")
  print(clean.text, clean.conflicts)
  assert(clean.text == "a\nB\nC\n" and clean.conflicts == 0)
  local clash = Merge.three("1\n2\n3\n", "1\ntwo\n3\n", "1\ndeux\n3\n", { theirs_name = "fr" })
  assert(clash.conflicts == 1)
  assert(clash.text == "1\n<<<<<<< ours\ntwo\n=======\ndeux\n>>>>>>> fr\n3\n")
end

--- The rows of a side-by-side comparison: lines that are the same, replaced, removed or added.
function Example.rows()
  local rows = Merge.rows("a\nb\n", "a\nB\nc\n")
  for _, row in ipairs(rows) do print(row.kind, row.old, row.new) end
  assert(#rows == 3 and assert(rows[2]).kind == "change" and assert(rows[3]).kind == "add")
end

--- The same rows written as `sdiff` does, with a mark between the columns.
function Example.sdiff()
  local text = Merge.sdiff("a\nb\n", "a\nB\n", { width = 11 })
  print(text)
  assert(text == "a      a\nb    | B\n")
end

--- Where two texts first differ, as `cmp` finds it.
function Example.compare()
  local at = assert(Merge.compare("same\nfile\n", "same\nfine\n"))
  print(at.offset, at.line, at.column)
  assert(at.offset == 8 and at.line == 2 and at.column == 3)
  assert(Merge.compare("x\n", "x\n") == nil)
end

--- Two sorted lists split into the lines only in the first, only in the second and in both, as `comm` does.
function Example.comm()
  local rows = Merge.comm({ "a", "b", "d" }, { "b", "c", "d" })
  for _, row in ipairs(rows) do print(row.column, row.text) end
  assert(#rows == 4 and assert(rows[1]).column == 1 and assert(rows[2]).column == 3)
end

return Example
