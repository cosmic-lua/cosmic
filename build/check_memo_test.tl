--- The memo of [`build.check_memo`]: rows survive being written as text, a key
--- moves with the salt, the dialect and the bytes, and a run keeps the rows it
--- used.
local Sqlite = require("cosmic.sqlite")
local check_memo = require("build.check_memo")

local function test_rows_with_tabs_breaks_and_backslashes_come_back_as_written()
  local rows: {{string}} = {
    { "E", "a\tb", "c\nd", "e\\f", "" },
    { "H", "", "x\r\ny", "\\t", "\\" },
  }
  local back = check_memo.decode(check_memo.encode(rows))
  assert(#back == 2 and #back[1] == 5 and #back[2] == 5, #back)
  for i, row in ipairs(rows) do
    for j, field in ipairs(row) do
      assert(back[i][j] == field, tostring(i) .. "," .. tostring(j))
    end
  end
  assert(#check_memo.decode("") == 0)
end

local function test_a_key_moves_with_the_salt_the_dialect_and_the_bytes()
  local base = check_memo.key("salt", "tl", "bytes")
  assert(base == check_memo.key("salt", "tl", "bytes"))
  assert(base ~= check_memo.key("other", "tl", "bytes"))
  assert(base ~= check_memo.key("salt", "decl", "bytes"))
  assert(base ~= check_memo.key("salt", "tl", "byte"))
end

local function test_a_run_keeps_the_rows_it_used_and_drops_the_rest()
  local db = assert(Sqlite.memory())
  assert(check_memo.prepare(db, "k"))
  check_memo.put(db, "k", "one", "1")
  check_memo.put(db, "k", "two", "2")
  check_memo.put(db, "other", "one", "x")
  assert(check_memo.get(db, "k", "one") == "1" and check_memo.get(db, "k", "none") == nil)
  check_memo.finish(db, "k")
  assert(check_memo.get(db, "k", "two") == "2")
  -- A second run that uses only `one`: `two` goes.
  assert(check_memo.prepare(db, "k"))
  assert(check_memo.get(db, "k", "one") == "1")
  check_memo.finish(db, "k")
  assert(check_memo.get(db, "k", "two") == nil and check_memo.get(db, "other", "one") == "x")
  assert(db:close())
end
