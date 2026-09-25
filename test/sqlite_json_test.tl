--- SQLite's JSON functions read `#` line comments (patch/sqlite/), as
--- cosmic.json does when asked, so a text in YAML's flow style reads
--- the same through either.

local Json = require("cosmic.json")
local Sqlite = require("cosmic.sqlite")

--- SQLite's `json(text)`, or nil and its failure.
local function minified(db: Sqlite.Handle, text: string): string | nil, string
  local rows, failure = Sqlite.text_rows(db, "SELECT json(?1)", { { text = text } })
  if rows == nil then return nil, failure end
  return rows[1][1]
end

local function valid(db: Sqlite.Handle, text: string, flags: integer): boolean
  local rows = assert(Sqlite.text_rows(db, "SELECT json_valid(?1, ?2)",
    { { text = text }, { integer = flags } }))
  return rows[1][1] == "1"
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
    local got, failure = minified(db, case[1])
    assert(got == case[2], string.format("%q: %s", case[1], tostring(got or failure)))
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
  assert(Json.encode(ours) == Json.encode(theirs))
  assert(db:close())
end
