local Diff = require("cosmic.diff")

--- How many random texts each property draws.
local CASES <const> = 300

--- A generator of integers in [1, n], the same for a seed on every host.
local function drawer(seed: integer): function(integer): integer
  local state = seed
  return function(n: integer): integer
    state = (state * 1103515245 + 12345) % 2147483648
    return (state // 65536) % n + 1
  end
end

--- Text of up to `most` lines drawn from `kinds` distinct lines, with no final newline in a quarter of them.
local function text_of(draw: function(integer): integer, most: integer, kinds: integer): string
  local lines: mut {string} = {}
  for _ = 1, draw(most + 1) - 1 do lines[#lines + 1] = "line " .. tostring(draw(kinds)) end
  local body = table.concat(lines, "\n")
  if #lines > 0 and draw(4) > 1 then body = body .. "\n" end
  return body
end

--- The text the hunks and the lines of `old` outside them give.
local function applied(old: string, hunks: {Diff.Hunk}): string
  local lines: mut {string} = {}
  for line in old:gmatch("[^\n]*\n?") do
    if line ~= "" then lines[#lines + 1] = line end
  end
  local out: mut {string} = {}
  local at = 1
  for _, h in ipairs(hunks) do
    local first = if h.old_count == 0 then h.old_start + 1 else h.old_start end
    while at < first do
      out[#out + 1] = assert(lines[at])
      at = at + 1
    end
    for _, l in ipairs(h.lines) do
      if l.op ~= "add" then
        assert((lines[at] or ""):gsub("\n$", "") == l.text, "a kept or deleted line is the old one")
        at = at + 1
      end
      if l.op ~= "del" then
        out[#out + 1] = l.text .. (if l.no_newline == true then "" else "\n" end)
      end
    end
  end
  while at <= #lines do
    out[#out + 1] = assert(lines[at])
    at = at + 1
  end
  return table.concat(out)
end

--- The number of lines a shortest script adds and removes (lines with their `\n`), by dynamic programming.
local function shortest(old: string, new: string): integer
  local function split(text: string): {string}
    local out: mut {string} = {}
    for line in text:gmatch("[^\n]*\n?") do
      if line ~= "" then out[#out + 1] = line end
    end
    return out
  end
  local a, b = split(old), split(new)
  local prev: mut {integer: integer} = {}
  for j = 0, #b do prev[j + 1] = 0 end
  for i = 1, #a do
    local row: mut {integer: integer} = { [1] = 0 }
    for j = 1, #b do
      if a[i] == b[j] then
        row[j + 1] = (prev[j] or 0) + 1
      else
        row[j + 1] = math.max(prev[j + 1] or 0, row[j] or 0)
      end
    end
    prev = row
  end
  return #a + #b - 2 * (prev[#b + 1] or 0)
end

--- How many lines the hunks add and remove.
local function changes(hunks: {Diff.Hunk}): integer
  local n = 0
  for _, h in ipairs(hunks) do
    for _, l in ipairs(h.lines) do
      if l.op ~= "context" then n = n + 1 end
    end
  end
  return n
end

local function unified(old: string, new: string, opts?: Diff.Options): string
  return Diff.unified(Diff.lines(old, new, opts), { old_name = "a/f", new_name = "b/f" })
end

local function test_equal_texts_have_no_hunks()
  assert(#Diff.lines("", "") == 0)
  assert(#Diff.lines("a\nb\n", "a\nb\n") == 0)
  assert(Diff.unified(Diff.lines("a", "a")) == "")
end

-- The expected texts below are what GNU diff -u writes for the same files.
local function test_unified_text_is_what_gnu_diff_writes()
  assert(unified("a\n", "a\nb\n") == "--- a/f\n+++ b/f\n@@ -1 +1,2 @@\n a\n+b\n")
  assert(unified("", "a\nb\n") == "--- a/f\n+++ b/f\n@@ -0,0 +1,2 @@\n+a\n+b\n")
  assert(unified("a\nb\n", "") == "--- a/f\n+++ b/f\n@@ -1,2 +0,0 @@\n-a\n-b\n")
  assert(unified("1\n2\n3\n", "3\n") == "--- a/f\n+++ b/f\n@@ -1,3 +1 @@\n-1\n-2\n 3\n")
  assert(Diff.unified(Diff.lines("a\n", "b\n")) == "--- a\n+++ b\n@@ -1 +1 @@\n-a\n+b\n")
end

local function test_two_far_changes_make_two_hunks()
  local old = "a\nb\nc\nd\ne\nf\ng\nh\ni\nj\nk\nl\n"
  local new = "a\nB\nc\nd\ne\nf\ng\nh\ni\nj\nK\nl\nz"
  assert(unified(old, new) == "--- a/f\n+++ b/f\n@@ -1,5 +1,5 @@\n a\n-b\n+B\n c\n d\n e\n" ..
      "@@ -8,5 +8,6 @@\n h\n i\n j\n-k\n+K\n l\n+z\n\\ No newline at end of file\n")
  assert(#Diff.lines(old, new, { context = 3 }) == 2)
  assert(#Diff.lines(old, new, { context = 4 }) == 1, "changes within twice the context share a hunk")
end

local function test_a_missing_final_newline_is_a_change()
  assert(unified("x\ny", "x\ny\n") == "--- a/f\n+++ b/f\n@@ -1,2 +1,2 @@\n x\n-y\n\\ No newline at end of file\n+y\n")
  assert(unified("x\ny\n", "x\ny") == "--- a/f\n+++ b/f\n@@ -1,2 +1,2 @@\n x\n-y\n+y\n\\ No newline at end of file\n")
end

local function test_context_zero_has_only_changes()
  local hunks = Diff.lines("a\nb\nc\n", "a\nB\nc\n", { context = 0 })
  assert(#hunks == 1)
  local h = assert(hunks[1])
  assert(h.old_start == 2 and h.old_count == 1 and h.new_start == 2 and h.new_count == 1)
  assert(#h.lines == 2)
end

local function test_bad_options_raise()
  local ok, why = pcall(Diff.lines, "a", "b", { context = -1 })
  assert(not ok and tostring(why):find("context is -1", 1, true) ~= nil)
  ok, why = pcall(Diff.lines, "a", "b", { cost = 0 })
  assert(not ok and tostring(why):find("cost is 0", 1, true) ~= nil)
end

local function test_hunks_rebuild_the_new_text_and_are_shortest()
  local draw = drawer(7)
  for case = 1, CASES do
    local old = text_of(draw, 14, 1 + case % 5)
    local new = text_of(draw, 14, 1 + case % 5)
    local hunks = Diff.lines(old, new, { cost = 100000, context = draw(4) - 1 })
    assert(applied(old, hunks) == new, "case " .. tostring(case) .. " rebuilds the new text")
    assert(changes(hunks) == shortest(old, new), "case " .. tostring(case) .. " is a shortest script")
    for _, h in ipairs(hunks) do
      local o, n = 0, 0
      for _, l in ipairs(h.lines) do
        if l.op ~= "add" then o = o + 1 end
        if l.op ~= "del" then n = n + 1 end
      end
      assert(o == h.old_count and n == h.new_count, "a header counts its lines")
    end
  end
end

local function test_texts_that_share_little_still_rebuild_with_a_cost_cap()
  local draw = drawer(11)
  for _ = 1, 20 do
    local old = text_of(draw, 400, 1000)
    local new = text_of(draw, 400, 1000)
    local hunks = Diff.lines(old, new, { cost = 5 })
    assert(applied(old, hunks) == new)
  end
  local a: mut {string} = {}
  local b: mut {string} = {}
  for i = 1, 5000 do
    a[i] = "a" .. tostring(i) .. "\n"
    b[i] = "b" .. tostring(i) .. "\n"
  end
  local old, new = table.concat(a), table.concat(b)
  assert(applied(old, Diff.lines(old, new)) == new, "unrelated texts of 5000 lines")
end

local function test_hunk_text_keeps_a_carriage_return()
  local hunks = Diff.lines("a\r\nb\r\n", "a\r\nc\r\n")
  assert(#hunks == 1)
  local h = assert(hunks[1])
  assert(assert(h.lines[1]).text == "a\r")
end

local function test_a_low_cost_never_beats_the_shortest_script_and_sometimes_loses_to_it()
  local draw = drawer(5)
  local worse = 0
  for _ = 1, 40 do
    local old = text_of(draw, 300, 8)
    local new = text_of(draw, 300, 8)
    local best = changes(Diff.lines(old, new, { cost = 100000 }))
    local capped = changes(Diff.lines(old, new, { cost = 1 }))
    assert(capped >= best, "a capped search is never shorter than the shortest script")
    if capped > best then worse = worse + 1 end
  end
  assert(worse > 0, "a cost of 1 changes the script for some texts")
end

local function test_hunks_split_when_more_than_twice_the_context_separates_changes()
  -- Two changes with `gap` unchanged lines between them.
  local function hunks_for(gap: integer, context: integer): integer
    local old: mut {string} = { "a" }
    local new: mut {string} = { "A" }
    for i = 1, gap do
      old[#old + 1] = "m" .. tostring(i)
      new[#new + 1] = "m" .. tostring(i)
    end
    old[#old + 1] = "z"
    new[#new + 1] = "Z"
    return #Diff.lines(table.concat(old, "\n") .. "\n", table.concat(new, "\n") .. "\n", { context = context })
  end
  assert(hunks_for(6, 3) == 1)
  assert(hunks_for(7, 3) == 2)
  assert(hunks_for(0, 0) == 1)
  assert(hunks_for(1, 0) == 2)
end

local function test_a_huge_context_is_every_line()
  local old, new = "a\nb\nc\nd\ne\nf\ng\nh\ni\n", "A\nb\nc\nd\ne\nf\ng\nh\nI\n"
  local hunks = Diff.lines(old, new, { context = math.maxinteger })
  assert(#hunks == 1)
  assert(assert(hunks[1]).old_count == 9)
end

local function test_an_unchanged_last_line_with_no_newline_is_context()
  local hunks = Diff.lines("x\ny\nz", "X\ny\nz")
  assert(#hunks == 1)
  assert(Diff.unified(hunks) == "--- a\n+++ b\n@@ -1,3 +1,3 @@\n-x\n+X\n y\n z\n\\ No newline at end of file\n")
end

local function test_crlf_against_lf_is_a_change()
  assert(Diff.unified(Diff.lines("a\r\n", "a\n")) == "--- a\n+++ b\n@@ -1 +1 @@\n-a\r\n+a\n")
end
