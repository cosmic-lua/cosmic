--- Tests for cosmic.sqlite's typed column readers: the happy path per
--- type, the two failure messages, and the float an integer read must
--- refuse. Reads run against real query rows so the readers are exercised
--- on the values sqlite actually hands back, not on hand-built tables.

local check = require("cosmic.check")
local sqlite = require("cosmic.sqlite")

-- One in-memory row with a TEXT, a REAL and an INTEGER column, plus a
-- NULL, which is every shape the readers branch on.
local function one_row(): {string: any}
  local db = check.must(sqlite.open(":memory:"))
  assert(db:exec("CREATE TABLE t (name TEXT, c REAL, n INTEGER, missing TEXT)"))
  assert(db:exec("INSERT INTO t (name, c, n) VALUES ('alice', 3.14, 7)"))
  local row = check.must(db:query_one("SELECT * FROM t"))
  assert(db:close())
  return row
end

local function test_reads_each_column_at_its_declared_type()
  local row = one_row()
  check.equal(check.must(sqlite.column_text(row, "name")), "alice", "TEXT reads as string")
  check.equal(check.must(sqlite.column_number(row, "c")), 3.14, "REAL reads as number")
  check.equal(check.must(sqlite.column_integer(row, "n")), 7, "INTEGER reads as integer")
end
test_reads_each_column_at_its_declared_type()

-- An INTEGER column is a number too: the wider reader accepts it, so a
-- caller who does not care about the subtype is not forced to guess.
local function test_number_accepts_an_integer_column()
  local row = one_row()
  check.equal(check.must(sqlite.column_number(row, "n")), 7, "INTEGER reads as number")
end
test_number_accepts_an_integer_column()

local function test_a_missing_or_null_column_fails_with_one_message()
  local row = one_row()
  local absent, aerr = sqlite.column_text(row, "nosuch")
  check.equal(absent, nil, "an unnamed column has no value")
  check.equal(aerr, 'column "nosuch" is absent or NULL', "absent message")

  local null, nerr = sqlite.column_text(row, "missing")
  check.equal(null, nil, "a NULL column has no value")
  check.equal(nerr, 'column "missing" is absent or NULL',
    "a SQL NULL reads the same as an absent column")

  -- Each reader owns its own nil branch, so each is asked for one.
  local num, numerr = sqlite.column_number(row, "missing")
  check.equal(num, nil, "a NULL column is not a number")
  check.equal(numerr, 'column "missing" is absent or NULL', "number absent message")

  local int, interr = sqlite.column_integer(row, "nosuch")
  check.equal(int, nil, "an unnamed column is not an integer")
  check.equal(interr, 'column "nosuch" is absent or NULL', "integer absent message")
end
test_a_missing_or_null_column_fails_with_one_message()

local function test_a_wrong_type_names_what_it_found_and_what_it_wanted()
  local row = one_row()
  local v, err = sqlite.column_text(row, "c")
  check.equal(v, nil, "a REAL column is not a string")
  check.equal(err, 'column "c" is number, want string', "text mismatch message")

  local n, nerr = sqlite.column_number(row, "name")
  check.equal(n, nil, "a TEXT column is not a number")
  check.equal(nerr, 'column "name" is string, want number', "number mismatch message")
end
test_a_wrong_type_names_what_it_found_and_what_it_wanted()

-- The subtype is the whole point of the integer reader: a REAL column
-- means the schema is not what the caller assumed, and reading it as an
-- integer would silently truncate.
local function test_integer_refuses_a_float()
  local row = one_row()
  local v, err = sqlite.column_integer(row, "c")
  check.equal(v, nil, "3.14 is not an integer")
  check.equal(err, 'column "c" is a float, want integer', "float message names the subtype")

  local s, serr = sqlite.column_integer(row, "name")
  check.equal(s, nil, "a TEXT column is not an integer")
  check.equal(serr, 'column "name" is string, want integer', "non-number keeps its type name")
end
test_integer_refuses_a_float()

print("all sqlite column reader tests passed")
