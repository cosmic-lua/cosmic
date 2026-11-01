--- Tests of [`build.coverage.syntax_lines`]: the executable lines of a source in the new grammar, and the
--- `executable` table [`build.work`]'s schema adds so a run where a module's source has not changed answers from
--- `build.db` instead of reparsing it.
local Hits = require("build.coverage_hits")
local Sqlite = require("cosmic.sqlite")
local Test = require("cosmic.test")
local lines = require("build.coverage.syntax_lines")
local work = require("build.work")

Test.policy{ cpu_features = true }

local function count(db: Sqlite.Handle, table_name: string): integer
  local rows = assert(Sqlite.text_rows(db, "SELECT count(*) FROM " .. table_name))
  return assert(math.tointeger(tonumber(rows[1]:text(1))))
end

local function same_lines(a: {integer: boolean}, b: {integer: boolean}): boolean
  for line in pairs(a) do
    if b[line] ~= true then return false end
  end
  for line in pairs(b) do
    if a[line] ~= true then return false end
  end
  return true
end

local function numbers(set: {integer: boolean}): string
  local out: mut {integer} = {}
  for line in pairs(set) do
    out[#out + 1] = line
  end
  table.sort(out)
  return table.concat(out, " ")
end

local function test_a_statement_at_any_depth_counts_on_its_first_line_and_a_type_declaration_does_not()
  local source = table.concat({
    "local record R", -- 1
    "  n: integer", -- 2
    "end", -- 3
    "", -- 4
    "-- a comment", -- 5
    "local function f(a: integer): integer", -- 6
    "  if a > 1 then", -- 7
    "    return a", -- 8
    "  else", -- 9
    "    return 0", -- 10
    "  end", -- 11
    "end", -- 12
    "local t = {", -- 13
    "  1,", -- 14
    "}", -- 15
    "function R.make(n: integer): R", -- 16
    "  return { n = n }", -- 17
    "end", -- 18
    "print(t)", -- 19
    "",
  }, "\n")
  local found = assert(lines.executable(source, "m.tl"))
  assert(numbers(found) == "7 8 10 12 13 16 17 19", numbers(found))
end

local function test_a_statement_that_spans_lines_counts_on_the_line_it_starts()
  local found = assert(lines.executable("local x = f(\n  1,\n  2)\nreturn x\n", "m.tl"))
  assert(numbers(found) == "1 4", numbers(found))
end

local function test_a_miss_computes_and_stores_a_row(tmp: string)
  local handle = assert(work.open(tmp))
  local source = "local x = 1\nlocal y = 2\n"
  local direct = assert(lines.executable(source, "miss.tl"))
  local cached, trouble = lines.executable_cached(handle.db, "hash-miss", source, "miss.tl")
  assert(cached ~= nil, trouble)
  assert(same_lines(direct, cached))
  assert(count(handle.db, "executable") == 1)
  assert(work.close(handle))
end

local function test_a_hit_returns_the_stored_answer_without_reparsing(tmp: string)
  local handle = assert(work.open(tmp))
  local first, first_trouble = lines.executable_cached(handle.db, "hash-hit", "local x = 1\nlocal y = 2\n", "hit.tl")
  assert(first ~= nil, first_trouble)
  local second, second_trouble = lines.executable_cached(handle.db, "hash-hit",
    "local a = 1\nlocal b = 2\nlocal c = 3\n", "hit.tl")
  assert(second ~= nil, second_trouble)
  assert(same_lines(first, second), "a hit should return the first call's answer, not a fresh parse")
  assert(count(handle.db, "executable") == 1)
  assert(work.close(handle))
end

local function test_a_parse_failure_stores_nothing(tmp: string)
  local handle = assert(work.open(tmp))
  local out, trouble = lines.executable_cached(handle.db, "hash-broken", "if x then", "broken.tl")
  assert(out == nil and trouble:find("broken.tl", 1, true) ~= nil, tostring(trouble))
  assert(count(handle.db, "executable") == 0)
  assert(work.close(handle))
end

--- Every line counted executable is one the VM can report: a chunk with no branches, run to completion under this
--- test's own window, hits each of them. A `local function` statement runs on its `end` line, since Lua attributes the
--- closure there, never on its first.
local function test_every_executable_line_of_straight_code_is_hit()
  local source = "local function f()\n  return 1\nend\nlocal g = f()\nlocal t = {}\nfunction t.h()\n  return g\nend\n" ..
    "local h = t.h()\n"
  local executable = assert(lines.executable(source, "straight.tl"))
  assert(executable[1] ~= true, "a local function's first line never runs")
  assert(executable[3], "a local function runs on its end line")
  assert(executable[6], "function t.h runs on its first line")
  local name = "coverage.syntax_lines_test.straight"
  local chunk = assert(load(source, "@" .. name, "t"))
  chunk()
  local hit = Hits.snapshot()[name] or {}
  for line in pairs(executable) do
    assert(hit[line], "executable line " .. tostring(line) .. " was never hit")
  end
end
