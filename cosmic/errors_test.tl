--- `Errors.guidance` over a catalog of its own, attached ahead of the
--- binary's: which row an uncaught error's message is matched to, and
--- what is printed for it. The words are made up, so no row of the
--- binary's own catalog matches any of these messages.
local Errors = require("cosmic.errors")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")

--- A catalog row: its message, its own guidance (nil to take the doc
--- comment of `symbol` in `module` instead), and where it was found.
local record Row
  message: string
  text: string | nil
  module: string
  symbol: string
  file: string
  line: integer
end

--- Writes a database at `path` holding `rows` in its catalog, indexed
--- as a projection's is, and `docs` as doc comments by symbol, and
--- attaches it ahead of the binary's.
local function attach(path: string, rows: {Row}, docs?: {string:string})
  local db = assert(Sqlite.open(path, true))
  assert(db:exec([[
    CREATE TABLE catalog (id INTEGER PRIMARY KEY, kind TEXT NOT NULL,
      module TEXT NOT NULL, symbol TEXT, message TEXT, text TEXT,
      file TEXT NOT NULL, line INTEGER NOT NULL);
    CREATE TABLE docs (id INTEGER PRIMARY KEY, module TEXT NOT NULL,
      source_symbol TEXT NOT NULL, text TEXT NOT NULL);
    CREATE VIRTUAL TABLE catalog_fts USING fts5(message, text,
      content=catalog, content_rowid=id);
  ]]))
  for _, row in ipairs(rows) do
    local text: Sqlite.Value = {}
    if row.text ~= nil then
      text = { text = row.text }
    end
    assert(Sqlite.run(db, "INSERT INTO catalog (kind, module, symbol, message, " ..
      "text, file, line) VALUES ('extracted', ?1, ?2, ?3, ?4, ?5, ?6)",
      { { text = row.module }, { text = row.symbol }, { text = row.message }, text,
        { text = row.file }, { integer = row.line } }))
  end
  for symbol, doc in pairs(docs or {}) do
    assert(Sqlite.run(db, "INSERT INTO docs (module, source_symbol, text) " ..
      "VALUES ('zorb', ?1, ?2)", { { text = symbol }, { text = doc } }))
  end
  assert(db:exec("INSERT INTO catalog_fts(catalog_fts) VALUES ('rebuild')"))
  assert(db:close())
  assert(Store.attach(path))
end

local function row(message: string, text?: string, line?: integer): Row
  return { message = message, text = text, module = "zorb",
           symbol = "Zorb.frob", file = "zorb.tl", line = line or 12 }
end

local function test_a_message_sharing_two_words_gets_the_rows_guidance(tmp: string)
  attach(tmp .. "/c.db", { row("the quuxifier refused the zorblax",
    "Frobs a zorblax.\nA second line.\n@param x ignored\nA third.") })
  local text = Errors.guidance("frob: the quuxifier refused the zorblax at 3")
  assert(text == "cosmic: Zorb.frob (zorb.tl:12): Frobs a zorblax.\n" ..
    "cosmic:   A second line.\ncosmic:   A third.\n", tostring(text))
end

--- One shared word is not enough, and a function word shared counts
--- for nothing: "not" and "the" alone relate nothing.
local function test_one_word_or_function_words_are_not_enough(tmp: string)
  attach(tmp .. "/c.db", { row("the quuxifier is not ready", "Guidance.") })
  assert(Errors.guidance("quuxifier is gone") == nil)
  local matched = Errors.guidance("the quuxifier is ready")
  assert(matched ~= nil and matched:find("Guidance.", 1, true) ~= nil,
    "two content words match: " .. tostring(matched))
  assert(Errors.guidance("the flarb is not here") == nil)
  assert(Errors.guidance("quuxifier is not") == nil,
    "a function word beside one content word is one word")
end

--- A word said twice is one word, and a word is matched whole, case
--- aside: "os" is not in "quuxos".
local function test_words_count_once_and_whole(tmp: string)
  attach(tmp .. "/c.db", { row("quuxos zorblax", "Guidance.") })
  assert(Errors.guidance("zorblax zorblax ZORBLAX") == nil)
  assert(Errors.guidance("os zorblax") == nil)
  assert(Errors.guidance("QUUXOS Zorblax") ~= nil)
end

--- A row with no guidance of its own prints the doc comment of the
--- function it was found in, and a row with no line names its file.
local function test_a_row_without_text_takes_its_functions_doc(tmp: string)
  attach(tmp .. "/c.db", { row("quuxifier zorblax", nil, 0) },
    { ["Zorb.frob"] = "Frobs the zorblax." })
  assert(Errors.guidance("quuxifier zorblax") ==
    "cosmic: Zorb.frob (zorb.tl): Frobs the zorblax.\n")
end

--- A message with only function words asks nothing.
local function test_a_message_of_function_words_asks_nothing(tmp: string)
  attach(tmp .. "/c.db", { row("the and of", "Guidance.") })
  assert(Errors.guidance("the and of") == nil)
  assert(Errors.guidance("") == nil)
end
