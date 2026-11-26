--- [`Sqlite.identifier`] and [`Sqlite.literal`] quote a name and a text
--- so SQL reads each as itself, whatever it holds.

local Sqlite = require("cosmic.sqlite")

local function test_a_hostile_name_and_text_are_read_as_themselves()
  local db = assert(Sqlite.memory())
  local name = 'notes"; DROP TABLE kept; --'
  local text = "it's'); DROP TABLE kept; --"
  assert(db:exec("CREATE TABLE kept (x)"))
  assert(db:exec("CREATE TABLE " .. Sqlite.identifier(name) .. " (" .. Sqlite.identifier("a \"b\"") ..
      " TEXT DEFAULT " .. Sqlite.literal(text) .. ")"))
  assert(db:exec("INSERT INTO " .. Sqlite.identifier(name) .. " DEFAULT VALUES"))
  local rows = assert(db:rows("SELECT " .. Sqlite.identifier("a \"b\"") .. " FROM " .. Sqlite.identifier(name)))
  assert(assert(rows[1]):text(1) == text)
  assert(#assert(db:rows("SELECT name FROM sqlite_schema WHERE name = 'kept'")) == 1)
  assert(Sqlite.identifier("") == '""' and Sqlite.literal("") == "''")
  for _, odd in ipairs({ "`tick`", "[bracket]", "\xff\xfe", "two words" }) do
    assert(db:exec("CREATE TABLE " .. Sqlite.identifier(odd) .. " (x)"))
    local found = assert(db:rows("SELECT name FROM sqlite_schema WHERE name = ?1", { { text = odd } }))
    assert(#found == 1, odd)
  end
  assert(db:close())
end

local function test_a_nul_raises()
  local ok, why = pcall(Sqlite.identifier, "a\0b")
  assert(not ok and tostring(why):find("cannot hold a NUL", 1, true) ~= nil, tostring(why))
  local lit_ok, lit_why = pcall(Sqlite.literal, "a\0b")
  assert(not lit_ok and tostring(lit_why):find("cannot hold a NUL", 1, true) ~= nil, tostring(lit_why))
end

--- A NUL in a name Csv.load would quote is refused before the load begins, so the handle is left as it was.
local function test_csv_load_refuses_a_nul_name_before_it_begins()
  local Csv = require("cosmic.csv")
  local db = assert(Sqlite.memory())
  local loaded, why = Csv.load(db, "a\0b", { text = "x\n1\n" })
  assert(loaded == nil and tostring(why):find("NUL", 1, true) ~= nil, tostring(why))
  local json_loaded, json_why = Csv.load(db, "t", { text = "x\n1\n", json = "j\0k" })
  assert(json_loaded == nil and tostring(json_why):find("NUL", 1, true) ~= nil, tostring(json_why))
  assert(not db:in_transaction())
  assert(db:exec("BEGIN; COMMIT"))
  assert(db:close())
end
