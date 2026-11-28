--- Three-way merge and the small comparers of the diff family, in pure Teal: `diff3 -m`, `sdiff`, `cmp` and
--- `comm`. They sit on [`Diff.lines`], so a line is its bytes up to and including `\n`.
---
---     local merged = Merge.three("a\nb\nc\n", "a\nB\nc\n", "a\nb\nC\n")
---     -- merged.text == "a\nB\nC\n", merged.conflicts == 0
---
---     local at = Merge.compare("same\nfile\n", "same\nfine\n")
---     -- at.offset == 8, at.line == 2

local Diff = require("cosmic.diff")

local record Merge
  --- What [`Merge.three`] takes.
  record Options
    --- The name after `<<<<<<<` on a conflict, `ours` unless given.
    ours_name?: string
    --- The name after `>>>>>>>` on a conflict, `theirs` unless given.
    theirs_name?: string
  end

  --- What [`Merge.three`] returns.
  record Merged
    --- The merged text. A conflict is written between `<<<<<<<`, `=======` and `>>>>>>>` lines, as `diff3 -m` does.
    text: string
    --- How many conflicts the text holds; 0 is a clean merge.
    conflicts: integer
  end

  --- How two rows of [`Merge.rows`] relate.
  enum RowKind
    --- The line is the same on both sides.
    "same"
    --- A line of the old text was replaced by a line of the new text.
    "change"
    --- A line only the old text holds.
    "remove"
    --- A line only the new text holds.
    "add"
  end

  --- One row of a side-by-side comparison.
  record Row
    --- How the two sides relate.
    kind: RowKind
    --- The old line without its `\n`, nil for an added line.
    old?: string
    --- The new line without its `\n`, nil for a removed line.
    new?: string
    --- The old line's number from 1, nil for an added line.
    old_line?: integer
    --- The new line's number from 1, nil for a removed line.
    new_line?: integer
  end

  --- What [`Merge.sdiff`] takes.
  record SdiffOptions
    --- The width of a row, 130 unless given, as `sdiff -w`.
    width?: integer
    --- Leave out the rows of lines that are the same.
    suppress_common?: boolean
  end

  --- Where two texts first differ.
  record Difference
    --- The first byte that differs, from 1. When one text ends first, the byte after its end.
    offset: integer
    --- The line that byte is on, from 1.
    line: integer
    --- The byte's place in its line, from 1.
    column: integer
    --- True when one text is a prefix of the other.
    eof: boolean
  end

  --- One line of [`Merge.comm`].
  record Common
    --- 1 for a line only in the first list, 2 for one only in the second, 3 for one in both.
    column: integer
    --- The line.
    text: string
  end
end

