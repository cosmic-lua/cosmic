local Sqlite = require("cosmic.sqlite")
local docs = require("build.docs")
local schema = require("build.schema")

--- One in-memory shipped database holding the rows a test names, its
--- FTS index built, so the lookups run against the real schema.
local function database(rows: {{string}}, uses: {{string}},
                        examples?: {{string}}, modules?: {string}): Sqlite.Handle
  local db = assert(Sqlite.memory())
  for _, statement in ipairs(schema.create("")) do
    assert(db:exec(statement))
  end
  local members: {string: boolean} = {}
  if modules ~= nil then
    for _, module in ipairs(modules) do
      members[module] = true
    end
  else
    for _, row in ipairs(rows) do members[row[1]] = true end
    for _, row in ipairs(uses) do members[row[3]] = true end
    for _, row in ipairs(examples or {}) do members[row[1]] = true end
  end
  for module in pairs(members) do
    assert(Sqlite.run(db,
      "INSERT INTO modules (path, file, kind, source_hash, key, source, lua, " ..
      "bytecode, tests) VALUES (?1, ?2, 'module', '', '', '', '', '', '')",
      { { text = module }, { text = module:gsub("%.", "/") .. ".tl" } }))
  end
  for _, row in ipairs(rows) do
    assert(Sqlite.run(db,
      "INSERT INTO docs (module, symbol, source_symbol, exported, kind, " ..
      "signature, text, file, line) " ..
      "VALUES (?1, ?2, ?2, ?8, ?3, ?4, ?5, ?6, ?7)",
      { { text = row[1] }, { text = row[2] }, { text = row[3] }, { text = row[4] },
        { text = row[5] }, { text = row[6] }, { integer = math.tointeger(tonumber(row[7])) },
        { integer = row[8] == "private" and 0 or 1 } }))
  end
  for _, row in ipairs(uses) do
    assert(Sqlite.run(db,
      "INSERT INTO uses (module, symbol, from_module, from_file, line) " ..
      "VALUES (?1, ?2, ?3, ?4, ?5)",
      { { text = row[1] }, { text = row[2] }, { text = row[3] }, { text = row[4] },
        { integer = math.tointeger(tonumber(row[5])) } }))
  end
  for _, row in ipairs(examples or {}) do
    assert(Sqlite.run(db,
      "INSERT INTO examples (module, name, text, file, line, source) " ..
      "VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
      { { text = row[1] }, { text = row[2] }, { text = row[3] }, { text = row[4] },
        { integer = math.tointeger(tonumber(row[5])) }, { text = row[6] } }))
  end
  assert(db:exec("INSERT INTO docs_fts(docs_fts) VALUES ('rebuild')"))
  assert(db:exec("INSERT INTO examples_fts(examples_fts) VALUES ('rebuild')"))
  return db
end

