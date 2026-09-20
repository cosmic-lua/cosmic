--- Regression tests for `build.coverage.lines.executable_cached`: the
--- `executable` table `build.work`'s schema adds so a run where a
--- module's source has not changed answers from `o/build.db` instead
--- of reparsing it.
local Sqlite = require("cosmic.sqlite")
local lines = require("build.coverage.lines")
local teal = require("build.teal")
local work = require("build.work")

local built, load_trouble = teal.load()
if built == nil then
  error("could not load the compiler: " .. tostring(load_trouble))
end

local function count(db: Sqlite.Handle, table_name: string): integer
  local rows = assert(Sqlite.text_rows(db, "SELECT count(*) FROM " .. table_name))
  return math.tointeger(tonumber(rows[1][1])) as integer
end

--- Same keys in both executable-line sets, ignoring the `true` payload
--- `lines.executable` always sets: what a caller actually compares.
local function same_lines(a: {integer: boolean}, b: {integer: boolean}): boolean
  for line in pairs(a) do
    if not b[line] then return false end
  end
  for line in pairs(b) do
    if not a[line] then return false end
  end
  return true
end

--- A miss (no row for the hash yet) computes exactly what the pure
--- `lines.executable` computes, and stores one row for it.
local function test_miss_computes_and_stores_a_row(tmp: string)
  local handle = assert(work.open(tmp))
  local source = "local x = 1\nlocal y = 2\n"
  local direct = assert(lines.executable(built, source, "miss.tl"))
  local cached, trouble = lines.executable_cached(handle.db, built,
    "hash-miss", source, "miss.tl")
  assert(cached ~= nil, trouble)
  assert(same_lines(direct, cached))
  assert(count(handle.db, "executable") == 1)
  assert(work.close(handle))
end

--- A hit answers from the stored row rather than reparsing: fed a
--- different source under the same hash (which a real reparse would
--- answer differently for), the second call still returns the first
--- call's own answer.
local function test_hit_returns_the_stored_answer_without_reparsing(tmp: string)
  local handle = assert(work.open(tmp))
  local original = "local x = 1\nlocal y = 2\n"
  local first, first_trouble =
    lines.executable_cached(handle.db, built, "hash-hit", original, "hit.tl")
  assert(first ~= nil, first_trouble)

  local different = "local a = 1\nlocal b = 2\nlocal c = 3\n"
  local second, second_trouble =
    lines.executable_cached(handle.db, built, "hash-hit", different, "hit.tl")
  assert(second ~= nil, second_trouble)
  assert(same_lines(first, second),
    "a hit should return the first call's answer, not a fresh parse")
  assert(count(handle.db, "executable") == 1)
  assert(work.close(handle))
end

--- A parse failure is reported exactly as `lines.executable` reports
--- it, and stores nothing: only a successful parse is a function of
--- the hash alone worth caching.
local function test_parse_failure_stores_nothing(tmp: string)
  local handle = assert(work.open(tmp))
  local broken = "if x then"
  local out, trouble = lines.executable_cached(handle.db, built,
    "hash-broken", broken, "broken.tl")
  assert(out == nil, "expected nil on a syntax error")
  assert(trouble ~= "" and trouble:find("broken.tl", 1, true) ~= nil,
    "error should name the file: " .. tostring(trouble))
  assert(count(handle.db, "executable") == 0)
  assert(work.close(handle))
end
