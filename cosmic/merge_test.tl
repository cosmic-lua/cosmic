local Bench = require("cosmic.bench")
local Merge = require("cosmic.merge")

--- A generator of integers in [1, n], the same for a seed on every host.
local function drawer(seed: integer): function(integer): integer
  local state = seed
  return function(n: integer): integer
    state = (state * 1103515245 + 12345) % 2147483648
    return (state // 65536) % n + 1
  end
end

local function lines_of(text: string): {string}
  local out: mut {string} = {}
  for line in text:gmatch("[^\n]*\n") do out[#out + 1] = line end
  return out
end

local function test_a_side_that_did_not_change_gives_the_other()
  local base, x = "a\nb\nc\n", "a\nB\nc\nd\n"
  local one, two, three = Merge.three(base, x, base), Merge.three(base, base, x), Merge.three(base, x, x)
  assert(one.text == x and one.conflicts == 0)
  assert(two.text == x and two.conflicts == 0)
  assert(three.text == x and three.conflicts == 0, "the same change on both sides is made once")
end

local function test_changes_in_different_places_both_land()
  local merged = Merge.three("a\nb\nc\nd\ne\n", "a\nB\nc\nd\ne\n", "a\nb\nc\nd\nE\n")
  assert(merged.text == "a\nB\nc\nd\nE\n" and merged.conflicts == 0)
end

local function test_a_clash_is_written_as_diff3_does()
  local merged = Merge.three("1\n2\n3\n", "1\ntwo\n3\n", "1\ndeux\n3\n", { theirs_name = "fr" })
  assert(merged.conflicts == 1)
  assert(merged.text == "1\n<<<<<<< ours\ntwo\n=======\ndeux\n>>>>>>> fr\n3\n", merged.text)
end

local function test_a_missing_final_newline_gets_one_before_a_marker()
  local merged = Merge.three("a\nb", "a\nx", "a\ny")
  assert(merged.conflicts == 1)
  assert(merged.text == "a\n<<<<<<< ours\nx\n=======\ny\n>>>>>>> theirs\n", merged.text)
end

local function test_two_inserts_at_one_place_clash_unless_equal()
  local clash = Merge.three("a\nb\n", "a\nx\nb\n", "a\ny\nb\n")
  assert(clash.conflicts == 1 and clash.text == "a\n<<<<<<< ours\nx\n=======\ny\n>>>>>>> theirs\nb\n", clash.text)
  local same = Merge.three("a\nb\n", "a\nx\nb\n", "a\nx\nb\n")
  assert(same.conflicts == 0 and same.text == "a\nx\nb\n")
end

local function test_changes_that_only_touch_do_not_clash()
  -- ours changes line 2, theirs inserts before line 3: the first ends where the second starts
  local merged = Merge.three("a\nb\nc\n", "a\nB\nc\n", "a\nb\nnew\nc\n")
  assert(merged.conflicts == 0 and merged.text == "a\nB\nnew\nc\n", merged.text)
end

local function test_a_change_inside_a_deleted_run_clashes()
  local merged = Merge.three("a\nb\nc\nd\n", "a\nd\n", "a\nb\nC\nd\n")
  assert(merged.conflicts == 1)
  assert(merged.text == "a\n<<<<<<< ours\n=======\nb\nC\n>>>>>>> theirs\nd\n", merged.text)
end

local function test_edits_on_alternate_lines_merge_to_both()
  local draw = drawer(7)
  for _ = 1, 200 do
    local n = draw(24)
    local base: mut {string} = {}
    local ours: mut {string} = {}
    local theirs: mut {string} = {}
    local want: mut {string} = {}
    for k = 1, n do
      local line = "l" .. tostring(k) .. "\n"
      local mine, yours = line, line
      local both = line
      if k % 4 == 1 and draw(2) == 1 then mine, both = "mine " .. line, "mine " .. line end
      if k % 4 == 3 and draw(2) == 1 then yours, both = "your " .. line, "your " .. line end
      base[#base + 1], ours[#ours + 1], theirs[#theirs + 1], want[#want + 1] = line, mine, yours, both
    end
    local merged = Merge.three(table.concat(base), table.concat(ours), table.concat(theirs))
    assert(merged.conflicts == 0 and merged.text == table.concat(want), merged.text)
  end
end

local function test_rows_pair_removed_with_added_lines()
  local rows = Merge.rows("a\nb\nc\n", "a\nB\nB2\nc\n")
  local kinds: mut {string} = {}
  for _, row in ipairs(rows) do kinds[#kinds + 1] = row.kind end
  assert(table.concat(kinds, ",") == "same,change,add,same", table.concat(kinds, ","))
  local change = assert(rows[2])
  assert(change.old == "b" and change.new == "B" and change.old_line == 2 and change.new_line == 2)
  local added = assert(rows[3])
  assert(added.old == nil and added.new == "B2" and added.old_line == nil and added.new_line == 3)
  assert(assert(rows[4]).old_line == 3 and assert(rows[4]).new_line == 4)
  assert(#Merge.rows("", "") == 0)
end

local function test_sdiff_marks_each_row()
  local text = Merge.sdiff("a\nb\nc\n", "a\nB\nc\nd\n", { width = 11 })
  assert(text == "a      a\nb    | B\nc      c\n     > d\n", text)
  local only = Merge.sdiff("a\nb\nc\n", "a\nB\nc\n", { width = 11, suppress_common = true })
  assert(only == "b    | B\n", only)
  assert(Merge.sdiff("x\n", "", { width = 11 }) == "x    <\n")
end

local function test_compare_finds_the_first_difference()
  assert(Merge.compare("same\n", "same\n") == nil)
  local at = assert(Merge.compare("same\nfile\n", "same\nfine\n"))
  assert(at.offset == 8 and at.line == 2 and at.column == 3 and not at.eof)
  local prefix = assert(Merge.compare("ab", "abc\n"))
  assert(prefix.offset == 3 and prefix.line == 1 and prefix.column == 3 and prefix.eof)
  local first = assert(Merge.compare("x", "y"))
  assert(first.offset == 1 and first.line == 1 and first.column == 1)
  local empty = assert(Merge.compare("", "a"))
  assert(empty.offset == 1 and empty.eof)
end

local function test_compare_agrees_with_a_byte_scan_across_chunks()
  local draw = drawer(11)
  for _, size in ipairs({ 4095, 4096, 4097, 8192, 9000 }) do
    local base = ("0123456789\n"):rep(size // 11 + 1):sub(1, size)
    for _ = 1, 10 do
      local at = draw(size)
      local other = base:sub(1, at - 1) .. "#" .. base:sub(at + 1)
      local found = assert(Merge.compare(base, other))
      assert(found.offset == at, tostring(size) .. ": " .. tostring(found.offset) .. " vs " .. tostring(at))
      local before = base:sub(1, at - 1)
      local _, newlines = before:gsub("\n", "")
      assert(found.line == newlines + 1)
      assert(found.column == at - (before:match(".*\n()") or 1) + 1)
    end
    local longer = base .. "z"
    local cut = assert(Merge.compare(base, longer))
    assert(cut.offset == size + 1 and cut.eof)
  end
end

local function test_comm_sorts_lines_into_three_columns()
  local rows = Merge.comm({ "a", "b", "d" }, { "b", "c", "d" })
  local got: mut {string} = {}
  for _, row in ipairs(rows) do got[#got + 1] = tostring(row.column) .. row.text end
  assert(table.concat(got, " ") == "1a 3b 2c 3d", table.concat(got, " "))
  assert(#Merge.comm({}, {}) == 0)
  assert(#Merge.comm({ "x" }, {}) == 1 and assert(Merge.comm({ "x" }, {})[1]).column == 1)
end

local function test_merging_keeps_every_line_of_a_clean_result()
  local draw = drawer(3)
  for _ = 1, 200 do
    local base: mut {string} = {}
    local count = draw(12)
    for k = 1, count do
      local line = "b" .. tostring(k) .. "\n"
      base[#base + 1] = line
    end
    local function edit(): string
      local out: mut {string} = {}
      for _, line in ipairs(base) do
        local r = draw(10)
        if r == 1 then
          -- dropped
        elseif r == 2 then
          out[#out + 1] = "e" .. tostring(draw(9)) .. "\n"
        else
          out[#out + 1] = line
        end
      end
      return table.concat(out)
    end
    local ours, theirs = edit(), edit()
    local merged = Merge.three(table.concat(base), ours, theirs)
    if merged.conflicts == 0 then
      -- a clean merge keeps a base line only if neither side dropped it
      local text = merged.text
      for _, line in ipairs(lines_of(ours)) do
        if line:sub(1, 1) == "e" then assert(text:find(line, 1, true) ~= nil) end
      end
    else
      assert(merged.text:find("<<<<<<< ours\n", 1, true) ~= nil)
    end
  end
end

local function test_a_dropped_final_newline_is_not_glued_to_an_added_line()
  local merged = Merge.three("a\nb\n", "a\nb", "a\nb\nc\n")
  assert(merged.conflicts == 1, merged.text)
  assert(merged.text == "a\n<<<<<<< ours\nb\n=======\nb\nc\n>>>>>>> theirs\n", merged.text)
  assert(Merge.three("a\nb\n", "a\nb\nc\n", "a\nb").conflicts == 1)
end

local function test_sdiff_cuts_both_columns_to_the_width()
  local text = Merge.sdiff("a\n", "b" .. ("x"):rep(500) .. "\n", { width = 11 })
  assert(#text < 20, text)
end

--- `n` code-like lines, and the same with about `permille` in a thousand of them removed, changed or given a line before.
local function edited_pair(n: integer, permille: integer): string, string
  local draw = drawer(2026)
  local old: mut {string} = {}
  for i = 1, n do
    old[#old + 1] = "  local v" .. tostring(draw(1000000)) .. " = f(" .. tostring(draw(100)) .. ", \"" .. tostring(i) .. "\")"
  end
  local new: mut {string} = {}
  for _, line in ipairs(old) do
    local r = draw(1000)
    if r <= permille / 3 then
      -- removed
    elseif r <= permille * 2 / 3 then
      new[#new + 1] = line .. " -- x"
    elseif r <= permille then
      new[#new + 1] = "  new line " .. tostring(draw(1000000000))
      new[#new + 1] = line
    else
      new[#new + 1] = line
    end
  end
  return table.concat(old, "\n") .. "\n", table.concat(new, "\n") .. "\n"
end

--- Bench: side-by-side rows of 2000 lines, 2 percent of them edited.
local function bench_sdiff_2k_lines(b: Bench.B)
  local old, new = edited_pair(2000, 20)
  b.bytes = #old + #new
  b.reset()
  for _ = 1, b.n do local _ = Merge.sdiff(old, new) end
end

--- Bench: first difference of two texts of 20000 lines, 1 percent of them edited.
local function bench_compare_20k_lines(b: Bench.B)
  local old, new = edited_pair(20000, 10)
  b.bytes = #old + #new
  b.reset()
  for _ = 1, b.n do local _ = Merge.compare(old, new) end
end

--- Bench: three-way merge of 2000 lines, where one side adds a line at the end of the other.
local function bench_merge_2k_lines(b: Bench.B)
  local old, new = edited_pair(2000, 20)
  local theirs = new .. "tail\n"
  b.bytes = #old + #new * 2
  b.reset()
  for _ = 1, b.n do local _ = Merge.three(old, new, theirs) end
end