local function view(databases: {Sqlite.Handle}): docs.View
  return (assert(docs.view(databases)))
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
  local found, trouble = docs.lookup(view({ db }), "Fs.read")
  local exact = found ~= nil and found.exact
  assert(found ~= nil, trouble)
  assert(exact, "a declared name was not an exact match")
  assert(#found == 1 and found[1].symbol == "Fs.read", tostring(#found))
  assert(found[1].uses == 2, tostring(found[1].uses))
end

--- A symbol's last name alone finds every symbol ending in it.
local function test_looks_up_a_symbol_by_its_last_name()
  local db = database(fs_rows, fs_uses)
  local found = assert(docs.lookup(view({ db }), "read"))
  assert(#found == 1 and found[1].symbol == "Fs.read")
end

--- A module's own name finds its module row; rendering it lists what
--- the module declares.
local function test_looks_up_a_module_and_lists_its_symbols()
  local db = database(fs_rows, fs_uses)
  local found = assert(docs.lookup(view({ db }), "cosmic.fs"))
  assert(#found == 1 and found[1].kind == "module", tostring(#found))
  local lines = docs.render(view({ db }), found[1])
  assert(lines[1] == "cosmic.fs (cosmic/fs.tl)", lines[1])
  assert(lines[2] == "  Files and directories.", lines[2])
  assert(lines[3] == "  record Fs", lines[3])
  assert(lines[4] == "  function Fs.read (2 uses)", lines[4])
  assert(lines[5] == "  function Fs.write", lines[5])
end

--- A module's listing leaves out the functions its returned value never
--- reaches, but keeps the types it declares; a private function is still
--- found by its own name.
local function test_a_module_listing_leaves_out_private_functions()
  local rows: {{string}} = {
    { "cosmic.fs", "", "module", "", "Files and directories.", "cosmic/fs.tl", "1" },
    { "cosmic.fs", "Stat", "record", "local record Stat", "", "cosmic/fs.tl", "5", "private" },
    { "cosmic.fs", "Fs", "record", "local record Fs", "", "cosmic/fs.tl", "12" },
    { "cosmic.fs", "write_all", "function", "local function write_all(fd: integer)",
      "", "cosmic/fs.tl", "18", "private" },
    { "cosmic.fs", "Fs.read", "function", "function Fs.read(path: string): string",
      "", "cosmic/fs.tl", "23" },
  }
  local db = database(rows, {})
  local found = assert(docs.lookup(view({ db }), "cosmic.fs"))
  local lines = docs.render(view({ db }), found[1])
  assert(lines[3] == "  record Stat", lines[3])
  assert(lines[4] == "  record Fs", lines[4])
  assert(lines[5] == "  function Fs.read", lines[5])
  assert(lines[6] == nil, lines[6])
  local helper = assert(docs.lookup(view({ db }), "write_all"))
  assert(#helper == 1 and helper[1].symbol == "write_all", tostring(#helper))
end

--- Words that name no symbol search the documentation, every word
--- required, and a name nothing matches finds nothing.
local function test_searches_the_documentation_for_words()
  local db = database(fs_rows, fs_uses)
  local words = assert(docs.lookup(view({ db }), "whole file"))
  local exact = words.exact
  assert(words ~= nil)
  assert(not exact)
  assert(#words == 2, tostring(#words))
  local one = assert(docs.lookup(view({ db }), "parent directory"))
  assert(#one == 1 and one[1].symbol == "Fs.write")
  local none = assert(docs.lookup(view({ db }), "nothing_like_this"))
  assert(#none == 0)
end

--- A symbol renders as where it is, its signature, its documentation
--- line by line, and how it is used.
local function test_renders_a_symbol()
  local db = database(fs_rows, fs_uses)
  local found = assert(docs.lookup(view({ db }), "Fs.write"))
  local lines = docs.render(view({ db }), found[1])
  assert(lines[1] == "cosmic.fs Fs.write (cosmic/fs.tl:40)", lines[1])
  assert(lines[2] == "  function Fs.write(path: string, data: string): boolean, string", lines[2])
  assert(lines[3] == "  Writes the whole of a file.", lines[3])
  assert(lines[4] == "  Creates no parent directory.", lines[4])
  assert(#lines == 4, tostring(#lines))
  local read = assert(docs.lookup(view({ db }), "Fs.read"))
  local read_lines = docs.render(view({ db }), read[1])
  assert(read_lines[#read_lines] == "  used in 2 places; cosmic uses Fs.read",
    read_lines[#read_lines])
end

--- A symbol with a worked example renders its own doc comment and its
--- source, in that order, under `Fs.read`'s own doc comment; a
--- module's own listing marks which of its symbols have one. The
--- example is matched to `Fs.read` by its own code calling it, not by
--- its function name (`read`, here, could have been anything).
local function test_renders_a_symbols_example()
  local db = database(fs_rows, fs_uses, {
    { "cosmic.fs", "read", "Reads a file back.", "cosmic/fs_example.tl",
      "3", "function Example.read()\n  print(Fs.read(\"x\"))\nend" },
  })
  local read = assert(docs.lookup(view({ db }), "Fs.read"))
  local lines = docs.render(view({ db }), read[1])
  assert(lines[#lines - 4] == "  example read (cosmic/fs_example.tl:3):",
    lines[#lines - 4])
  assert(lines[#lines - 3] == "  Reads a file back.", lines[#lines - 3])
  assert(lines[#lines - 2] == "    function Example.read()", lines[#lines - 2])
  assert(lines[#lines - 1] == "      print(Fs.read(\"x\"))", lines[#lines - 1])
  assert(lines[#lines] == "    end", lines[#lines])

  local module = assert(docs.lookup(view({ db }), "cosmic.fs"))
  local module_lines = docs.render(view({ db }), module[1])
  assert(module_lines[4] == "  function Fs.read (2 uses, 1 example)", module_lines[4])
  assert(module_lines[5] == "  function Fs.write", module_lines[5])
end

--- Many examples can be for one symbol: each is matched independently
--- by its own code, so nothing caps how many turn up, and each keeps
--- its own name in the rendering to tell them apart.
local function test_many_examples_for_one_symbol()
  local db = database(fs_rows, fs_uses, {
    { "cosmic.fs", "basic", "", "cosmic/fs_example.tl", "3",
      "function Example.basic()\n  print(Fs.read(\"notes.txt\"))\nend" },
    { "cosmic.fs", "missing_file", "", "cosmic/fs_example.tl", "9",
      "function Example.missing_file()\n  local ok = Fs.read(\"none\")\nend" },
  })
  local read = assert(docs.lookup(view({ db }), "Fs.read"))
  local lines = docs.render(view({ db }), read[1])
  local headers: {string} = {}
  for _, line in ipairs(lines) do
    if line:match("^  example ") then
      headers[#headers + 1] = line
    end
  end
  assert(#headers == 2, table.concat(headers, " | "))
  assert(headers[1] == "  example basic (cosmic/fs_example.tl:3):", headers[1])
  assert(headers[2] == "  example missing_file (cosmic/fs_example.tl:9):", headers[2])

  local module = assert(docs.lookup(view({ db }), "cosmic.fs"))
  local module_lines = docs.render(view({ db }), module[1])
  assert(module_lines[4] == "  function Fs.read (2 uses, 2 examples)", module_lines[4])
end

--- FTS5 tokenizes on `_`, so `Hash.hex` and `Hash.hex_sha256` share
--- their first two tokens; an example that only ever calls
--- `Hash.hex_sha256` must not also match `Hash.hex`.
local function test_examples_do_not_match_a_shorter_symbol_sharing_a_prefix()
  local rows: {{string}} = {
    { "cosmic.hash", "", "module", "", "", "cosmic/hash.tl", "1" },
    { "cosmic.hash", "Hash", "record", "local record Hash", "", "cosmic/hash.tl", "5" },
    { "cosmic.hash", "Hash.hex", "function",
      "function Hash.hex(digest: string): string",
      "Hex encodes a digest.", "cosmic/hash.tl", "10" },
    { "cosmic.hash", "Hash.hex_sha256", "function",
      "function Hash.hex_sha256(data: string): string",
      "The hexadecimal SHA-256 of some bytes.", "cosmic/hash.tl", "20" },
  }
  local db = database(rows, {}, {
    { "cosmic.hash", "hex_sha256", "", "cosmic/hash_example.tl", "3",
      "function Example.hex_sha256()\n  print(Hash.hex_sha256(\"x\"))\nend" },
  })
  local hex = assert(docs.lookup(view({ db }), "Hash.hex"))
  assert(#hex == 1 and hex[1].examples == 0, tostring(hex[1].examples))
  for _, line in ipairs(docs.render(view({ db }), hex[1])) do
    assert(not line:match("^  example "),
      "Hash.hex wrongly matched an example for Hash.hex_sha256: " .. line)
  end

  local hex_sha256 = assert(docs.lookup(view({ db }), "Hash.hex_sha256"))
  assert(#hex_sha256 == 1 and hex_sha256[1].examples == 1)
end

--- A word only a worked example's own code or its own doc comment
--- mentions -- never in `Fs.read`'s own doc comment -- still finds
--- `cosmic.fs`, and renders the matching comment and checked source.
local function test_searches_finds_a_word_only_in_an_example()
  local db = database(fs_rows, fs_uses, {
    { "cosmic.fs", "read", "", "cosmic/fs_example.tl", "3",
      "function Example.read()\n  print(Hash.hex_sha256(Fs.read(\"x\")))\nend" },
  })
  local found = assert(docs.lookup(view({ db }), "hex_sha256"))
  local exact = found.exact
  assert(found ~= nil)
  assert(not exact)
  assert(#found == 1 and found[1].module == "cosmic.fs" and
    found[1].symbol == "Example.read",
    tostring(#found))
  local lines = docs.render(view({ db }), found[1])
  assert(lines[1] == "cosmic.fs example read (cosmic/fs_example.tl:3)", lines[1])
  assert(table.concat(lines, "\n"):find("Hash.hex_sha256(Fs.read", 1, true) ~= nil)

  local db2 = database(fs_rows, fs_uses, {
    { "cosmic.fs", "read", "Demonstrates reading a config file.",
      "cosmic/fs_example.tl", "3", "function Example.read()\nend" },
  })
  local by_text = assert(docs.lookup(view({ db2 }), "config"))
  assert(#by_text == 1 and by_text[1].module == "cosmic.fs" and
    by_text[1].symbol == "Example.read",
    tostring(#by_text))
  local text_lines = docs.render(view({ db2 }), by_text[1])
  assert(table.concat(text_lines, "\n"):find(
    "Demonstrates reading a config file.", 1, true) ~= nil)
end

--- A documentation comment ranks first, while the matching worked example is
--- also returned under its own identity and rendered only there.
local function test_search_keeps_docs_and_example_identities()
  local db = database(fs_rows, fs_uses, {
    { "cosmic.fs", "read_config", "Reads a whole config file.",
      "cosmic/fs_example.tl", "3",
      "function Example.read_config()\n  Fs.read(\"config\")\nend" },
  })
  local found = assert(docs.lookup(view({ db }), "whole config"))
  assert(#found == 1, "expected one example result")
  assert(found[1].symbol == "Example.read_config", found[1].symbol)
  local rendered = table.concat(docs.render(view({ db }), found[1]), "\n")
  assert(rendered:find("function Example.read_config()", 1, true) ~= nil, rendered)
end

--- Examples obey the same whole-module project precedence as docs: a
--- project's replacement is shown and the binary's older example is hidden.
local function test_example_search_obeys_module_ownership()
  local project = database(fs_rows, {}, {
    { "cosmic.fs", "new_read", "current sentinel contract",
      "cosmic/fs_example.tl", "3", "function Example.new_read()\nend" },
  })
  local binary = database(fs_rows, {}, {
    { "cosmic.fs", "old_read", "legacy sentinel contract",
      "cosmic/fs_example.tl", "3", "function Example.old_read()\nend" },
  })
  local current = assert(docs.lookup(view({ project, binary }), "current sentinel"))
  assert(#current == 1)
  assert(table.concat(docs.render(view({ project, binary }), current[1]), "\n"):
    find("Example.new_read", 1, true) ~= nil)
  assert(#assert(docs.lookup(view({ project, binary }), "legacy sentinel")) == 0)
end

--- The uses of a symbol, by either name.
local function test_lists_uses()
  local db = database(fs_rows, fs_uses)
  local found = assert(docs.uses(view({ db }), "read"))
  assert(#found == 2 and found[1].from_file == "build/boot.tl", tostring(#found))
  assert(#assert(docs.uses(view({ db }), "Fs.write")) == 0)
end

--- An earlier database owns a module as a whole: symbols removed by the
--- replacement cannot reappear from a later database.
local function test_an_earlier_database_hides_a_module_in_a_later_one()
  local project = database({
    { "cosmic.fs", "Fs.read", "function", "function Fs.read(path: string): string",
      "The project's own.", "cosmic/fs.tl", "5" },
  }, {})
  local binary = database(fs_rows, fs_uses)
  local read = assert(docs.lookup(view({ project, binary }), "read"))
  assert(#read == 1 and read[1].text == "The project's own.", tostring(#read))
  local write = assert(docs.lookup(view({ project, binary }), "Fs.write"))
  assert(#write == 0, "a removed symbol reappeared from the older module")
end

--- Membership owns a module even when it produced no documentation.
--- Old symbols and examples must both stay hidden.
local function test_an_undocumented_module_hides_old_docs_and_examples()
  local project = database({}, {}, {}, { "cosmic.fs" })
  local binary = database(fs_rows, {}, {
    { "cosmic.fs", "read", "legacy example", "cosmic/fs_example.tl", "3",
      "function Example.read()\n  Fs.read(\"x\")\nend" },
  })
  local layered = view({ project, binary })
  assert(#assert(docs.lookup(layered, "Fs.read")) == 0)
  assert(#assert(docs.lookup(layered, "legacy example")) == 0)
end

--- Uses belong to their calling module. Independent callers in later
--- databases survive, while a replaced caller's older positions do not.
local function test_uses_merge_active_calling_modules()
  local project = database({}, {
    { "external.api", "Api.call", "app.main", "app/main.tl", "9" },
  })
  local binary = database({
    { "external.api", "Api.call", "function", "function Api.call()",
      "Calls the API.", "external/api.tl", "5" },
  }, {
    { "external.api", "Api.call", "app.main", "old/app.tl", "4" },
    { "external.api", "Api.call", "lib.helper", "lib/helper.tl", "12" },
  })
  local found = assert(docs.uses(view({ project, binary }), "Api.call"))
  assert(#found == 2, tostring(#found))
  assert(found[1].from_file == "app/main.tl", found[1].from_file)
  assert(found[2].from_file == "lib/helper.tl", found[2].from_file)
  local entry = assert(docs.lookup(view({ project, binary }), "Api.call"))[1]
  assert(entry ~= nil and entry.uses == 2, tostring(entry and entry.uses))
end

--- From outside cosmic's own tree, the binary's database is a public
--- source: it answers for the standard library's own modules and for
--- nothing behind them -- not the build, not `cosmic.internal.*`, not
--- a test -- and counts only the uses those modules make.
local function test_a_public_source_answers_only_for_the_standard_library()
  local rows: {{string}} = {
    { "cosmic.fs", "", "module", "", "Files and directories.", "cosmic/fs.tl", "1" },
    { "cosmic.fs", "Fs.read", "function", "function Fs.read(path: string): string | nil, string",
      "The whole of a file.", "cosmic/fs.tl", "23" },
    { "build.importer", "", "module", "", "The tree, read by position.", "build/importer.tl", "1" },
    { "build.importer", "importer.read", "function", "function importer.read(path: string): string",
      "The whole of a file, staged.", "build/importer.tl", "9" },
    { "cosmic.internal.sqlite", "", "module", "", "SQLite at the Lua boundary.",
      "cosmic/internal/sqlite.d.tl", "1" },
    { "cosmic.internal.sqlite", "sqlite.read", "function", "read: function(Statement): string",
      "A raw read.", "cosmic/internal/sqlite.d.tl", "8" },
    { "cosmic.coverage_test", "", "module", "", "Proves coverage.", "cosmic/coverage_test.tl", "1" },
    { "cosmic.coverage_test", "test_read", "function", "local function test_read()",
      "Reads the whole of a file.", "cosmic/coverage_test.tl", "4" },
  }
  local uses: {{string}} = {
    { "cosmic.fs", "Fs.read", "build.boot", "build/boot.tl", "56" },
    { "cosmic.fs", "Fs.read", "cosmic.hash", "cosmic/hash.tl", "12" },
  }
  local modules = { "cosmic.fs", "build.importer", "cosmic.internal.sqlite",
    "cosmic.coverage_test", "build.boot", "cosmic.hash" }
  local db = database(rows, uses, {}, modules)

  local everything = assert(docs.view({ db }))
  assert(#assert(docs.lookup(everything, "read")) == 3)
  assert(#assert(docs.uses(everything, "read")) == 2)

  local public = assert(docs.view({ db }, { true }))
  local found = assert(docs.lookup(public, "read"))
  assert(#found == 1 and found[1].module == "cosmic.fs", tostring(#found))
  assert(found[1].uses == 1, "only the standard library's own use counts: " .. found[1].uses)
  assert(#assert(docs.lookup(public, "build.importer")) == 0, "the build is not a public module")
  local searched = assert(docs.lookup(public, "whole file"))
  assert(#searched == 1 and searched[1].module == "cosmic.fs", tostring(#searched))
  local referring = assert(docs.uses(public, "Fs.read"))
  assert(#referring == 1 and referring[1].from_module == "cosmic.hash")
  local listed = docs.render(public, assert(docs.lookup(public, "cosmic.fs"))[1])
  assert(listed[#listed]:find("Fs.read", 1, true) ~= nil, listed[#listed])
end

--- Counts use the same public target-and-caller boundary as the listed rows.
--- A binary row aimed at a private build name must not inflate an unrelated
--- project module that happens to own that path.
local function test_public_use_count_matches_list_across_project_collision()
  local project = database({
    { "build.helper", "Helper.run", "function", "function Helper.run()",
      "Runs the project helper.", "build/helper.tl", "4" },
  }, {})
  local binary = database({
    { "cosmic.fs", "Fs.read", "function", "function Fs.read()",
      "Reads a file.", "cosmic/fs.tl", "20" },
  }, {
    { "build.helper", "Helper.run", "cosmic.fs", "cosmic/fs.tl", "30" },
  }, {}, { "cosmic.fs" })
  local layered = assert(docs.view({ project, binary }, { false, true }))
  local entry = assert(docs.lookup(layered, "Helper.run"))[1]
  assert(entry ~= nil and entry.uses == 0, tostring(entry and entry.uses))
  assert(#assert(docs.uses(layered, "Helper.run")) == 0)
end

--- A module that is only a declaration -- `cosmic.sys`, generated from
--- a C header -- is owned through `decls`, and its rows, which carry
--- no line of their own, render without one.
local function test_a_declared_module_is_found_without_a_line()
  local rows: {{string}} = {
    { "cosmic.sys", "syscalls.lstat", "field",
      "lstat: function(path: string): Stat | nil, string, integer",
      "Describes a path, not a link's target.", "core/syscalls.h", "0" },
  }
  local db = database(rows, {}, nil, {})
  assert(db:exec("INSERT INTO decls (path, source) VALUES ('cosmic.sys', '')"))
  local found = assert(docs.lookup(view({ db }), "lstat"))
  assert(#found == 1 and found[1].module == "cosmic.sys", tostring(#found))
  local lines = docs.render(view({ db }), found[1])
  assert(lines[1] == "cosmic.sys syscalls.lstat (core/syscalls.h)", lines[1])
end
