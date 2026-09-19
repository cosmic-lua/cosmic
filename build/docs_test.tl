local Sqlite = require("cosmic.sqlite")
local docs = require("build.docs")
local schema = require("build.schema")

--- One in-memory shipped database holding the rows a test names, its
--- FTS index built, so the lookups run against the real schema.
local function database(rows: {{string}}, uses: {{string}}): Sqlite.Handle
  local db = assert(Sqlite.memory())
  for _, statement in ipairs(schema.create("")) do
    assert(db:exec(statement))
  end
  for _, row in ipairs(rows) do
    assert(Sqlite.run(db,
      "INSERT INTO docs (module, symbol, kind, signature, text, file, line) " ..
      "VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
      { { text = row[1] }, { text = row[2] }, { text = row[3] }, { text = row[4] },
        { text = row[5] }, { text = row[6] }, { integer = math.tointeger(tonumber(row[7])) } }))
  end
  for _, row in ipairs(uses) do
    assert(Sqlite.run(db,
      "INSERT INTO uses (module, symbol, from_module, from_file, line) " ..
      "VALUES (?1, ?2, ?3, ?4, ?5)",
      { { text = row[1] }, { text = row[2] }, { text = row[3] }, { text = row[4] },
        { integer = math.tointeger(tonumber(row[5])) } }))
  end
  assert(db:exec("INSERT INTO docs_fts(docs_fts) VALUES ('rebuild')"))
  return db
end

local fs_rows: {{string}} = {
  { "cosmic.fs", "", "module", "", "Files and directories.", "cosmic/fs.tl", "1" },
  { "cosmic.fs", "Fs", "record", "local record Fs", "", "cosmic/fs.tl", "12" },
  { "cosmic.fs", "Fs.read", "function", "function Fs.read(path: string): string | nil, string",
    "The whole of a file.", "cosmic/fs.tl", "23" },
  { "cosmic.fs", "Fs.write", "function", "function Fs.write(path: string, data: string): boolean, string",
    "Writes the whole of a file.\nCreates no parent directory.", "cosmic/fs.tl", "40" },
}
local fs_uses: {{string}} = {
  { "cosmic.fs", "Fs.read", "build.boot", "build/boot.tl", "56" },
  { "cosmic.fs", "Fs.read", "build.test", "build/test.tl", "225" },
}

--- A symbol as declared is found by name, with its use count.
local function test_looks_up_a_symbol_as_declared()
  local db = database(fs_rows, fs_uses)
  local found, trouble, exact = docs.lookup({ db }, "Fs.read")
  assert(found ~= nil, trouble)
  assert(exact, "a declared name was not an exact match")
  assert(#found == 1 and found[1].symbol == "Fs.read", tostring(#found))
  assert(found[1].uses == 2, tostring(found[1].uses))
end

--- A symbol's last name alone finds every symbol ending in it.
local function test_looks_up_a_symbol_by_its_last_name()
  local db = database(fs_rows, fs_uses)
  local found = assert(docs.lookup({ db }, "read"))
  assert(#found == 1 and found[1].symbol == "Fs.read")
end

--- A module's own name finds its module row; rendering it lists what
--- the module declares.
local function test_looks_up_a_module_and_lists_its_symbols()
  local db = database(fs_rows, fs_uses)
  local found = assert(docs.lookup({ db }, "cosmic.fs"))
  assert(#found == 1 and found[1].kind == "module", tostring(#found))
  local lines = docs.render({ db }, found[1])
  assert(lines[1] == "cosmic.fs (cosmic/fs.tl)", lines[1])
  assert(lines[2] == "  Files and directories.", lines[2])
  assert(lines[3] == "  record Fs", lines[3])
  assert(lines[4] == "  function Fs.read (2 uses)", lines[4])
  assert(lines[5] == "  function Fs.write", lines[5])
end

--- Words that name no symbol search the documentation, every word
--- required, and a name nothing matches finds nothing.
local function test_searches_the_documentation_for_words()
  local db = database(fs_rows, fs_uses)
  local words, _, exact = docs.lookup({ db }, "whole file")
  assert(words ~= nil)
  assert(not exact)
  assert(#words == 2, tostring(#words))
  local one = assert(docs.lookup({ db }, "parent directory"))
  assert(#one == 1 and one[1].symbol == "Fs.write")
  local none = assert(docs.lookup({ db }, "nothing_like_this"))
  assert(#none == 0)
end

--- A symbol renders as where it is, its signature, its documentation
--- line by line, and how it is used.
local function test_renders_a_symbol()
  local db = database(fs_rows, fs_uses)
  local found = assert(docs.lookup({ db }, "Fs.write"))
  local lines = docs.render({ db }, found[1])
  assert(lines[1] == "cosmic.fs Fs.write (cosmic/fs.tl:40)", lines[1])
  assert(lines[2] == "  function Fs.write(path: string, data: string): boolean, string", lines[2])
  assert(lines[3] == "  Writes the whole of a file.", lines[3])
  assert(lines[4] == "  Creates no parent directory.", lines[4])
  assert(#lines == 4, tostring(#lines))
  local read = assert(docs.lookup({ db }, "Fs.read"))
  local read_lines = docs.render({ db }, read[1])
  assert(read_lines[#read_lines] == "  used in 2 places; cosmic uses Fs.read",
    read_lines[#read_lines])
end

--- The uses of a symbol, by either name.
local function test_lists_uses()
  local db = database(fs_rows, fs_uses)
  local found = assert(docs.uses({ db }, "read"))
  assert(#found == 2 and found[1].from_file == "build/boot.tl", tostring(#found))
  assert(#assert(docs.uses({ db }, "Fs.write")) == 0)
end

--- An earlier database answers for a module ahead of a later one: a
--- project's build hides the binary's copy of the same module, and the
--- binary still answers for every other.
local function test_an_earlier_database_hides_a_module_in_a_later_one()
  local project = database({
    { "cosmic.fs", "Fs.read", "function", "function Fs.read(path: string): string",
      "The project's own.", "cosmic/fs.tl", "5" },
  }, {})
  local binary = database(fs_rows, fs_uses)
  local read = assert(docs.lookup({ project, binary }, "read"))
  assert(#read == 1 and read[1].text == "The project's own.", tostring(#read))
  local write = assert(docs.lookup({ project, binary }, "Fs.write"))
  assert(#write == 1 and write[1].module == "cosmic.fs")
end
