local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local sys = require("cosmic.sys")
local docs = require("build.docs")
local fixture = require("build.docs_fixture")
local schema = require("build.schema")

--- Lines as one source file's text.
local function source(...: string): string
  return table.concat({ ... }, "\n") .. "\n"
end

--- The shipped database the tree `files` builds to, rows and all, as
--- `build.docs_fixture` makes it with the build's own code.
local function built(dir: string, files: {string: string}): Sqlite.Handle
  return fixture.database(dir, files)
end

--- One in-memory shipped database holding rows written by hand, for a
--- shape the build's projection of a tree never writes (each caller says
--- which). A row's eighth field is "private" for an unexported symbol,
--- its ninth its `source_symbol` when that differs from its symbol.
local function database(rows: {{string}}, uses: {{string}},
                        modules?: {string}): Sqlite.Handle
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
      "VALUES (?1, ?2, ?9, ?8, ?3, ?4, ?5, ?6, ?7)",
      { { text = row[1] }, { text = row[2] }, { text = row[3] }, { text = row[4] },
        { text = row[5] }, { text = row[6] }, { integer = math.tointeger(tonumber(row[7])) },
        { integer = row[8] == "private" and 0 or 1 }, { text = row[9] or row[2] } }))
  end
  for _, row in ipairs(uses) do
    assert(Sqlite.run(db,
      "INSERT INTO uses (module, symbol, from_module, from_file, line) " ..
      "VALUES (?1, ?2, ?3, ?4, ?5)",
      { { text = row[1] }, { text = row[2] }, { text = row[3] }, { text = row[4] },
        { integer = math.tointeger(tonumber(row[5])) } }))
  end
  assert(db:exec("INSERT INTO docs_fts(docs_fts) VALUES ('rebuild')"))
  assert(db:exec("INSERT INTO examples_fts(examples_fts) VALUES ('rebuild')"))
  return db
end

local function view(databases: {Sqlite.Handle}): docs.View
  return (assert(docs.view(databases)))
end

--- `cosmic.fs`, documented, and two modules that each read a file
--- through it: `build/boot.tl` on its line 3, `build/test.tl` on its 4.
local function fs_tree(extra?: {string: string}): {string: string}
  local files: {string: string} = {
    ["cosmic/fs.tl"] = source(
      "--- Files and directories.",
      "",
      "local record Fs",
      "end",
      "",
      "--- The whole of a file.",
      "function Fs.read(path: string): string | nil, string",
      "  return nil, path",
      "end",
      "",
      "--- Writes the whole of a file.",
      "--- Creates no parent directory.",
      "function Fs.write(path: string, data: string): boolean, string",
      "  return false, path .. data",
      "end",
      "",
      "return Fs"),
    ["build/boot.tl"] = source(
      "local Fs = require(\"cosmic.fs\")",
      "",
      "local text = Fs.read(\"boot\")",
      "return text"),
    ["build/test.tl"] = source(
      "local Fs = require(\"cosmic.fs\")",
      "",
      "",
      "local text = Fs.read(\"test\")",
      "return text"),
  }
  for path, text in pairs(extra or {}) do
    files[path] = text
  end
  return files
end

--- A worked example for `cosmic.fs`: `Example.<name>`, its doc comment
--- `text`, its body `body`, declared on line 7 of its file.
local function fs_example(name: string, text: string, body: string): string
  return source(
    "local Fs = require(\"cosmic.fs\")",
    "local Hash = require(\"cosmic.hash\")",
    "",
    "local record Example",
    "end",
    "",
    "--- " .. text,
    "function Example." .. name .. "()",
    body,
    "end",
    "",
    "return Example")
end

