--- SQLite's JSON functions read `#` line comments (patch/sqlite/), as
--- cosmic.json does when asked, so a text in YAML's flow style reads
--- the same through either.

local Json = require("cosmic.json")
local Sqlite = require("cosmic.sqlite")

--- The first of `rows`, which the statement is known to yield.
local function first_row(rows: Sqlite.Rows): Sqlite.Row
  local found = rows[1]
  assert(found, "the statement yields a row")
  return found
end

--- SQLite's `json(text)`, or nil and its failure.
local function minified(db: Sqlite.Handle, text: string): string?, string
  local rows, failure = Sqlite.text_rows(db, "SELECT json(?1)", { { text = text } })
  if rows == nil then return nil, failure end
  return first_row(rows):text(1), ""
end

local function valid(db: Sqlite.Handle, text: string, flags: integer): boolean
  local rows = assert(Sqlite.text_rows(db, "SELECT json_valid(?1, ?2)",
    { { text = text }, { integer = flags } }))
  return first_row(rows):text(1) == "1"
end

local function test_hash_comments_read_as_whitespace()
  local db = assert(Sqlite.memory())
  local cases: {{string}} = {
    { "# head\n{a: 1, # after a value\n  b: [2, # inside\n 3], # last\n}", '{"a":1,"b":[2,3]}' },
    { "1 # no line break after", "1" },
    { "{a# before the colon\n: 1}", '{"a":1}' },
    { "[1, # ends at a carriage return\r2]", "[1,2]" },
    { "[1, # ends at U+2028\u{2028}2, # and U+2029\u{2029}3]", "[1,2,3]" },
    { '["a # b"]', '["a # b"]' },
  }
  for _, case in ipairs(cases) do
    local text, want = case[1], case[2]
    assert(text and want, "a case is a text and what it minifies to")
    local got, failure = minified(db, text)
    assert(got == want, string.format("%q: %s", text, tostring(got or failure)))
  end
  assert(minified(db, "[1 # ]") == nil, "a comment runs to the line's end")
  assert(db:close())
end

local function test_a_hash_comment_is_json5_not_json()
  local db = assert(Sqlite.memory())
  assert(not valid(db, "# c\n1", 1), "RFC 8259 JSON has no comments")
  assert(valid(db, "# c\n1", 2), "JSON5, as SQLite reads it, has")
  assert(db:close())
end

local function test_sqlite_and_cosmic_json_read_flow_style_alike()
  local db = assert(Sqlite.memory())
  local text = "# a workflow\n{on: {push: {}}, jobs: {a: {\"runs-on\": \"x\", # the runner\n steps: [{run: \"echo #1\"}]}}}\n"
  local ours = assert(Json.decode(text, { json5 = true, hash_comments = true }))
  local theirs = assert(Json.decode((assert(minified(db, text)))))
  assert(Json.encode_any(ours) == Json.encode_any(theirs))
  assert(db:close())
end

--- A scalar subquery's JSON result is text to its caller: its subtype
--- does not pass through, so json_object embeds it as a string, and
--- json() embeds it as JSON.
local function test_a_subquerys_json_result_is_text_to_its_caller()
  local db = assert(Sqlite.memory())
  local cases: {{string}} = {
    { "SELECT json_object('a', (SELECT json_group_array(1)))", '{"a":"[1]"}' },
    { "SELECT json_object('a', json((SELECT json_group_array(1))))", '{"a":[1]}' },
  }
  for _, case in ipairs(cases) do
    local sql, want = case[1], case[2]
    assert(sql and want, "a case is a statement and what it answers")
    local rows = assert(Sqlite.text_rows(db, sql))
    local got = first_row(rows):text(1)
    assert(got == want, sql .. ": " .. got)
  end
  assert(db:close())
end
