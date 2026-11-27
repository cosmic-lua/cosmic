--- cosmic.shell's calls do as their commands do, and return nil and a failure, never raise, where they fail.
local Fs = require("cosmic.fs")
local Json = require("cosmic.json")
local Shell = require("cosmic.shell")
local Bench = require("cosmic.bench")

--- split keeps a last line with no newline, adds none past a last newline, and keeps a `\r`.
local function test_split_cuts_at_each_newline()
  assert(#Shell.split("") == 0)
  local lines = Shell.split("a\r\n\nb")
  assert(#lines == 3 and lines[1] == "a\r" and lines[2] == "" and lines[3] == "b")
  assert(#Shell.split("a\n") == 1)
  assert(#Shell.split("\n\n") == 2 and Shell.split("\n\n")[2] == "")
end

--- sort orders by bytes, a prefix first and a NUL as the least byte, and leaves its list as it was.
local function test_sort_orders_by_bytes()
  local list = { "b", "a\0b", "", "a", "ab", "\255", "a" }
  local sorted = Shell.sort(list)
  assert(table.concat(sorted, "|") == "|a|a|a\0b|ab|b|\255", string.format("%q", table.concat(sorted, "|")))
  assert(list[1] == "b" and #list == 7)
  assert(#Shell.sort({}) == 0)
end

--- The file calls read and write as their commands do.
local function test_the_file_calls_do_as_their_commands_do(tmp: string)
  assert(Fs.mkdirs(tmp .. "/d/sub"))
  assert(Fs.write(tmp .. "/d/a.tl", "local x = 1\n-- TODO one\n"))
  assert(Fs.write(tmp .. "/d/sub/b.tl", "-- TODO two\r\nlast"))
  assert(Fs.write(tmp .. "/d/c.md", ""))
  local files = assert(Shell.find(tmp .. "/d", ".tl"))
  assert(#files == 2 and files[1] == tmp .. "/d/a.tl" and files[2] == tmp .. "/d/sub/b.tl", table.concat(files, " "))
  local here = assert(Shell.find(tmp .. "/d/"))
  assert(#here == 3 and here[1] == files[1])
  local lines = assert(Shell.lines(tmp .. "/d/sub/b.tl"))
  assert(#lines == 2 and lines[1] == "-- TODO two" and lines[2] == "last")
  assert(assert(Shell.wc(tmp .. "/d/a.tl")) == 2 and assert(Shell.wc(tmp .. "/d/sub/b.tl")) == 1)
  assert(assert(Shell.wc(tmp .. "/d/c.md")) == 0)
  local hits = assert(Shell.grep("TODO", files, true))
  assert(#hits == 2 and hits[2].path == files[2] and hits[2].line == 1 and hits[2].text == "-- TODO two")
  assert(assert(Shell.sed(tmp .. "/d/a.tl", "(%a+) = 1", "%1 = 2")) == 1)
  assert(assert(Fs.read(tmp .. "/d/a.tl")) == "local x = 2\n-- TODO one\n")
  assert(assert(Shell.sed(tmp .. "/d/sub/b.tl", "^last$", "end")) == 1)
  assert(assert(Fs.read(tmp .. "/d/sub/b.tl")) == "-- TODO two\r\nend")
end

--- A missing file, a malformed pattern and a value that cannot be bound are failures the caller reads.
local function test_failures_are_values(tmp: string)
  local found, find_why = Shell.find(tmp .. "/nope")
  assert(found == nil and tostring(find_why) ~= "")
  local hits, grep_why = Shell.grep("[a", {})
  assert(hits ~= nil and #hits == 0 and grep_why == nil, "no file, no line to match")
  assert(Fs.write(tmp .. "/a.txt", "a\n"))
  local bad, bad_why = Shell.grep("[a", { tmp .. "/a.txt" })
  assert(bad == nil and tostring(bad_why):find("[a: ", 1, true) ~= nil, tostring(bad_why))
  local count, sed_why = Shell.sed(tmp .. "/a.txt", "[a", "x")
  assert(count == nil and tostring(sed_why) ~= "")
  local wc, wc_why = Shell.wc(tmp .. "/nope")
  assert(wc == nil and tostring(wc_why) ~= "")
  local rows, sql_why = Shell.sqlite(tmp .. "/n.db", "select ?1", { { 1 } })
  assert(rows == nil and tostring(sql_why):find("value 1 is a table", 1, true) ~= nil, tostring(sql_why))
end

--- sqlite runs a statement with values, or a script with none; NULL is Json.null.
local function test_sqlite_runs_a_statement_or_a_script(tmp: string)
  local db = tmp .. "/n.db"
  assert(#assert(Shell.sqlite(db, "create table t (k text, v); insert into t values ('a', null)")) == 0)
  assert(#assert(Shell.sqlite(db, "insert into t values (?1, ?2)", { "b", true })) == 0)
  local rows = assert(Shell.sqlite(db, "select k, v from t order by k"))
  assert(#rows == 2 and rows[1]["v"] == Json.null and rows[2]["v"] == 1)
  local none, why = Shell.sqlite(db, "create table u (x); nonsense")
  assert(none == nil and tostring(why) ~= "")
end

--- uniq counts, top ranks the most first and ties by key, and sort orders by bytes or by a key, ties by the item.
local function test_counting_and_sorting()
  local ranked = Shell.top(Shell.uniq({ "b", "a", "b", "c", "a" }), 2)
  assert(#ranked == 2 and ranked[1].key == "a" and ranked[1].count == 2 and ranked[2].key == "b")
  assert(#Shell.top({ a = 1 }, -1) == 0)
  assert(table.concat(Shell.sort({ "b", "B", "a" }), ",") == "B,a,b")
  local by_path = Shell.sort({ "f0 b.md", "0a a.md", "0a c.md" }, function(l: string): string
    return l:match("%S+$") or l
  end)
  assert(table.concat(by_path, ",") == "0a a.md,f0 b.md,0a c.md", table.concat(by_path, ","))
end

--- version_sort orders a run of digits by its number, as `sort -V` does: path:line texts come in line order.
local function test_version_sort_orders_numbers_by_value()
  local lines = Shell.version_sort({ "x.tl:1082", "x.tl:56", "a.tl:9", "a.tl:10", "x.tl:056", "b" })
  assert(table.concat(lines, ",") == "a.tl:9,a.tl:10,b,x.tl:056,x.tl:56,x.tl:1082", table.concat(lines, ","))
  assert(table.concat(Shell.version_sort({ "v10", "v9", "v" }), ",") == "v,v9,v10")
  local by_last = Shell.version_sort({ "z 10", "a 9" }, function(l: string): string
    return l:match("%d+$") or l
  end)
  assert(table.concat(by_last, ",") == "a 9,z 10", table.concat(by_last, ","))
end

-- Shell.split cuts at newlines it finds 64 and 32 bytes at a step
-- (core/bytes.h): lines of every length around those widths come back
-- whole.
local function test_split_cuts_lines_of_every_length()
  local lines: mut {string} = {}
  for n = 0, 140 do lines[#lines + 1] = string.rep("x", n) end
  local got = Shell.split(table.concat(lines, "\n"))
  assert(#got == #lines, #got)
  for i, line in ipairs(lines) do assert(got[i] == line, i) end
end

-- A plain grep counts the newlines between its hits 64 and 32 bytes at
-- a step (core/bytes.h): hits after lines of every length around those
-- widths are on the lines they are.
local function test_plain_grep_counts_lines_of_every_length(tmp: string)
  local lines: mut {string} = {}
  for n = 0, 140 do
    lines[#lines + 1] = string.rep("x", n)
    if n % 7 == 0 then lines[#lines + 1] = "hit " .. tostring(n) end
  end
  local path = tmp .. "/lines.txt"
  assert(Fs.write(path, table.concat(lines, "\n")))
  local hits = assert(Shell.grep("hit ", { path }, true))
  local seen = 0
  for i, line in ipairs(lines) do
    if line:sub(1, 4) == "hit " then
      seen = seen + 1
      local hit = assert(hits[seen], i)
      assert(hit.line == i and hit.text == line, ("%d: %s"):format(i, hit.text))
    end
  end
  assert(#hits == seen, #hits)
end

--- Benches. cosmic.shell's calls in this process, on a small file and on 1 MiB, and a find over 200 files.

--- Writes the small file (20 lines) or the big one (16384 lines, about 1 MiB) to `dir` and returns its path.
local function sample_file(dir: string, big: boolean): string
  local parts: mut {string} = {}
  if big then
    for i = 1, 16384 do
      parts[i] = string.rep("x", 50 + i % 7) .. (if i % 97 == 0 then " TODO" else "" end) .. tostring(i % 89)
    end
  else
    for i = 1, 20 do
      parts[i] = "line " .. tostring(i) .. (if i % 3 == 0 then " TODO" else "" end)
    end
  end
  local path = dir .. (if big then "/big.txt" else "/small.txt" end)
  assert(Fs.write(path, table.concat(parts, "\n") .. "\n"))
  return path
end

local function wcing(b: Bench.B, big: boolean)
  local path = sample_file(b.dir, big)
  b.reset()
  for _ = 1, b.n do assert(Shell.wc(path)) end
end

local function grepping(b: Bench.B, big: boolean)
  local path = sample_file(b.dir, big)
  b.reset()
  for _ = 1, b.n do assert(Shell.grep("TODO", { path }, true)) end
end

local function sorting(b: Bench.B, big: boolean)
  local path = sample_file(b.dir, big)
  b.reset()
  for _ = 1, b.n do local _ = Shell.sort(assert(Shell.lines(path))) end
end

local function counting(b: Bench.B, big: boolean)
  local path = sample_file(b.dir, big)
  b.reset()
  for _ = 1, b.n do local _ = Shell.top(Shell.uniq(assert(Shell.lines(path)))) end
end

local function bench_wc_small(b: Bench.B) wcing(b, false) end
local function bench_wc_1_mib(b: Bench.B) wcing(b, true) end
local function bench_grep_small(b: Bench.B) grepping(b, false) end
local function bench_grep_1_mib(b: Bench.B) grepping(b, true) end
local function bench_sort_small(b: Bench.B) sorting(b, false) end
local function bench_sort_1_mib(b: Bench.B) sorting(b, true) end
local function bench_sort_uniq_c_small(b: Bench.B) counting(b, false) end
local function bench_sort_uniq_c_1_mib(b: Bench.B) counting(b, true) end

local function bench_find_200_files(b: Bench.B)
  for i = 1, 200 do
    local sub = b.dir .. "/tree/d" .. tostring(i % 10)
    assert(Fs.mkdirs(sub))
    assert(Fs.write(sub .. "/f" .. tostring(i) .. ".tl", ""))
  end
  b.reset()
  for _ = 1, b.n do assert(Shell.find(b.dir .. "/tree")) end
end