--- A symbol as declared is found by name, with its use count.
local function test_looks_up_a_symbol_as_declared(dir: string)
  local db = built(dir, fs_tree())
  local found, trouble = docs.lookup(view({ db }), "Fs.read")
  local exact = found ~= nil and found.exact
  assert(found ~= nil, trouble)
  assert(exact, "a declared name was not an exact match")
  assert(#found == 1 and found[1].source_symbol == "Fs.read", tostring(#found))
  assert(found[1].symbol == "read", found[1].symbol)
  assert(found[1].uses == 2, tostring(found[1].uses))
end

--- A symbol's last name alone finds every symbol ending in it.
local function test_looks_up_a_symbol_by_its_last_name(dir: string)
  local db = built(dir, fs_tree())
  local found = assert(docs.lookup(view({ db }), "read"))
  assert(#found == 1 and found[1].source_symbol == "Fs.read", tostring(#found))
end

--- A module's own name finds its module row; rendering it lists what
--- the module declares.
local function test_looks_up_a_module_and_lists_its_symbols(dir: string)
  local db = built(dir, fs_tree())
  local found = assert(docs.lookup(view({ db }), "cosmic.fs"))
  assert(#found == 1 and found[1].kind == "module", tostring(#found))
  local lines = assert(docs.render(view({ db }), found[1]))
  assert(lines[1] == "cosmic.fs (cosmic/fs.tl)", lines[1])
  assert(lines[2] == "  Files and directories.", lines[2])
  assert(lines[3] == "  record Fs", lines[3])
  assert(lines[4] == "  function Fs.read (2 uses)", lines[4])
  assert(lines[5] == "  function Fs.write", lines[5])
end

--- Asked nothing, docs lists every module with the first sentence of
--- its documentation (its record's when that is where it is said), an
--- undocumented one too, and no test or example;
--- a public source lists only the standard library.
local function test_the_index_lists_every_module_by_its_first_sentence(dir: string)
  local db = built(dir, fs_tree({
    ["cosmic/hash.tl"] = source(
      "--- Digests. Each answers bytes,",
      "--- never text.",
      "",
      "local record Hash",
      "end",
      "",
      "return Hash"),
    ["build/tree.tl"] = source(
      "--- The tree, read by",
      "--- position.",
      "",
      "local record tree",
      "end",
      "",
      "return tree"),
    ["cosmic/fs_test.tl"] = source(
      "--- Proves Fs.",
      "",
      "local function test_read()",
      "end"),
    ["cosmic/fs_example.tl"] = fs_example("read", "Reads a file.", "  local _ = Fs.read"),
    ["lib/bare.tl"] = source("return {}"),
    ["lib/tworec.tl"] = source(
      "local x = 1",
      "",
      "--- Not the module's: a record further down.",
      "local record A",
      "  y: integer",
      "end",
      "",
      "return { x = x, a = A }"),
    ["lib/sentence.tl"] = source(
      "--- ",
      "--- Reads, e.g. a file, with `a. b` inside. Then more.",
      "",
      "return {}"),
    ["lib/onrecord.tl"] = source(
      "--- Said on the record. More.",
      "local record onrecord",
      "  --- A field.",
      "  x: integer",
      "end",
      "",
      "return onrecord"),
  }))
  local index = assert(docs.index(view({ db })))
  local lines: {string} = {}
  for _, summary in ipairs(index) do
    lines[#lines + 1] = summary.module .. "|" .. summary.text
  end
  local all = table.concat(lines, "\n")
  assert(all == "build.boot|\nbuild.test|\nbuild.tree|The tree, read by position.\n" ..
    "cosmic.fs|Files and directories.\n" ..
    "cosmic.hash|Digests.\nlib.bare|\nlib.onrecord|Said on the record.\n" ..
    "lib.sentence|Reads, e.g. a file, with `a. b` inside.\nlib.tworec|", all)
  local public = assert(docs.index((assert(docs.view({ db }, { true })))))
  assert(#public == 2 and public[1].module == "cosmic.fs" and
    public[2].module == "cosmic.hash", tostring(#public))
end

--- A module's listing leaves out the functions its returned value never
--- reaches, but keeps the types it declares; a private function is still
--- found by its own name.
local function test_a_module_listing_leaves_out_private_functions(dir: string)
  local db = built(dir, { ["cosmic/fs.tl"] = source(
    "--- Files and directories.",
    "",
    "local record Stat",
    "end",
    "",
    "local record Fs",
    "end",
    "",
    "local function write_all(fd: integer)",
    "end",
    "",
    "function Fs.read(path: string): string",
    "  return path",
    "end",
    "",
    "return Fs") })
  local found = assert(docs.lookup(view({ db }), "cosmic.fs"))
  local lines = assert(docs.render(view({ db }), found[1]))
  assert(lines[3] == "  record Stat", lines[3])
  assert(lines[4] == "  record Fs", lines[4])
  assert(lines[5] == "  function Fs.read", lines[5])
  assert(lines[6] == nil, lines[6])
  local helper = assert(docs.lookup(view({ db }), "write_all"))
  assert(#helper == 1 and helper[1].symbol == "write_all", tostring(#helper))
end

--- Words that name no symbol search the documentation, every word
--- required, and a name nothing matches finds nothing.
local function test_searches_the_documentation_for_words(dir: string)
  local db = built(dir, fs_tree())
  local words = assert(docs.lookup(view({ db }), "whole file"))
  local exact = words.exact
  assert(words ~= nil)
  assert(not exact)
  assert(#words == 2, tostring(#words))
  local one = assert(docs.lookup(view({ db }), "parent directory"))
  assert(#one == 1 and one[1].source_symbol == "Fs.write")
  local none = assert(docs.lookup(view({ db }), "nothing_like_this"))
  assert(#none == 0)
end

--- A qualified name that names nothing answers from its qualifier:
--- the members whose documentation carries the last name, or every
--- exported function when none does -- never what another module's
--- documentation happens to say.
local function test_a_qualified_miss_answers_from_its_qualifier(dir: string)
  local db = built(dir, {
    ["cosmic/fs.tl"] = source(
      "--- Files and directories.",
      "",
      "local record Fs",
      "end",
      "",
      "--- The whole of a file.",
      "function Fs.read(path: string): string",
      "  return path",
      "end",
      "",
      "--- Writes the whole of a file.",
      "--- Creates no parent directory.",
      "function Fs.write(path: string, data: string): boolean",
      "  return path == data",
      "end",
      "",
      "--- Copies a file's bytes.",
      "local function copy_bytes(fd: integer)",
      "end",
      "",
      "return Fs"),
    ["cosmic/proc.tl"] = source(
      "local record Proc",
      "end",
      "",
      "--- Where a program runs from, as `which` finds it; every file on the PATH is read.",
      "function Proc.find(name: string): string",
      "  return name",
      "end",
      "",
      "return Proc"),
  })
  local near = assert(docs.lookup(view({ db }), "Fs.parent"))
  assert(not near.exact)
  assert(#near == 1 and near[1].source_symbol == "Fs.write", tostring(#near))
  local all = assert(docs.lookup(view({ db }), "Fs.slurp"))
  assert(#all == 2 and all[1].source_symbol == "Fs.read" and
    all[2].source_symbol == "Fs.write", tostring(#all))
  local which = assert(docs.lookup(view({ db }), "Proc.which"))
  assert(#which == 1 and which[1].source_symbol == "Proc.find", tostring(#which))
  -- "file" is in Fs's documentation too; Proc's qualifier keeps it out.
  local file = assert(docs.lookup(view({ db }), "Proc.file"))
  assert(#file == 1 and file[1].source_symbol == "Proc.find", tostring(#file))
  -- A private helper is not something the qualifier offers.
  local bytes = assert(docs.lookup(view({ db }), "Fs.bytes"))
  for _, entry in ipairs(bytes) do
    assert(entry.symbol ~= "copy_bytes", "a private helper was offered")
  end
end

--- A word the documentation spells as code outranks one it only uses,
--- unless that word is one of the function's own parameters, which
--- documentation spells as code everywhere.
local function test_a_search_ranks_what_a_function_stands_in_for(dir: string)
  local db = built(dir, {
    ["cosmic/proc.tl"] = source(
      "local record Proc",
      "end",
      "",
      "--- Where a program runs from, as `which` finds it; `name` itself when it holds",
      "--- a slash.",
      "function Proc.find(name: string): string",
      "  return name",
      "end",
      "",
      "return Proc"),
    ["cosmic/time.tl"] = source(
      "local record Time",
      "  --- The clock which steps.",
      "  CLOCK: integer",
      "end",
      "",
      "return Time"),
    ["cosmic/env.tl"] = source(
      "local record Env",
      "end",
      "",
      "--- A variable's value, looked up by its exact `name` in this process's",
      "--- environment as it stands when called, or nil when it is unset.",
      "function Env.get(name: string): string",
      "  return name",
      "end",
      "",
      "--- Each variable name.",
      "function Env.names(): {string}",
      "  return {}",
      "end",
      "",
      "return Env"),
  })
  local which = assert(docs.lookup(view({ db }), "which"))
  assert(which[1].source_symbol == "Proc.find", which[1].source_symbol)
  -- Both spell `name` as code, but as their parameter: neither is
  -- boosted over the shorter match.
  local name = assert(docs.lookup(view({ db }), "name variable"))
  assert(name[1].source_symbol == "Env.names", name[1].source_symbol)
end

--- A one-letter word is a flag no documentation spells alone, so a
--- search leaves it out rather than finding nothing.
local function test_a_search_leaves_out_one_letter_words(dir: string)
  local db = built(dir, fs_tree())
  local found = assert(docs.lookup(view({ db }), "parent directory -p"))
  assert(#found == 1 and found[1].source_symbol == "Fs.write", tostring(#found))
  -- A query of nothing else still searches for what it has.
  local lone = built(dir, { ["cosmic/fs.tl"] = source(
    "local record Fs",
    "end",
    "",
    "--- Axis x.",
    "function Fs.x()",
    "end",
    "",
    "return Fs") })
  local x = assert(docs.lookup(view({ lone }), "x -"))
  assert(#x == 1, tostring(#x))
end

--- A symbol renders as where it is, its signature, its documentation
--- line by line, and how it is used.
local function test_renders_a_symbol(dir: string)
  local db = built(dir, fs_tree())
  local found = assert(docs.lookup(view({ db }), "Fs.write"))
  local lines = assert(docs.render(view({ db }), found[1]))
  assert(lines[1] == "cosmic.fs Fs.write (cosmic/fs.tl:13)", lines[1])
  assert(lines[2] == "  function Fs.write(path: string, data: string): boolean, string", lines[2])
  assert(lines[3] == "  Writes the whole of a file.", lines[3])
  assert(lines[4] == "  Creates no parent directory.", lines[4])
  assert(#lines == 4, tostring(#lines))
  local read = assert(docs.lookup(view({ db }), "Fs.read"))
  local read_lines = assert(docs.render(view({ db }), read[1]))
  assert(read_lines[#read_lines] == "  used in 2 places; cosmic uses Fs.read",
    read_lines[#read_lines])
end

--- A symbol with a worked example renders its own doc comment and its
--- source, in that order, under `Fs.read`'s own doc comment; a
--- module's own listing marks which of its symbols have one. The
--- example is matched to `Fs.read` by its own code calling it, not by
--- its function name (`read`, here, could have been anything). An
--- example's own call is a use, as any module's is.
local function test_renders_a_symbols_example(dir: string)
  local db = built(dir, fs_tree({
    ["cosmic/fs_example.tl"] = fs_example("read", "Reads a file back.",
      "  print(Fs.read(\"x\"))"),
  }))
  local read = assert(docs.lookup(view({ db }), "Fs.read"))
  local lines = assert(docs.render(view({ db }), read[1]))
  assert(lines[#lines - 4] == "  example read (cosmic/fs_example.tl:8):",
    lines[#lines - 4])
  assert(lines[#lines - 3] == "  Reads a file back.", lines[#lines - 3])
  assert(lines[#lines - 2] == "    function Example.read()", lines[#lines - 2])
  assert(lines[#lines - 1] == "      print(Fs.read(\"x\"))", lines[#lines - 1])
  assert(lines[#lines] == "    end", lines[#lines])

  local module = assert(docs.lookup(view({ db }), "cosmic.fs"))
  local module_lines = assert(docs.render(view({ db }), module[1]))
  assert(module_lines[4] == "  function Fs.read (3 uses, 1 example)", module_lines[4])
  assert(module_lines[5] == "  function Fs.write", module_lines[5])
end

--- Many examples can be for one symbol: each is matched independently
--- by its own code, so nothing caps how many turn up, and each keeps
--- its own name in the rendering to tell them apart.
local function test_many_examples_for_one_symbol(dir: string)
  local db = built(dir, fs_tree({
    ["cosmic/fs_example.tl"] = source(
      "local Fs = require(\"cosmic.fs\")",
      "",
      "local record Example",
      "end",
      "",
      "function Example.basic()",
      "  print(Fs.read(\"notes.txt\"))",
      "end",
      "",
      "function Example.missing_file()",
      "  local ok = Fs.read(\"none\")",
      "end",
      "",
      "return Example"),
  }))
  local read = assert(docs.lookup(view({ db }), "Fs.read"))
  local lines = assert(docs.render(view({ db }), read[1]))
  local headers: {string} = {}
  for _, line in ipairs(lines) do
    if line:match("^  example ") then
      headers[#headers + 1] = line
    end
  end
  assert(#headers == 2, table.concat(headers, " | "))
  assert(headers[1] == "  example basic (cosmic/fs_example.tl:6):", headers[1])
  assert(headers[2] == "  example missing_file (cosmic/fs_example.tl:10):", headers[2])

  local module = assert(docs.lookup(view({ db }), "cosmic.fs"))
  local module_lines = assert(docs.render(view({ db }), module[1]))
  assert(module_lines[4] == "  function Fs.read (4 uses, 2 examples)", module_lines[4])
end

--- FTS5 tokenizes on `_`, so `Hash.hex` and `Hash.hex_sha256` share
--- their first two tokens; an example that only ever calls
--- `Hash.hex_sha256` must not also match `Hash.hex`.
local function test_examples_do_not_match_a_shorter_symbol_sharing_a_prefix(dir: string)
  local db = built(dir, {
    ["cosmic/hash.tl"] = source(
      "local record Hash",
      "end",
      "",
      "--- Hex encodes a digest.",
      "function Hash.hex(digest: string): string",
      "  return digest",
      "end",
      "",
      "--- The hexadecimal SHA-256 of some bytes.",
      "function Hash.hex_sha256(data: string): string",
      "  return data",
      "end",
      "",
      "return Hash"),
    ["cosmic/hash_example.tl"] = source(
      "local Hash = require(\"cosmic.hash\")",
      "",
      "local record Example",
      "end",
      "",
      "function Example.hex_sha256()",
      "  print(Hash.hex_sha256(\"x\"))",
      "end",
      "",
      "return Example"),
  })
  local hex = assert(docs.lookup(view({ db }), "Hash.hex"))
  assert(#hex == 1 and hex[1].examples == 0, tostring(hex[1].examples))
  for _, line in ipairs((assert(docs.render(view({ db }), hex[1])))) do
    assert(not line:match("^  example "),
      "Hash.hex wrongly matched an example for Hash.hex_sha256: " .. line)
  end

  local hex_sha256 = assert(docs.lookup(view({ db }), "Hash.hex_sha256"))
  assert(#hex_sha256 == 1 and hex_sha256[1].examples == 1)
end

--- A word only a worked example's own code or its own doc comment
--- mentions -- never in `Fs.read`'s own doc comment -- still finds
--- `cosmic.fs`, and renders the matching comment and checked source.
local function test_searches_finds_a_word_only_in_an_example(dir: string)
  local db = built(dir, fs_tree({
    ["cosmic/fs_example.tl"] = fs_example("read", "Reads a digest.",
      "  print(Hash.hex_sha256(Fs.read(\"x\")))"),
  }))
  local found = assert(docs.lookup(view({ db }), "hex_sha256"))
  local exact = found.exact
  assert(found ~= nil)
  assert(not exact)
  assert(#found == 1 and found[1].module == "cosmic.fs" and
    found[1].symbol == "Example.read",
    tostring(#found))
  local lines = assert(docs.render(view({ db }), found[1]))
  assert(lines[1] == "cosmic.fs example read (cosmic/fs_example.tl:8)", lines[1])
  assert(table.concat(lines, "\n"):find("Hash.hex_sha256(Fs.read", 1, true) ~= nil)

  local db2 = built(dir, fs_tree({
    ["cosmic/fs_example.tl"] = fs_example("read",
      "Demonstrates reading a config file.", ""),
  }))
  local by_text = assert(docs.lookup(view({ db2 }), "config"))
  assert(#by_text == 1 and by_text[1].module == "cosmic.fs" and
    by_text[1].symbol == "Example.read",
    tostring(#by_text))
  local text_lines = assert(docs.render(view({ db2 }), by_text[1]))
  assert(table.concat(text_lines, "\n"):find(
    "Demonstrates reading a config file.", 1, true) ~= nil)
end

--- A documentation comment ranks first, while the matching worked example is
--- also returned under its own identity and rendered only there.
local function test_search_keeps_docs_and_example_identities(dir: string)
  local db = built(dir, fs_tree({
    ["cosmic/fs_example.tl"] = fs_example("read_config", "Reads a whole config file.",
      "  Fs.read(\"config\")"),
  }))
  local found = assert(docs.lookup(view({ db }), "whole config"))
  assert(#found == 1, "expected one example result")
  assert(found[1].symbol == "Example.read_config", found[1].symbol)
  local rendered = table.concat(assert(docs.render(view({ db }), found[1])), "\n")
  assert(rendered:find("function Example.read_config()", 1, true) ~= nil, rendered)
end

--- Examples obey the same whole-module project precedence as docs: a
--- project's replacement is shown and the binary's older example is hidden.
local function test_example_search_obeys_module_ownership(dir: string)
  local project = built(dir, fs_tree({
    ["cosmic/fs_example.tl"] = fs_example("new_read", "current sentinel contract", ""),
  }))
  local binary = built(dir, fs_tree({
    ["cosmic/fs_example.tl"] = fs_example("old_read", "legacy sentinel contract", ""),
  }))
  local current = assert(docs.lookup(view({ project, binary }), "current sentinel"))
  assert(#current == 1)
  assert(table.concat(assert(docs.render(view({ project, binary }), current[1])), "\n"):
    find("Example.new_read", 1, true) ~= nil)
  assert(#assert(docs.lookup(view({ project, binary }), "legacy sentinel")) == 0)
end

--- The uses of a symbol, by either name.
local function test_lists_uses(dir: string)
  local db = built(dir, fs_tree())
  local found = assert(docs.uses(view({ db }), "read"))
  assert(#found == 2 and found[1].from_file == "build/boot.tl", tostring(#found))
  assert(found[1].line == 3, tostring(found[1].line))
  assert(#assert(docs.uses(view({ db }), "Fs.read")) == 2)
  assert(#assert(docs.uses(view({ db }), "Fs.write")) == 0)
end

--- A name spelled from a module's record down is a use of the member
--- it ends in, and of nothing else with the same last name: a use is
--- recorded without the module's own record (`write`, `Writer.write`).
--- Written by hand: `Writer.add_file` is a use through a typed
--- value, which only a compile finds (see `build.docs_fixture`).
local function test_a_qualified_name_lists_only_its_own_uses()
  local db = database({}, {
    { "cosmic.fs", "write", "build.boot", "build/boot.tl", "10" },
    { "cosmic.stream", "Writer.write", "build.test", "build/test.tl", "20" },
    { "cosmic.zip", "Writer.add_file", "build.boot", "build/boot.tl", "30" },
  })
  local writer = assert(docs.uses(view({ db }), "Stream.Writer.write"))
  assert(#writer == 1 and writer[1].module == "cosmic.stream", tostring(#writer))
  local fs = assert(docs.uses(view({ db }), "Fs.write"))
  assert(#fs == 1 and fs[1].module == "cosmic.fs", tostring(#fs))
  local method = assert(docs.uses(view({ db }), "Fs:write"))
  assert(#method == 1 and method[1].module == "cosmic.fs", tostring(#method))
  assert(#assert(docs.uses(view({ db }), "write")) == 2, "a last name finds both")
  -- `Writer` may be a module's own record, as `Fs` is: the uses table
  -- keeps no record names to tell.
  assert(#assert(docs.uses(view({ db }), "Writer.write")) == 2)
  assert(#assert(docs.uses(view({ db }), "Zip.Writer.add_file")) == 1)
  assert(#assert(docs.uses(view({ db }), "cosmic.Zip.Writer.add_file")) == 0,
    "one name past the record, and no more")
end

--- An earlier database owns a module as a whole: symbols removed by the
--- replacement cannot reappear from a later database.
local function test_an_earlier_database_hides_a_module_in_a_later_one(dir: string)
  local project = built(dir, { ["cosmic/fs.tl"] = source(
    "local record Fs",
    "end",
    "",
    "--- The project's own.",
    "function Fs.read(path: string): string",
    "  return path",
    "end",
    "",
    "return Fs") })
  local binary = built(dir, fs_tree())
  local read = assert(docs.lookup(view({ project, binary }), "read"))
  assert(#read == 1 and read[1].text == "The project's own.", tostring(#read))
  local write = assert(docs.lookup(view({ project, binary }), "Fs.write"))
  for _, entry in ipairs(write) do
    assert(entry.source_symbol ~= "Fs.write",
      "a removed symbol reappeared from the older module")
  end
end

--- Membership owns a module even when it produced no documentation.
--- Old symbols and examples must both stay hidden.
local function test_an_undocumented_module_hides_old_docs_and_examples(dir: string)
  local project = built(dir, { ["cosmic/fs.tl"] = source("return {}") })
  local binary = built(dir, fs_tree({
    ["cosmic/fs_example.tl"] = fs_example("read", "legacy example", "  Fs.read(\"x\")"),
  }))
  local layered = view({ project, binary })
  assert(#assert(docs.lookup(layered, "Fs.read")) == 0)
  assert(#assert(docs.lookup(layered, "legacy example")) == 0)
end

--- Uses belong to their calling module. Independent callers in later
--- databases survive, while a replaced caller's older positions do not.
local function test_uses_merge_active_calling_modules(dir: string)
  local project = built(dir, { ["app/main.tl"] = source(
    "local Api = require(\"external.api\")",
    "",
    "",
    "",
    "",
    "",
    "",
    "",
    "Api.call()") })
  local binary = built(dir, {
    ["external/api.tl"] = source(
      "local record Api",
      "end",
      "",
      "--- Calls the API.",
      "function Api.call()",
      "end",
      "",
      "return Api"),
    ["app/main.tl"] = source(
      "local Api = require(\"external.api\")",
      "",
      "",
      "Api.call()"),
    ["lib/helper.tl"] = source(
      "local Api = require(\"external.api\")",
      "",
      "Api.call()"),
  })
  local found = assert(docs.uses(view({ project, binary }), "Api.call"))
  assert(#found == 2, tostring(#found))
  assert(found[1].from_file == "app/main.tl" and found[1].line == 9,
    found[1].from_file .. ":" .. found[1].line)
  assert(found[2].from_file == "lib/helper.tl", found[2].from_file)
  local entry = assert(docs.lookup(view({ project, binary }), "Api.call"))[1]
  assert(entry ~= nil and entry.uses == 2, tostring(entry and entry.uses))
end

--- From outside cosmic's own tree, the binary's database is a public
--- source: it answers for the standard library's own modules and for
--- nothing behind them -- not the build, not `cosmic.internal.*`, not
--- a test -- and counts only the uses those modules make.
local function test_a_public_source_answers_only_for_the_standard_library(dir: string)
  local db = built(dir, {
    ["cosmic/fs.tl"] = source(
      "--- Files and directories.",
      "",
      "local record Fs",
      "end",
      "",
      "--- The whole of a file.",
      "function Fs.read(path: string): string | nil, string",
      "  return nil, path",
      "end",
      "",
      "return Fs"),
    ["build/importer.tl"] = source(
      "--- The tree, read by position.",
      "",
      "local record importer",
      "end",
      "",
      "--- The whole of a file, staged.",
      "function importer.read(path: string): string",
      "  return path",
      "end",
      "",
      "return importer"),
    ["cosmic/internal/sqlite.d.tl"] = source(
      "--- SQLite at the Lua boundary.",
      "",
      "local record sqlite",
      "  --- A raw read.",
      "  read: function(Statement): string",
      "end",
      "",
      "return sqlite"),
    ["cosmic/coverage_test.tl"] = source(
      "--- Proves coverage.",
      "",
      "--- Reads the whole of a file.",
      "local function test_read()",
      "end"),
    ["build/boot.tl"] = source(
      "local Fs = require(\"cosmic.fs\")",
      "",
      "local text = Fs.read(\"boot\")",
      "return text"),
    ["cosmic/hash.tl"] = source(
      "local Fs = require(\"cosmic.fs\")",
      "",
      "local text = Fs.read(\"hash\")",
      "return text"),
  })

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
  local listed = assert(docs.render(public, assert(docs.lookup(public, "cosmic.fs"))[1]))
  assert(listed[#listed]:find("Fs.read", 1, true) ~= nil, listed[#listed])
end

--- Counts use the same public target-and-caller boundary as the listed rows.
--- A binary row aimed at a private build name must not inflate an unrelated
--- project module that happens to own that path.
local function test_public_use_count_matches_list_across_project_collision(dir: string)
  local project = built(dir, { ["build/helper.tl"] = source(
    "local record Helper",
    "end",
    "",
    "--- Runs the project helper.",
    "function Helper.run()",
    "end",
    "",
    "return Helper") })
  local binary = built(dir, { ["cosmic/fs.tl"] = source(
    "local Helper = require(\"build.helper\")",
    "",
    "local record Fs",
    "end",
    "",
    "--- Reads a file.",
    "function Fs.read()",
    "  Helper.run()",
    "end",
    "",
    "return Fs") })
  local layered = assert(docs.view({ project, binary }, { false, true }))
  local entry = assert(docs.lookup(layered, "Helper.run"))[1]
  assert(entry ~= nil and entry.uses == 0, tostring(entry and entry.uses))
  assert(#assert(docs.uses(layered, "Helper.run")) == 0)
end

--- A module that is only a declaration -- `cosmic.sys`, generated from
--- a C header -- is owned through `decls`, and its rows, which carry
--- no line of their own, render without one. Written by hand: which
--- rows carry no line is the header generator's own line map's to say,
--- and this pins how such a row renders, whatever the header holds.
local function test_a_declared_module_is_found_without_a_line()
  local rows: {{string}} = {
    { "cosmic.sys", "syscalls.lstat", "field",
      "lstat: function(path: string): Stat | nil, string, integer",
      "Describes a path, not a link's target.", "core/syscalls.h", "0" },
  }
  local db = database(rows, {}, {})
  assert(db:exec("INSERT INTO decls (path, source) VALUES ('cosmic.sys', '')"))
  local found = assert(docs.lookup(view({ db }), "lstat"))
  assert(#found == 1 and found[1].module == "cosmic.sys", tostring(#found))
  local lines = assert(docs.render(view({ db }), found[1]))
  assert(lines[1] == "cosmic.sys syscalls.lstat (core/syscalls.h)", lines[1])
end

--- A database that copied a declaration without its documentation --
--- an executable's own, which carries every declaration it was built
--- against -- does not hide the database that documents it. Written by
--- hand: that copy is `build.embed`'s shape, not the build's.
local function test_an_undocumented_declaration_does_not_hide_a_documented_one()
  local copy = database({}, {}, {})
  assert(copy:exec("INSERT INTO decls (path, source) VALUES ('cosmic.sys', '')"))
  local rows: {{string}} = {
    { "cosmic.sys", "syscalls.lstat", "field", "lstat: function(path: string)",
      "Describes a path.", "core/syscalls.h", "154" },
  }
  local documented = database(rows, {}, {})
  assert(documented:exec("INSERT INTO decls (path, source) VALUES ('cosmic.sys', '')"))
  local found = assert(docs.lookup(view({ copy, documented }), "lstat"))
  assert(#found == 1 and found[1].line == 154, tostring(#found))
end

--- A project's own o/cosmic.db that is not a database is left out,
--- rather than failing every lookup: help and docs still answer from
--- the binary's own databases.
local function test_an_unreadable_own_database_is_left_out(dir: string)
  assert(Fs.mkdirs(dir .. "/o"))
  assert(Fs.write(dir .. "/o/cosmic.db", "not a database"))
  local before = assert(sys.getcwd())
  assert(sys.chdir(dir))
  local sources = docs.databases()
  assert(sys.chdir(before))
  local looked = assert(docs.view(sources.handles, sources.public))
  local found = assert(docs.lookup(looked, "Fs.read"))
  assert(#found > 0 and found.exact)
end

--- What a newcomer types first is the command or call they would have
--- used elsewhere. Each of these, looked up the way a project sees the
--- standard library, answers with the function that stands in for it
--- first, after any raw `cosmic.sys` binding of that name -- so a doc
--- comment that stops naming its command is caught here, not by the
--- next person who writes the function again.
local function test_a_familiar_command_finds_its_stand_in()
  -- Read from this tree's own o/cosmic.db, which the build rewrites
  -- before any test runs: a doc comment edit changes that file, and
  -- so this test's verdict key, and the test runs again.
  -- TODO: SQLite opens that file in C, which the verdict key does not
  -- observe, so this test stands across a rewrite of it; open it
  -- through `Fs` first, as build/exports_test.tl does, or have
  -- build.filesystem_observations see an `Sqlite.open`.
  local handles = docs.databases().handles
  local public: {boolean} = {}
  for index = 1, #handles do public[index] = true end
  local looked = assert(docs.view(handles, public))
  local stand_ins: {{string}} = {
    { "which", "Proc.find" },
    { "command -v", "Proc.find" },
    { "Proc.which", "Proc.find" },
    { "cp -R", "Fs.copy_tree" },
    { "mkdir -p", "Fs.mkdirs" },
    { "rm -rf", "Fs.remove_tree" },
    { "unlink", "Fs.remove" },
    { "ls", "Fs.list" },
    { "find type", "Fs.walk" },
    { "mktemp", "Fs.mkdtemp" },
    { "realpath", "Fs.absolute" },
    { "mv", "Fs.rename" },
    { "ln -s", "Fs.symlink" },
    { "touch", "Fs.set_mtime" },
    { "nproc", "Proc.cpu_count" },
    { "isatty", "Proc.is_tty" },
    { "getpid", "Proc.pid" },
    { "curl", "Http.download" },
    { "wget", "Http.download" },
    { "tar -x", "Archive.extract" },
    { "unzip", "Archive.extract" },
    { "sha256sum", "Hash.hex_sha256" },
    { "sleep", "Time.sleep_ns" },
    { "getentropy", "Rand.entropy" },
    { "getenv", "Env.get" },
    { "urandom", "Rand.entropy" },
  }
  local wrong: {string} = {}
  for _, case in ipairs(stand_ins) do
    -- A raw binding of the same name may come first; what stands in
    -- for it must come right after.
    local found = assert(docs.lookup(looked, case[1]))
    local first = "nothing"
    for _, entry in ipairs(found) do
      if entry.module ~= "cosmic.sys" then
        first = entry.source_symbol
        break
      end
    end
    if first ~= case[2] then
      wrong[#wrong + 1] = case[1] .. " -> " .. first .. ", not " .. case[2]
    end
  end
  assert(#wrong == 0, table.concat(wrong, "; "))
end
