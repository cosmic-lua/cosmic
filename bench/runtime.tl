--- Run-time microbenchmarks of the stdlib's hot paths: `bin/cosmic bench/runtime.tl [name...]`.
--- Each case runs its body in batches until a batch takes 50 ms, then times five batches of that size and prints the
--- fastest and the median per operation. It measures; it gates nothing, and no test reads its numbers.
local Clock = require("cosmic.clock")
local Csv = require("cosmic.csv")
local Json = require("cosmic.json")
local Sqlite = require("cosmic.sqlite")
local Stream = require("cosmic.stream")

local record Case
  name: string
  run: function(n: integer)
end

local cases: mut {Case} = {}

local function decoded(text: string): Json.Value
  local value, why = Json.decode(text)
  if value == nil then error(tostring(why)) end
  return value
end

local function case(name: string, run: function(n: integer))
  cases[#cases + 1] = { name = name, run = run }
end

local function batch(c: Case, n: integer): integer
  collectgarbage("collect")
  local start = Clock.monotonic_ns()
  c.run(n)
  return Clock.monotonic_ns() - start
end

local function measure(c: Case)
  local n = 1
  while batch(c, n) < 50 * 1000 * 1000 do n = n * 2 end
  local times: mut {number} = {}
  for i = 1, 5 do times[i] = batch(c, n) / n end
  table.sort(times)
  print(string.format("%-28s %12.0f ns/op  (median %.0f, n=%d)", c.name, assert(times[1]), assert(times[3]), n))
end

-- JSON: one small object, and an array of 1000 records.
local small = '{"id":42,"name":"cosmic","tags":["lua","teal"],"ok":true,"score":3.5,"owner":{"login":"x"}}'
local records: mut {Json.Value} = {}
for i = 1, 1000 do
  records[i] = { id = i, name = "user" .. tostring(i), email = "u" .. tostring(i) .. "@example.com",
    active = i % 2 == 0, score = i / 7, tags = Json.array({ "a", "b", "c" }) }
end
local big_value = Json.array(records)
local big = assert(Json.encode(big_value))

case("lua.build 1000 records", function(n: integer)
  for _ = 1, n do
    local out: mut {Json.Value} = {}
    for i = 1, 1000 do
      out[i] = { id = i, name = "user", email = "u@example.com", active = true, score = 1.5, tags = { "a", "b", "c" } }
    end
  end
end)
case("json.decode small", function(n: integer)
  for _ = 1, n do local _ = decoded(small) end
end)
case("json.decode 1000 records", function(n: integer)
  for _ = 1, n do local _ = decoded(big) end
end)
case("json.encode 1000 records", function(n: integer)
  for _ = 1, n do assert(Json.encode(big_value)) end
end)
local small_value = decoded(small)
case("json.encode small", function(n: integer)
  for _ = 1, n do assert(Json.encode(small_value)) end
end)

-- SQLite, in memory: one insert of three values, one select by key, and 1000 rows read.
local db = assert(Sqlite.memory())
assert(db:exec("create table t (id integer primary key, name text, score real)"))
assert(db:exec("create table w (id integer primary key, name text, score real)"))
local next_id = 0
case("sqlite.run insert", function(n: integer)
  for _ = 1, n do
    next_id = next_id + 1
    assert(db:run("insert into w (id, name, score) values (?, ?, ?)",
      { { integer = next_id }, { text = "name" }, { number = 1.5 } }))
  end
end)
case("sqlite.run insert plain", function(n: integer)
  for _ = 1, n do
    next_id = next_id + 1
    assert(db:run("insert into w (id, name, score) values (?, ?, ?)", { next_id, "name", 1.5 }))
  end
end)
for i = 1, 1000 do
  assert(db:run("insert into t (id, name, score) values (?, ?, ?)",
    { { integer = i }, { text = "name" .. tostring(i) }, { number = i / 3 } }))
end
case("sqlite.rows by key", function(n: integer)
  for i = 1, n do
    local rows = assert(db:rows("select name, score from t where id = ?", { { integer = i % 1000 + 1 } }))
    assert(#rows == 1)
  end
end)
case("sqlite.rows 1000", function(n: integer)
  for _ = 1, n do
    local rows = assert(db:rows("select id, name, score from t"))
    assert(#rows == 1000)
  end
end)
case("sqlite.query each 1000", function(n: integer)
  for _ = 1, n do
    local q = assert(db:query("select id, name, score from t"))
    local count = 0
    for row in q:each() do
      if row:integer(1) > 0 then count = count + 1 end
    end
    local _, _ = q:close()
    assert(count == 1000)
  end
end)

-- Streams: the lines of 1 MiB of text, and reading it whole.
local line_parts: mut {string} = {}
for i = 1, 16384 do line_parts[i] = string.rep("x", 60 + i % 7) end
local text = table.concat(line_parts, "\n") .. "\n"
case("stream.lines 1 MiB", function(n: integer)
  for _ = 1, n do
    local count = 0
    for _ in Stream.lines(Stream.from_string(text)):each() do count = count + 1 end
    assert(count == 16384)
  end
end)
case("stream.read_all 1 MiB", function(n: integer)
  for _ = 1, n do assert(#assert(Stream.read_all(Stream.from_string(text))) == #text) end
end)

-- CSV: 1000 rows of five fields, one quoted.
local csv_rows: mut {string} = { "id,name,email,score,note" }
for i = 1, 1000 do
  csv_rows[#csv_rows + 1] = tostring(i) .. ",user" .. tostring(i) .. ",u@example.com," .. tostring(i / 7) .. ',"a, b"'
end
local csv_text = table.concat(csv_rows, "\n") .. "\n"
case("csv.parse 1000 rows", function(n: integer)
  for _ = 1, n do assert(#assert(Csv.parse(csv_text)) == 1001) end
end)

local wanted: mut {string: boolean} = {}
for _, name in ipairs(arg) do wanted[name] = true end
for _, c in ipairs(cases) do
  local selected = next(wanted) == nil
  for name in pairs(wanted) do
    if c.name:find(name, 1, true) ~= nil then selected = true end
  end
  if selected then measure(c) end
end
