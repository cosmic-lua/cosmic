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

local function test_parse_reads_back_what_unified_writes()
  local draw = drawer(21)
  for _ = 1, CASES do
    local old, new = text_of(draw, 40, 6), text_of(draw, 40, 6)
    local text = Diff.unified(Diff.lines(old, new), { old_name = "a/f", new_name = "b/f" })
    local files = assert(Diff.parse(text, { strip = 1 }))
    if text == "" then
      assert(#files == 0)
    else
      assert(#files == 1)
      local f = assert(files[1])
      assert(f.old_name == "f" and f.new_name == "f" and f.kind == "modify")
      assert(Diff.unified(f.hunks, { old_name = "a/f", new_name = "b/f" }) == text)
    end
  end
end

local function test_parse_reads_git_headers()
  local text = table.concat({
    "From abc Mon Sep 17 00:00:00 2001",
    "Subject: a message that is skipped",
    "",
    "diff --git a/new.txt b/new.txt",
    "new file mode 100644",
    "index 0000000..e69de29",
    "--- /dev/null",
    "+++ b/new.txt",
    "@@ -0,0 +1,2 @@",
    "+one",
    "+two",
    "diff --git a/gone.txt b/gone.txt",
    "deleted file mode 100755",
    "--- a/gone.txt",
    "+++ /dev/null",
    "@@ -1 +0,0 @@",
    "-bye",
    "diff --git a/x b/y",
    "similarity index 100%",
    "rename from x",
    "rename to y",
    "diff --git a/run.sh b/run.sh",
    "old mode 100644",
    "new mode 100755",
    "",
  }, "\n")
  local files = assert(Diff.parse(text, { strip = 1 }))
  assert(#files == 4)
  local created, deleted, renamed, moded = assert(files[1]), assert(files[2]), assert(files[3]), assert(files[4])
  assert(created.kind == "create" and created.old_name == nil and created.new_name == "new.txt")
  assert(created.new_mode == "100644" and #created.hunks == 1)
  assert(assert(created.hunks[1]).new_count == 2)
  assert(deleted.kind == "delete" and deleted.new_name == nil and deleted.old_mode == "100755")
  assert(renamed.kind == "rename" and renamed.old_name == "x" and renamed.new_name == "y" and #renamed.hunks == 0)
  assert(moded.kind == "modify" and moded.old_mode == "100644" and moded.new_mode == "100755")
end

local function test_parse_refuses_what_it_cannot_read()
  local function why(text: string): string
    local files, failure = Diff.parse(text)
    assert(files == nil)
    return tostring(failure)
  end
  assert(why("--- a\n+++ b\n@@ -1,2 +1,2 @@\n a\n"):find("ends before its counts", 1, true) ~= nil)
  assert(why("--- a\n+++ b\n@@ -1 +1 @@\n-a\n-b\n+c\n"):find("more lines than its counts", 1, true) ~= nil)
  assert(why("--- a\n+++ b\n@@ nonsense @@\n"):find("hunk header", 1, true) ~= nil)
  assert(why("@@ -1 +1 @@\n-a\n+b\n"):find("before any file", 1, true) ~= nil)
  assert(why("diff --git a/x b/x\nBinary files a/x and b/x differ\n"):find("binary", 1, true) ~= nil)
  assert(why("--- \"a\\tb\"\n+++ \"b\"\n@@ -1 +1 @@\n-a\n+b\n"):find("quoted", 1, true) ~= nil)
  local _, failure = Diff.parse("--- a\n+++ b\n@@ -1,2 +1,2 @@\n a\n")
  assert(failure ~= nil and failure.line == 3)
end

local function test_apply_makes_the_new_text_and_reverse_makes_the_old()
  local draw = drawer(33)
  for _ = 1, CASES do
    local old, new = text_of(draw, 60, 8), text_of(draw, 60, 8)
    local hunks = Diff.lines(old, new, { context = draw(4) - 1 })
    local forward = Diff.apply(old, hunks)
    assert(forward.text == new and #forward.rejects == 0)
    for _, p in ipairs(forward.placed) do assert(p.offset == 0 and p.fuzz == 0) end
    assert(Diff.apply(new, hunks, { reverse = true }).text == old)
    assert(Diff.apply(new, Diff.reverse(hunks)).text == old)
  end
end

local function test_apply_finds_a_hunk_that_moved()
  local old = "a\nb\nc\nd\ne\nf\ng\n"
  local hunks = Diff.lines(old, "a\nb\nc\nD\ne\nf\ng\n", { context = 2 })
  local moved = "x\ny\nz\n" .. old
  local result = Diff.apply(moved, hunks)
  assert(result.text == "x\ny\nz\na\nb\nc\nD\ne\nf\ng\n")
  assert(assert(result.placed[1]).offset == 3)
  local earlier = Diff.apply("b\nc\nd\ne\nf\ng\n", hunks)
  assert(earlier.text == "b\nc\nD\ne\nf\ng\n")
  assert(assert(earlier.placed[1]).offset == -1)
end

local function test_apply_uses_fuzz_only_when_allowed()
  local hunks = Diff.lines("a\nb\nc\nd\ne\n", "a\nb\nC\nd\ne\n", { context = 2 })
  local drifted = "A\nb\nc\nd\nE\n"
  local strict = Diff.apply(drifted, hunks)
  assert(strict.text == nil and #strict.rejects == 1)
  assert(assert(strict.rejects[1]).index == 1 and #assert(strict.rejects[1]).hunk.lines > 0)
  local loose = Diff.apply(drifted, hunks, { fuzz = 1 })
  assert(loose.text == "A\nb\nC\nd\nE\n")
  assert(assert(loose.placed[1]).fuzz == 1)
  assert(Diff.apply("A\nB\nc\nD\nE\n", hunks, { fuzz = 1 }).text == nil)
  assert(Diff.apply("A\nB\nc\nD\nE\n", hunks, { fuzz = 2 }).text == "A\nB\nC\nD\nE\n")
end

local function test_a_file_changes_whole_or_not_at_all()
  local old = "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n"
  local new = "1\nTWO\n3\n4\n5\n6\n7\n8\n9\n10\nELEVEN\n12\n"
  local hunks = Diff.lines(old, new, { context = 1 })
  assert(#hunks == 2)
  local result = Diff.apply("1\n2\n3\n4\n5\n6\n7\n8\n9\n10\nchanged\n12\n", hunks)
  assert(result.text == nil)
  assert(#result.placed == 1 and assert(result.placed[1]).index == 1)
  assert(#result.rejects == 1 and assert(result.rejects[1]).index == 2)
  assert(result.rejects[1].message:find("hunk 2", 1, true) ~= nil)
end

local function test_apply_keeps_a_missing_final_newline_exact()
  local hunks = Diff.lines("a\nb", "a\nB")
  assert(Diff.apply("a\nb", hunks).text == "a\nB")
  assert(Diff.apply("a\nb\n", hunks).text == nil, "the old text ends in a newline the patch lacks")
end

local function test_apply_to_and_from_an_empty_text()
  local made = Diff.lines("", "a\nb\n")
  assert(Diff.apply("", made).text == "a\nb\n")
  assert(Diff.apply("a\nb\n", made, { reverse = true }).text == "")
end

local function test_a_parsed_patch_applies()
  local old = "one\ntwo\nthree\nfour\n"
  local new = "one\n2\nthree\nfour\nfive\n"
  local text = Diff.unified(Diff.lines(old, new), { old_name = "a/f", new_name = "b/f" })
  local files = assert(Diff.parse(text, { strip = 1 }))
  assert(Diff.apply(old, assert(files[1]).hunks).text == new)
end

local function test_bad_apply_options_raise()
  local ok, why = pcall(function(): Diff.Applied
    return Diff.apply("a\n", {}, { fuzz = -1 })
  end)
  assert(not ok and tostring(why):find("fuzz is -1", 1, true) ~= nil)
  local ok2, why2 = pcall(function(): {Diff.Entry}
    return assert(Diff.parse("", { strip = -1 }))
  end)
  assert(not ok2 and tostring(why2):find("strip is -1", 1, true) ~= nil)
end

local function test_a_hunk_at_an_end_of_the_text_stays_there()
  local start = Diff.lines("a\nc1\nc2\nc3\n", "A\nc1\nc2\nc3\n")
  assert(Diff.apply("x\ny\na\nc1\nc2\nc3\n", start).text == nil, "a change on the first line is not found later")
  assert(Diff.apply("a\nc1\nc2\nc3\n", start).text == "A\nc1\nc2\nc3\n")
  local finish = Diff.lines("c1\nc2\nc3\nz\n", "c1\nc2\nc3\n")
  assert(Diff.apply("c1\nc2\nc3\nz\nM\nc1\nc2\nc3\nz\nQ\n", finish).text == nil, "nor is a change on the last line")
  assert(Diff.apply("M\nc1\nc2\nc3\nz\n", finish).text == "M\nc1\nc2\nc3\n")
end

local function test_parse_keeps_rename_paths_with_strip()
  local files = assert(Diff.parse("diff --git a/src/x b/src/y\nrename from src/x\nrename to src/y\n", { strip = 1 }))
  local f = assert(files[1])
  assert(f.kind == "rename" and f.old_name == "src/x" and f.new_name == "src/y")
end

local function test_parse_refuses_lines_past_the_counts()
  local _, failure = Diff.parse("--- a\n+++ b\n@@ -1,2 +1,2 @@\n a\n-b\n+B\n c\n")
  assert(failure ~= nil and failure.line == 7)
  -- A mail signature follows the patch.
  local signed = assert(Diff.parse("--- a\n+++ b\n@@ -1 +1 @@\n-a\n+b\n-- \n2.40.0\n"))
  assert(#signed == 1)
  local two = assert(Diff.parse("--- a\n+++ b\n@@ -1 +1 @@\n-a\n+b\n--- c\n+++ d\n@@ -1 +1 @@\n-c\n+d\n"))
  assert(#two == 2)
end

local function test_parse_names_an_empty_create_and_delete_once()
  local made = assert(Diff.parse("diff --git a/e b/e\nnew file mode 100644\nindex 0000000..e69de29\n"))
  assert(assert(made[1]).kind == "create" and assert(made[1]).old_name == nil and assert(made[1]).new_name == "b/e")
  local gone = assert(Diff.parse("diff --git a/e b/e\ndeleted file mode 100644\n"))
  assert(assert(gone[1]).kind == "delete" and assert(gone[1]).new_name == nil and assert(gone[1]).old_name == "a/e")
end

local function test_parse_reads_a_patch_with_crlf_line_ends()
  local text = "--- a/f\r\n+++ b/f\r\n@@ -1 +1 @@\r\n-x\r\n+y\r\n"
  local files = assert(Diff.parse(text, { strip = 1 }))
  local f = assert(files[1])
  assert(f.old_name == "f" and f.new_name == "f")
  assert(assert(assert(f.hunks[1]).lines[1]).text == "x\r", "a hunk line keeps its carriage return")
end

local function test_a_quoted_word_in_a_message_is_not_a_file_name()
  local files = assert(Diff.parse("diff --git a/x b/y\nrename from x\nthe \"fix\" is here\nrename to y\n"))
  assert(#files == 1)
end