--- `text` as lines with their `\n` kept; the last has none when the text does not end in one.
local function split(text: string): {string}
  local out: mut {string} = {}
  local at = 1
  local n = #text
  while at <= n do
    local stop = text:find("\n", at, true)
    if stop == nil then
      out[#out + 1] = text:sub(at)
      break
    end
    out[#out + 1] = text:sub(at, stop)
    at = stop + 1
  end
  return out
end

--- A run of base lines `[from, to)` replaced by `lines`.
local record Change
  from: integer
  to: integer
  lines: {string}
end

--- The line of a hunk as the text holds it.
local function raw(line: Diff.Line): string
  if line.no_newline == true then return line.text end
  return line.text .. "\n"
end

--- The changes that turn `base` into `side`, in order.
local function changes(base: string, side: string): {Change}
  local out: mut {Change} = {}
  for _, h in ipairs(Diff.lines(base, side, { context = 0 })) do
    local added: mut {string} = {}
    for _, l in ipairs(h.lines) do
      if l.op == "add" then added[#added + 1] = raw(l) end
    end
    local from = if h.old_count == 0 then h.old_start + 1 else h.old_start end
    out[#out + 1] = { from = from, to = from + h.old_count, lines = added }
  end
  return out
end

--- Whether a change ends in a line with no `\n`, so that nothing may be written right after it.
local function unended(c: Change): boolean
  local last = c.lines[#c.lines]
  return last ~= nil and last:sub(-1) ~= "\n"
end

--- Whether two changes touch the same base lines, begin at the same point, or meet where the first ends unended.
local function overlap(a: Change, b: Change): boolean
  return a.from == b.from or (a.from < b.to and b.from < a.to) or (a.to == b.from and unended(a)) or
    (b.to == a.from and unended(b))
end

--- `base[from, to)` appended to `out`.
local function copy(out: mut {string}, base: {string}, from: integer, to: integer)
  for k = from, to - 1 do
    local line = assert(base[k])
    out[#out + 1] = line
  end
end

--- The lines of `base[from, to)` as `group` leaves them.
local function render(base: {string}, group: {Change}, from: integer, to: integer): {string}
  local out: mut {string} = {}
  local at = from
  for _, c in ipairs(group) do
    copy(out, base, at, c.from)
    for _, line in ipairs(c.lines) do out[#out + 1] = line end
    at = c.to
  end
  copy(out, base, at, to)
  return out
end

--- Appends `lines` to `out`, ending the last with `\n` so that a marker may follow.
local function append_ended(out: mut {string}, lines: {string})
  for _, line in ipairs(lines) do out[#out + 1] = line end
  local last = lines[#lines]
  if last ~= nil and last:sub(-1) ~= "\n" then
    table.remove(out)
    out[#out + 1] = last .. "\n"
  end
end

--- Merges `ours` and `theirs`, two changes of `base`: a change only one side makes is kept; a change both make
--- the same way is made once; a place both change in different ways is a conflict, written out as `diff3 -m`
--- does. Two changes that only touch (one ends on the line where the other starts) are not a conflict.
---
---     local merged = Merge.three("1\n2\n3\n", "1\ntwo\n3\n", "1\ndeux\n3\n", { theirs_name = "fr" })
---     -- "1\n<<<<<<< ours\ntwo\n=======\ndeux\n>>>>>>> fr\n3\n", with one conflict
--- @param base string The text both sides began as
--- @param ours string The first side
--- @param theirs string The second side
--- @param opts? Merge.Options The names written on a conflict
--- @return Merge.Merged The text and the number of conflicts
function Merge.three(base: string, ours: string, theirs: string, opts?: Merge.Options): Merge.Merged
  local lines = split(base)
  local mine, yours = changes(base, ours), changes(base, theirs)
  local open = "<<<<<<< " .. ((opts and opts.ours_name) or "ours") .. "\n"
  local close = ">>>>>>> " .. ((opts and opts.theirs_name) or "theirs") .. "\n"
  local out: mut {string} = {}
  local at, i, j, conflicts = 1, 1, 1, 0
  while i <= #mine or j <= #yours do
    local a, b = mine[i], yours[j]
    if a ~= nil and (b == nil or (a.from <= b.from and not overlap(a, b))) then
      copy(out, lines, at, a.from)
      for _, line in ipairs(a.lines) do out[#out + 1] = line end
      at, i = a.to, i + 1
    elseif b ~= nil and (a == nil or not overlap(a, b)) then
      copy(out, lines, at, b.from)
      for _, line in ipairs(b.lines) do out[#out + 1] = line end
      at, j = b.to, j + 1
    else
      local first, last = assert(a), assert(b)
      local from, to = math.min(first.from, last.from), math.max(first.to, last.to)
      local mine_group: mut {Change} = { first }
      local yours_group: mut {Change} = { last }
      i, j = i + 1, j + 1
      local grew = true
      while grew do
        grew = false
        local next_a, next_b = mine[i], yours[j]
        if next_a ~= nil and next_a.from < to then
          mine_group[#mine_group + 1] = next_a
          to, i, grew = math.max(to, next_a.to), i + 1, true
        end
        if next_b ~= nil and next_b.from < to then
          yours_group[#yours_group + 1] = next_b
          to, j, grew = math.max(to, next_b.to), j + 1, true
        end
      end
      copy(out, lines, at, from)
      local left, right = render(lines, mine_group, from, to), render(lines, yours_group, from, to)
      local left_text, right_text = table.concat(left), table.concat(right)
      if left_text == right_text then
        for _, line in ipairs(left) do out[#out + 1] = line end
      else
        conflicts = conflicts + 1
        out[#out + 1] = open
        append_ended(out, left)
        out[#out + 1] = "=======\n"
        append_ended(out, right)
        out[#out + 1] = close
      end
      at = to
    end
  end
  copy(out, lines, at, #lines + 1)
  return { text = table.concat(out), conflicts = conflicts }
end

--- The two texts as rows, one for each line of either, as `sdiff` pairs them: a run of removed lines meeting a
--- run of added ones is a run of changes, then the rest of the longer run.
---
---     local rows = Merge.rows("a\nb\n", "a\nB\nc\n")
---     -- same a/a, change b/B, add c
--- @param old string The first text
--- @param new string The second text
--- @return {Merge.Row} The rows, in order
function Merge.rows(old: string, new: string): {Merge.Row}
  local rows: mut {Merge.Row} = {}
  local old_lines, new_lines = split(old), split(new)
  local function bare(line: string): string
    if line:byte(-1) == 10 then return line:sub(1, -2) end
    return line
  end
  local old_at, new_at = 1, 1
  local function same(count: integer)
    for _ = 1, count do
      local row: Merge.Row = { kind = "same", old = bare(assert(old_lines[old_at])), new = bare(assert(new_lines[new_at])),
        old_line = old_at, new_line = new_at }
      rows[#rows + 1] = row
      old_at, new_at = old_at + 1, new_at + 1
    end
  end
  for _, h in ipairs(Diff.lines(old, new, { context = 0 })) do
    local first_old = if h.old_count == 0 then h.old_start + 1 else h.old_start end
    same(first_old - old_at)
    local removed: mut {string} = {}
    local added: mut {string} = {}
    for _, l in ipairs(h.lines) do
      if l.op == "del" then
        removed[#removed + 1] = l.text
      elseif l.op == "add" then
        added[#added + 1] = l.text
      end
    end
    for k = 1, math.max(#removed, #added) do
      local gone, came = removed[k], added[k]
      local kind: Merge.RowKind = if gone ~= nil and came ~= nil then "change" elseif gone ~= nil then "remove" else "add" end
      rows[#rows + 1] = {
        kind = kind,
        old = gone,
        new = came,
        old_line = if gone ~= nil then old_at else nil end,
        new_line = if came ~= nil then new_at else nil end,
      }
      if gone ~= nil then old_at = old_at + 1 end
      if came ~= nil then new_at = new_at + 1 end
    end
  end
  same(#old_lines - old_at + 1)
  return rows
end

--- `text` cut or padded to `width` columns.
local function fitted(text: string?, width: integer): string
  local whole = text or ""
  if whole:find("\t", 1, true) ~= nil then whole = whole:gsub("\t", " ") end
  local shown = whole:sub(1, width)
  return shown .. (" "):rep(width - #shown)
end

--- The texts side by side, as `sdiff` writes them: the old line, a mark (` ` same, `|` change, `<` removed, `>`
--- added), the new line.
---
---     print(Merge.sdiff("a\nb\n", "a\nB\n", { width = 20 }))
--- @param old string The first text
--- @param new string The second text
--- @param opts? Merge.SdiffOptions Width and suppression of common lines
--- @return string One line for each row, every one ending in `\n`
function Merge.sdiff(old: string, new: string, opts?: Merge.SdiffOptions): string
  local width = (opts and opts.width) or 130
  local half = math.max((width - 3) // 2, 1)
  local marks: {Merge.RowKind: string} = { same = " ", change = "|", remove = "<", add = ">" }
  local out: mut {string} = {}
  for _, row in ipairs(Merge.rows(old, new)) do
    if row.kind ~= "same" or not ((opts and opts.suppress_common) == true) then
      local line = fitted(row.old, half) .. " " .. assert(marks[row.kind]) .. " " .. fitted(row.new, half)
      local stop = #line
      while stop > 0 and line:byte(stop) == 32 do stop = stop - 1 end
      out[#out + 1] = line:sub(1, stop) .. "\n"
    end
  end
  return table.concat(out)
end

--- Where two texts first differ, as `cmp` finds it, or nil when they are the same.
---
---     local at = Merge.compare("abc\n", "abd\n")
---     -- at.offset == 3, at.line == 1, at.column == 3
--- @param a string The first text
--- @param b string The second text
--- @return Merge.Difference? The first difference
function Merge.compare(a: string, b: string): Merge.Difference?
  if a == b then return nil end
  local shorter = math.min(#a, #b)
  local at = 1
  local step = 4096
  while at <= shorter and a:sub(at, at + step - 1) == b:sub(at, at + step - 1) do at = at + step end
  local from = math.min(at, shorter + 1)
  while from <= shorter and a:byte(from) == b:byte(from) do from = from + 1 end
  local offset = from
  local line, start = 1, 1
  local lines_before = 0
  while true do
    local stop = a:find("\n", start, true)
    if stop == nil or stop >= offset then break end
    lines_before, start = lines_before + 1, stop + 1
  end
  line = lines_before + 1
  return { offset = offset, line = line, column = offset - start + 1, eof = offset > shorter }
end

--- Two sorted lists of lines compared as `comm` does: each line only in the first list, only in the second, or
--- in both, in order. Lines are compared by bytes, so sort them the same way (`LC_ALL=C sort`).
---
---     local rows = Merge.comm({ "a", "b", "d" }, { "b", "c", "d" })
---     -- column 1 "a", 3 "b", 2 "c", 3 "d"
--- @param a {string} The first list, sorted
--- @param b {string} The second list, sorted
--- @return {Merge.Common} One row for each distinct step through the lists
function Merge.comm(a: {string}, b: {string}): {Merge.Common}
  local out: mut {Merge.Common} = {}
  local i, j = 1, 1
  while i <= #a or j <= #b do
    local x, y = a[i], b[j]
    if x ~= nil and (y == nil or x < y) then
      out[#out + 1] = { column = 1, text = x }
      i = i + 1
    elseif y ~= nil and (x == nil or y < x) then
      out[#out + 1] = { column = 2, text = y }
      j = j + 1
    else
      out[#out + 1] = { column = 3, text = assert(x) }
      i, j = i + 1, j + 1
    end
  end
  return out
end

return Merge
