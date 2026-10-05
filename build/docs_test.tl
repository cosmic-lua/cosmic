local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local Test = require("cosmic.test")
local docs = require("build.docs")
local sys = require("cosmic.sys")
local fixture = require("build.docs_fixture")
local schema = require("build.schema")
local symbols = require("build.symbols")

--- Whether the tree is cosmic's own. No test here reads the binary's
--- own databases, or the tree's o/cosmic.db, whole: [`docs.databases`]
--- is handed databases of the test's own in the store's place.
Test.policy{ grants = { { path = "core", letters = "r" } } }

--- Lines as one source file's text.
local function source(...: string): string
  return table.concat({ ... }, "\n") .. "\n"
end

--- The shipped database the tree `files` builds to, rows and all, as
--- [`build.docs_fixture`] makes it with the build's own code.
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
      "INSERT INTO modules (path, file, kind, source_hash, key, source, " ..
        "bytecode, tests) VALUES (?1, ?2, 'module', '', '', '', '', '')",
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

--- [`cosmic.fs`], documented, and two modules that each read a file
--- through it: [`build/boot.tl`] on its line 3, [`build/test.tl`] on its 4.
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

--- A worked example for [`cosmic.fs`]: `Example.<name>`, its doc comment
--- `text`, its body `body`, declared on line 8 of its file.
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
  assert(lines[3] == "", lines[3])
  assert(lines[4] == "  record Fs", lines[4])
  assert(lines[5] == "  function Fs.read(path: string): string | nil, string -- The whole of a file.  " ..
      "(2 uses)", lines[5])
  assert(lines[6] == "  function Fs.write(path: string, data: string): boolean, string -- " ..
      "Writes the whole of a file.",
    lines[6])
end

--- A module's listing shows each call with the first sentence of its
--- doc, cut short past a glance, and the page ends by naming how to see
--- a member's own page: through a call with an example where one has
--- one, as that page shows it, though another is used more.
local function test_a_module_listing_says_what_each_call_does(dir: string)
  local long = string.rep("word ", 30)
  local db = built(dir, fs_tree({
    ["cosmic/fs_example.tl"] = fs_example("put", "Writes a file.",
      "  print(Fs.write(\"x\", \"y\"))"),
    ["cosmic/fs.tl"] = source(
      "--- Files and directories.",
      "",
      "local record Fs",
      "end",
      "",
      "--- " .. long .. "and more. A second sentence.",
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
  }))
  local found = assert(docs.lookup(view({ db }), "cosmic.fs"))
  local lines = assert(docs.render(view({ db }), found[1]))
  local read = assert(lines[5]:match("^  function Fs%.read%(path: string%): string | nil, string %-%- (.*)$"),
    lines[5])
  assert(read:find("^word word") and read:find("…", 1, true) and not read:find("second", 1, true),
    read)
  assert(lines[6]:find(" -- Writes the whole of a file.  (", 1, true) and
      not lines[6]:find("Creates", 1, true), lines[6])
  assert(lines[4] == "  record Fs  (1 example)", lines[4])
  assert(lines[#lines] ==
      "  a symbol's own page has its whole doc and its examples: cosmic docs Fs.write", lines[#lines])
end

--- A module that lists no call names none to see: its first
--- declaration, its own record here, answers as the module itself.
local function test_a_module_page_with_no_call_points_at_nothing(dir: string)
  local db = built(dir, { ["cosmic/consts.tl"] = source(
    "--- Constants.",
    "",
    "local record consts",
    "  --- The most.",
    "  limit: integer",
    "end",
    "",
    "return consts") })
  local found = assert(docs.lookup(view({ db }), "cosmic.consts"))
  local text = table.concat(assert(docs.render(view({ db }), found[1])), "\n")
  assert(not text:find("own page", 1, true), text)
end

--- A module's listing shows each function's signature, so a reader need
--- not infer its arguments from examples; a record stays kind and name,
--- and the listing comes before the rest of the module's prose.
local function test_a_module_listing_shows_signatures(dir: string)
  local db = built(dir, fs_tree({ ["cosmic/fs.tl"] = source(
    "--- Files and directories.",
    "---",
    "--- Long prose after the first paragraph.",
    "",
    "local record Fs",
    "  record Opts",
    "    mode: integer",
    "  end",
    "end",
    "",
    "function Fs.read(path: string, opts?: Fs.Opts): string | nil, string",
    "  return nil, path",
    "end",
    "",
    "return Fs") }))
  local found = assert(docs.lookup(view({ db }), "cosmic.fs"))
  local lines = assert(docs.render(view({ db }), found[1]))
  local text = table.concat(lines, "\n")
  assert(text:find("  function Fs.read(path: string, opts?: Fs.Opts): string | nil, string",
    1, true), text)
  assert(not text:find("function Fs.read (", 1, true), text)
  assert(text:find("  record Fs\n", 1, true), text)
  assert(not text:find("record Fs {", 1, true), text)
  assert(text:find("  record Fs.Opts\n    mode: integer\n", 1, true), text)
  local listing = text:find("  function Fs.read(", 1, true)
  local prose = text:find("Long prose after", 1, true)
  assert(listing ~= nil and prose ~= nil and listing < prose, text)
end

--- A module whose own record declares its calls as function-typed
--- fields (as [`cosmic.sys`] does) lists each with its signature, as a
--- function, ahead of the prose.
local function test_a_module_listing_shows_function_typed_fields(dir: string)
  local db = built(dir, { ["cosmic/calls.tl"] = source(
    "--- A table of calls.",
    "---",
    "--- Long prose after the first paragraph.",
    "",
    "local record calls",
    "  --- What a path is.",
    "  record Stat",
    "    size: integer",
    "    visit: function(path: string): boolean",
    "  end",
    "",
    "  --- Whether a path exists.",
    "  exists: function(path: string): boolean, string, integer",
    "  --- No parameters, no results.",
    "  tick: function()",
    "end",
    "",
    "return calls") })
  local found = assert(docs.lookup(view({ db }), "cosmic.calls"))
  local lines = assert(docs.render(view({ db }), found[1]))
  local text = table.concat(lines, "\n")
  assert(text:find("\n  function calls.exists(path: string): boolean, string, integer",
    1, true), text)
  assert(text:find("\n  function calls.tick()", 1, true), text)
  local listing = text:find("  function calls.exists(", 1, true)
  local prose = text:find("Long prose after", 1, true)
  assert(listing ~= nil and prose ~= nil and listing < prose, text)
  -- A function-typed field of a nested record is that record's, not
  -- the module's call: listed under it, as a field.
  assert(not text:find("function calls.visit", 1, true), text)
  assert(text:find("\n  record calls.Stat\n    size: integer\n    visit: function", 1, true),
    text)
end

--- A function-typed field written over several lines is listed with its
--- whole signature.
local function test_a_module_listing_shows_a_multi_line_field_signature(dir: string)
  local db = built(dir, { ["cosmic/calls.tl"] = source(
    "--- A table of calls.",
    "",
    "local record calls",
    "  gen: function(input: string, env: string,",
    "                options: any): string",
    "  exists: function(path: string): boolean",
    "end",
    "",
    "return calls") })
  local found = assert(docs.lookup(view({ db }), "cosmic.calls"))
  local lines = assert(docs.render(view({ db }), found[1]))
  local text = table.concat(lines, "\n")
  assert(text:find("  function calls.exists(path: string): boolean", 1, true), text)
  assert(text:find("\n  function calls.gen(input: string, env: string, options: any): string",
    1, true), text)
  assert(not text:find("field calls.gen", 1, true), text)
end

--- A record's plain data field is not a function: only a field whose
--- type is a function is listed as one. The data fields go under their
--- record instead, one line each with its first sentence.
local function test_a_module_listing_lists_data_fields_under_their_record(dir: string)
  local db = built(dir, { ["cosmic/calls.tl"] = source(
    "--- A table of calls.",
    "",
    "local record calls",
    "  --- The most it takes. More words.",
    "  limit: integer",
    "  name: string",
    "  callbacks: {function(): boolean}",
    "  exists: function(path: string): boolean",
    "end",
    "",
    "return calls") })
  local found = assert(docs.lookup(view({ db }), "cosmic.calls"))
  local lines = assert(docs.render(view({ db }), found[1]))
  local text = table.concat(lines, "\n")
  assert(text:find("  function calls.exists(path: string): boolean", 1, true), text)
  assert(not text:find("function calls.limit", 1, true) and
      not text:find("function calls.name", 1, true), text)
  assert(text:find("\n  record calls\n    limit: integer -- The most it takes.\n" ..
      "    name: string\n    callbacks: {function(): boolean}\n", 1, true), text)
  assert(not text:find("More words", 1, true), text)
end

--- A callable module's own `metamethod` is listed with its signature,
--- and documented; a nested record's (`__close`) stays that record's.
local function test_a_module_listing_shows_its_metamethods(dir: string)
  local db = built(dir, { ["cosmic/callable.tl"] = source(
    "--- A callable module.",
    "",
    "local record callable",
    "  --- Calls the module.",
    "  metamethod __call: function(callable, string): boolean",
    "  record Handle",
    "    metamethod __close: function(Handle)",
    "  end",
    "end",
    "",
    "return callable") })
  local found = assert(docs.lookup(view({ db }), "cosmic.callable"))
  local lines = assert(docs.render(view({ db }), found[1]))
  local text = table.concat(lines, "\n")
  assert(text:find("\n  metamethod __call: function(callable, string): boolean",
    1, true), text)
  assert(not text:find("__close", 1, true), text)
  local call = assert(docs.lookup(view({ db }), "callable.__call"))
  assert(#call == 1 and call[1].kind == "metamethod", tostring(#call))
  local rendered = assert(docs.render(view({ db }), call[1]))
  assert(table.concat(rendered, "\n"):find("Calls the module.", 1, true))
end

--- A script's opening comment after its `#!` line is its module text.
local function test_a_script_after_a_shebang_lists_its_own_text(dir: string)
  local db = built(dir, { ["cosmic/script.tl"] = source(
    "#!/usr/bin/env cosmic",
    "",
    "--- Runs the thing.",
    "",
    "local function run()",
    "end",
    "",
    "return { run = run }") })
  local found = assert(docs.lookup(view({ db }), "cosmic.script"))
  assert(#found == 1 and found[1].kind == "module", tostring(#found))
  local lines = assert(docs.render(view({ db }), found[1]))
  assert(lines[2] == "  Runs the thing.", lines[2])
end

--- A bare lowercase name that ends a public module's name is that
--- module, not an internal record or symbol of the same name; a name
--- that is no module's still finds its symbols.
local function test_a_short_module_name_finds_the_public_module(dir: string)
  local db = built(dir, fs_tree({
    ["cosmic/internal/fs.d.tl"] = source(
      "local record fs",
      "end",
      "",
      "return fs"),
  }))
  local plain = assert(docs.lookup(view({ db }), "fs"))
  assert(plain.exact and #plain == 1, tostring(#plain))
  assert(plain[1].kind == "module" and plain[1].module == "cosmic.fs", plain[1].module)
  local full = assert(docs.lookup(view({ db }), "cosmic.fs"))
  assert(#full == 1 and full[1].module == "cosmic.fs", tostring(#full))
  local read = assert(docs.lookup(view({ db }), "read"))
  assert(#read == 1 and read[1].source_symbol == "Fs.read", tostring(#read))
end

--- A module's member written in full is answered exactly, a field of
--- the record its value is typed as among them, and so is a member of a
--- type an alias stands for, spelled from its module. `cosmic docs`
--- answers the member spelled from the module's last name too.
local function test_a_modules_member_in_full_is_exact(dir: string)
  local db = built(dir, {
    ["cosmic/internal/raw.tl"] = source(
      "--- Raw things.",
      "local record raw",
      "  --- One box.",
      "  record Box",
      "    --- Grows the box.",
      "    grow: function(Box, n: integer): boolean",
      "  end",
      "end",
      "",
      "return raw"),
    ["cosmic/thing.tl"] = source(
      "--- Things.",
      "local type raw = require(\"cosmic.internal.raw\")",
      "",
      "--- What a thing answers.",
      "local record Result",
      "  --- Whether it did.",
      "  ok: boolean",
      "end",
      "",
      "local record Module",
      "  --- The order.",
      "  order: {string}",
      "  --- A box.",
      "  type Box = raw.Box",
      "  --- Runs one.",
      "  run: function(): Result",
      "end",
      "",
      "local module: Module = { order = {}, run = function(): Result return { ok = true } end }",
      "",
      "return module"),
  })
  local function exact(query: string): {string}
    local out: {string} = {}
    for _, entry in ipairs((assert(docs.exact(view({ db }), query)))) do
      out[#out + 1] = entry.module .. " " .. entry.symbol
    end
    return out
  end
  local order = table.concat(exact("cosmic.thing.order"), ", ")
  assert(order == "cosmic.thing Module.order", order)
  local grow = table.concat(exact("cosmic.thing.Box.grow"), ", ")
  assert(grow == "cosmic.thing Module.Box.grow", grow)
  -- `cosmic docs` reads a module's last name as a caller's alias does.
  for _, query in ipairs({ "cosmic.thing.order", "Thing.order", "thing.order" }) do
    local found = assert(docs.lookup(view({ db }), query))
    assert(found.exact and #found == 1 and found[1].source_symbol == "Module.order",
      query .. ": " .. #found)
  end
  -- `Result` is exported, as `run` hands it out, but the value is not one.
  local ok = table.concat(exact("cosmic.thing.ok"), ", ")
  assert(ok == "", ok)
  for _, query in ipairs({ "cosmic.thing.ok", "Thing.ok" }) do
    local found = assert(docs.lookup(view({ db }), query))
    assert(not found.exact or #found == 0 or found[1].source_symbol ~= "Result.ok", query)
  end
  assert(db:close())
end

--- `cosmic uses` finds a member of the record a module's value is typed
--- as by the module's name, and lists its uses and the links to it --
--- that module's alone, not another's `Module.order` -- and the page
--- names that command.
local function test_uses_of_a_typed_values_member_are_that_modules(dir: string)
  local function verbs(name: string): string
    return source(
      "--- " .. name .. ".",
      "local record Module",
      "  --- The order.",
      "  order: {string}",
      "end",
      "",
      "local module: Module = { order = {} }",
      "",
      "return module")
  end
  local db = built(dir, {
    ["cosmic/thing.tl"] = verbs("Things"),
    ["cosmic/other.tl"] = verbs("Others"),
    ["build/boot.tl"] = source(
      "local Thing = require(\"cosmic.thing\")",
      "local Other = require(\"cosmic.other\")",
      "",
      "-- Counts [`Thing.order`] and [`Other.order`].",
      "local n = #Thing.order + #Other.order",
      "return n"),
  })
  for _, query in ipairs({ "cosmic.thing.order", "Thing.order" }) do
    local listed: {string} = {}
    for _, use in ipairs((assert(docs.uses(view({ db }), query)))) do
      listed[#listed + 1] = use.module .. " " .. use.from_file .. ":" .. use.line ..
        (use.link and " link" or "")
    end
    local got = table.concat(listed, ", ")
    assert(got == "cosmic.thing build/boot.tl:4 link, cosmic.thing build/boot.tl:5" or
        got == "cosmic.thing build/boot.tl:5, cosmic.thing build/boot.tl:4 link", query .. ": " .. got)
  end
  local page = table.concat(assert(docs.render(view({ db }),
    (assert(docs.lookup(view({ db }), "Thing.order")))[1])), "\n")
  assert(page:find("used in 1 place and linked from 1; cosmic uses cosmic.thing.order", 1, true),
    page)
  assert(db:close())
end

--- A verb the bare name names answers first, then the module: `docs
--- test` shows [`Cli.test`], then [`cosmic.test`].
local function test_a_short_module_name_keeps_its_verb(dir: string)
  local db = built(dir, {
    ["cosmic/test.tl"] = source(
      "--- Test support.",
      "",
      "local record Test",
      "end",
      "",
      "return Test"),
    ["cosmic/cli.tl"] = source(
      "--- Verbs.",
      "",
      "local record Cli",
      "  --- Runs tests.",
      "  test: string",
      "end",
      "",
      "local module: Cli = { test = \"tests\" }",
      "",
      "return module"),
  })
  local found = assert(docs.lookup(view({ db }), "test"))
  assert(found.exact and #found == 2, tostring(#found))
  assert(found[1].source_symbol == "Cli.test", found[1].source_symbol)
  assert(found[2].module == "cosmic.test" and found[2].kind == "module", found[2].module)
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
    ["lib/ontype.tl"] = source(
      "--- Said on a type. More.",
      "local type Fs = require(\"cosmic.fs\")",
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
      "lib.ontype|Said on a type.\n" ..
      "lib.sentence|Reads, e.g. a file, with `a. b` inside.\nlib.tworec|", all)
  local public = assert(docs.index((assert(docs.view({ db }, { true })))))
  assert(#public == 2 and public[1].module == "cosmic.fs" and
      public[2].module == "cosmic.hash", tostring(#public))
end

--- A module's listing leaves out the functions its returned value never
--- reaches, and the `local` types no signature of it names, but keeps the
--- types its signatures use; a private function is still found by its
--- own name.
local function test_a_module_listing_leaves_out_private_functions(dir: string)
  local db = built(dir, { ["cosmic/fs.tl"] = source(
    "--- Files and directories.",
    "",
    "local record Stat",
    "end",
    "",
    "local record Cursor",
    "end",
    "",
    "local record Fs",
    "end",
    "",
    "local function write_all(fd: integer)",
    "end",
    "",
    "function Fs.stat(path: string): Stat",
    "  return path",
    "end",
    "",
    "return Fs") })
  local found = assert(docs.lookup(view({ db }), "cosmic.fs"))
  local lines = assert(docs.render(view({ db }), found[1]))
  assert(lines[4] == "  record Stat", lines[4])
  assert(lines[5] == "  record Fs", lines[5])
  assert(lines[6] == "  function Fs.stat(path: string): Stat", lines[6])
  assert(lines[7] == "  a symbol's own page has its whole doc and its examples: cosmic docs Fs.stat",
    lines[7])
  assert(lines[8] == nil, lines[8])
  local helper = assert(docs.lookup(view({ db }), "write_all"))
  assert(#helper == 1 and helper[1].symbol == "write_all", tostring(#helper))
end

--- A module and a symbol that both answer: the module first, then the
--- symbol, and an internal record only sharing the module's name left out.
local function test_a_short_module_name_keeps_its_symbols(dir: string)
  local db = built(dir, {
    ["cosmic/string.tl"] = source(
      "--- Strings.",
      "",
      "local record String",
      "end",
      "",
      "return String"),
    ["cosmic/shape.tl"] = source(
      "--- Shapes.",
      "",
      "local record Shape",
      "  --- A string shape.",
      "  string: string",
      "end",
      "",
      "local module: Shape = { string = \"s\" }",
      "",
      "return module"),
    ["cosmic/internal/string.d.tl"] = source(
      "local record string",
      "end",
      "",
      "return string"),
  })
  local found = assert(docs.lookup(view({ db }), "string"))
  assert(found.exact and #found == 2 and found.named == 2, tostring(#found))
  assert(found[1].module == "cosmic.string" and found[1].kind == "module", found[1].module)
  assert(found[2].source_symbol == "Shape.string", found[2].source_symbol)
end

--- Test, example and internal modules are no short name's module.
local function test_a_short_module_name_skips_test_example_and_internal(dir: string)
  local db = built(dir, {
    ["cosmic/fs.tl"] = source("--- Files.", "", "local record Fs", "end", "", "return Fs"),
    ["cosmic/internal/only.tl"] = source("--- Inside.", "", "local record Only", "end",
      "", "return Only"),
    ["cosmic/fs_test.tl"] = source("--- Tests.", "", "local record T", "end", "", "return T"),
    ["cosmic/thing_example.tl"] = source("--- Shows.", "", "local record E", "end", "",
      "return E"),
  })
  for _, name in ipairs({ "only", "fs_test", "thing_example", "example", "test" }) do
    local found = assert(docs.lookup(view({ db }), name))
    for _, entry in ipairs(found) do
      assert(entry.kind ~= "module" or found.exact == false,
        name .. " answered module " .. entry.module)
    end
  end
  local fs = assert(docs.lookup(view({ db }), "fs"))
  assert(#fs >= 1 and fs[1].module == "cosmic.fs", fs[1].module)
end

--- A project's own module answers a short name too, ahead of the
--- standard library's, and its own symbols follow.
local function test_a_short_module_name_finds_a_projects_module(dir: string)
  local db = built(dir, {
    ["myproj/util.tl"] = source("--- Helpers.", "", "local record Util", "end", "",
      "return Util"),
    ["cosmic/util.tl"] = source("--- Library helpers.", "", "local record Lib", "end",
      "", "return Lib"),
  })
  local found = assert(docs.lookup(view({ db }), "util"))
  assert(#found == 2 and found[1].module == "myproj.util" and
      found[2].module == "cosmic.util", tostring(#found))
end

--- A query that is not lowercase-and-bare takes the symbol route: exact
--- symbols only, and a qualified name answers by its symbol.
local function test_a_capitalized_name_takes_the_symbol_route(dir: string)
  local db = built(dir, fs_tree())
  local found = assert(docs.lookup(view({ db }), "Fs"))
  assert(#found == 1 and found[1].kind == "record", tostring(#found))
  local qualified = assert(docs.lookup(view({ db }), "Fs.read"))
  assert(#qualified == 1 and qualified[1].source_symbol == "Fs.read")
end

--- The listing is placed after the first paragraph, and after the block
--- a colon-ended paragraph introduces; a text with no blank line gets it last.
local function test_the_listing_keeps_a_colon_and_its_example_together(dir: string)
  local function listing_at(text: {string}): {string}
    local sub = dir .. "/" .. #text
    assert(Fs.mkdirs(sub))
    local db = built(sub, { ["cosmic/fs.tl"] = table.concat(text, "\n") .. "\n" .. source(
      "",
      "local record Fs",
      "end",
      "",
      "function Fs.read(path: string): string",
      "  return path",
      "end",
      "",
      "return Fs") })
    local found = assert(docs.lookup(view({ db }), "cosmic.fs"))
    return (assert(docs.render(view({ db }), found[1])))
  end
  local function at(lines: {string}, needle: string): integer
    for i, line in ipairs(lines) do
      if line:find(needle, 1, true) then return i end
    end
    return 0
  end
  local colon = listing_at({ "--- Files, for example:", "---", "--- `Fs.read(p)`", "---",
    "--- More prose." })
  assert(at(colon, "Fs.read(p)") < at(colon, "function Fs.read("), table.concat(colon, "\n"))
  assert(at(colon, "function Fs.read(") < at(colon, "More prose"), table.concat(colon, "\n"))
  local plain = listing_at({ "--- Files.", "---", "--- More prose." })
  assert(at(plain, "Files.") < at(plain, "function Fs.read(") and
      at(plain, "function Fs.read(") < at(plain, "More prose"), table.concat(plain, "\n"))
  local one = listing_at({ "--- Just one paragraph." })
  assert(at(one, "Just one") < at(one, "function Fs.read("), table.concat(one, "\n"))
end

--- A colon-ended paragraph keeps a multi-block example together: the
--- listing follows the whole run of indented blocks, not the first.
local function test_the_listing_follows_a_multi_block_example(dir: string)
  local db = built(dir, { ["cosmic/fs.tl"] = source(
    "--- Files, for example:",
    "---",
    "---     l1",
    "---",
    "---     l2",
    "---",
    "--- More prose.",
    "",
    "local record Fs",
    "end",
    "",
    "function Fs.read(path: string): string",
    "  return path",
    "end",
    "",
    "return Fs") })
  local found = assert(docs.lookup(view({ db }), "cosmic.fs"))
  local lines = assert(docs.render(view({ db }), found[1]))
  local text = table.concat(lines, "\n")
  local l2 = text:find("l2", 1, true)
  local listing = text:find("function Fs.read(", 1, true)
  local prose = text:find("More prose", 1, true)
  assert(l2 ~= nil and listing ~= nil and prose ~= nil and l2 < listing and
      listing < prose, text)
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

--- A search stems its words, so "writing" finds a comment that says
--- "Writes". When no member carries every word, the closest ones follow:
--- those with at least half of them, and never on one word alone.
local function test_a_search_stems_and_offers_the_closest_when_none_has_every_word(dir: string)
  local db = built(dir, fs_tree())
  local stemmed = assert(docs.lookup(view({ db }), "writing"))
  assert(stemmed[1].source_symbol == "Fs.write", tostring(stemmed[1].source_symbol))
  local some = assert(docs.lookup(view({ db }), "create parent unheard whole"))
  assert(some.closest and not some.exact)
  assert(some[1].source_symbol == "Fs.write", some[1].source_symbol)
  local seen: {string:boolean} = {}
  for _, entry in ipairs(some) do
    assert(not seen[entry.source_symbol], "repeated " .. entry.source_symbol)
    seen[entry.source_symbol] = true
  end
  assert(seen["Fs.read"] == nil, "one word of four is not enough")
  local junk = assert(docs.lookup(view({ db }), "unheard whole"))
  assert(#junk == 0, "one of two words is not enough")
  local whole = assert(docs.lookup(view({ db }), "whole file"))
  assert(whole[1].symbol == "read", "a member comes before its module: " .. whole[1].symbol)
end

--- The lines of `answer` as one text, for a search of it.
local function answered(answer: docs.Answer): string
  return table.concat(answer.lines, "\n")
end

--- Several qualified names are each looked up as they would be alone,
--- in the order given, where bare words -- which often each name
--- something too ("read", "write") -- are still searched for together.
local function test_several_qualified_names_are_each_looked_up(dir: string)
  local db = built(dir, fs_tree())
  local both = assert(docs.answer(view({ db }), { "Fs.write", "Fs.read" }))
  local text = answered(both)
  assert(both.found and both.said == "2 named", both.said)
  assert(not text:find("No exact symbol match", 1, true), text)
  local write = text:find("cosmic.fs Fs.write (", 1, true)
  local read = text:find("cosmic.fs Fs.read (", 1, true)
  assert(write ~= nil and read ~= nil and write < read, text)
  local bare = assert(docs.answer(view({ db }), { "read", "write" }))
  assert(bare.said == "nothing named or documented as 'read write'", bare.said)
  local missing = assert(docs.answer(view({ db }), { "Fs.read", "Nope.unheard" }))
  assert(not missing.found, missing.said)
  assert(missing.said == "nothing named or documented as 'Nope.unheard', 1 named", missing.said)
  assert(answered(missing):find("cosmic.fs Fs.read (", 1, true), answered(missing))
  assert(answered(missing):find("\nNothing named or documented as 'Nope.unheard'.", 1, true),
    answered(missing))
end

--- `cosmic` alone, which a search finds in nearly every comment, lists
--- the standard library's modules instead, a line each, ahead of a name
--- a tree's own module gives a symbol; no words list every module.
local function test_cosmic_alone_lists_the_standard_library(dir: string)
  local db = built(dir, fs_tree({
    ["build/tool.tl"] = source(
      "--- A tool of the tree's own.",
      "local record Tool",
      "end",
      "",
      "--- Starts cosmic.",
      "function Tool.cosmic()",
      "end",
      "",
      "return Tool"),
  }))
  local all = assert(docs.answer(view({ db }), {}))
  assert(all.found and all.said == "4 modules", all.said)
  assert(answered(all):find("build.tool  A tool of the tree's own.", 1, true), answered(all))
  for _, word in ipairs({ "cosmic", "cosmic." }) do
    local answer = assert(docs.answer(view({ db }), { word }))
    local text = answered(answer)
    assert(answer.found and answer.said == "1 module", answer.said)
    assert(text:find("cosmic.fs  Files and directories.", 1, true), text)
    assert(not text:find("build.", 1, true), text)
    assert(not text:find("Tool.cosmic", 1, true), text)
  end
end

--- A search with no exact match shows its first five entries whole and
--- names the rest a line each, so a broad word answers in a page.
local function test_a_search_shows_five_whole_and_lists_the_rest(dir: string)
  local lines: {string} = { "--- Many things.", "local record Many", "end", "" }
  for at = 1, 8 do
    lines[#lines + 1] = "--- Sentinel number " .. at .. ". Then more words."
    lines[#lines + 1] = "function Many.f" .. at .. "(): integer"
    lines[#lines + 1] = "  return " .. at
    lines[#lines + 1] = "end"
    lines[#lines + 1] = ""
  end
  lines[#lines + 1] = "return Many"
  local db = built(dir, { ["cosmic/many.tl"] = source(table.unpack(lines)) })
  local answer = assert(docs.answer(view({ db }), { "sentinel" }))
  local text = answered(answer)
  assert(answer.found and answer.said == "8 found", answer.said)
  assert(text:find("No exact symbol match for 'sentinel'", 1, true), text)
  local whole, listed = 0, 0
  for _, line in ipairs(answer.lines) do
    if line:match("^cosmic%.many Many%.f%d %(") then whole = whole + 1 end
    if line:match("^  cosmic%.many Many%.f%d %(cosmic/many%.tl:%d+%) %-%- Sentinel number %d%.$") then
      listed = listed + 1
    end
  end
  assert(whole == 5 and listed == 3, whole .. " whole, " .. listed .. " listed:\n" .. text)
  assert(text:find("3 more; narrow the search", 1, true), text)
  local near = assert(docs.answer(view({ db }), { "sentinel", "number", "unheard" }))
  assert(answered(near):find("No entry has every word of 'sentinel number unheard'; closest matches:",
    1, true), answered(near))
end

--- A name counts as documented by an example only when the example
--- spells it whole: the index stems words, so `Fs.reads` reaches an
--- example of [`Fs.read`], which the compiler's hint must not follow.
local function test_a_misspelt_name_is_not_a_known_example(dir: string)
  local db = built(dir, fs_tree({
    ["cosmic/fs_example.tl"] = fs_example("load", "Loads a file.", "  local _ = Fs.read(\"x\")"),
  }))
  assert(symbols.has_example_query({ db }, { false }, "Fs.read"))
  assert(not symbols.has_example_query({ db }, { false }, "Fs.reads"))
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

--- A shortcut link shows as its code span alone, a module's first
--- sentence included, and a definition's line not at all.
local function test_a_link_renders_as_its_code_span(dir: string)
  local db = built(dir, {
    ["cosmic/box.tl"] = source(
      "--- Boxes, which [`Box.grow`] grows.",
      "local record Box",
      "end",
      "",
      "--- Grows a box as [`Box.shrink`] shrinks one; see [the guide][g], and",
      "--- `` [`x`] `` as written.",
      "---",
      "--- [g]: doc/guide.md",
      "--- [`Box.shrink`]: cosmic/box.tl",
      "function Box.grow(): boolean",
      "  return true",
      "end",
      "",
      "--- Shrinks.",
      "function Box.shrink(): boolean",
      "  return true",
      "end",
      "",
      "return Box"),
  })
  local found = assert(docs.lookup(view({ db }), "Box.grow"))
  local lines = assert(docs.render(view({ db }), found[1]))
  local shown = table.concat(lines, "\n", 3, 6)
  local want = "  Grows a box as `Box.shrink` shrinks one; see [the guide][g], and\n" ..
    "  `` [`x`] `` as written.\n\n  [g]: doc/guide.md"
  assert(shown == want, shown)
  local index = assert(docs.index(view({ db })))
  assert(index[1].text == "Boxes, which `Box.grow` grows.", index[1].text)
end

--- A symbol with a worked example renders its own doc comment and its
--- source, in that order, under [`Fs.read`]'s own doc comment; a
--- module's own listing marks which of its symbols have one. The
--- example is matched to [`Fs.read`] by its own code calling it, not by
--- its function name (`read`, here, could have been anything). An
--- example's own call is a use, as any module's is.
local function test_renders_a_symbols_example(dir: string)
  local db = built(dir, fs_tree({
    ["cosmic/fs_example.tl"] = fs_example("read", "Reads a file back.",
      "  print(Fs.read(\"x\"))"),
  }))
  local read = assert(docs.lookup(view({ db }), "Fs.read"))
  local lines = assert(docs.render(view({ db }), read[1]))
  assert(lines[#lines - 6] == "  example read (cosmic/fs_example.tl:8):",
    lines[#lines - 6])
  assert(lines[#lines - 5] == "  Reads a file back.", lines[#lines - 5])
  assert(lines[#lines - 4] == "    local Fs = require(\"cosmic.fs\")", lines[#lines - 4])
  assert(lines[#lines - 3] == "", lines[#lines - 3])
  assert(lines[#lines - 2] == "    function Example.read()", lines[#lines - 2])
  assert(lines[#lines - 1] == "      print(Fs.read(\"x\"))", lines[#lines - 1])
  assert(lines[#lines] == "    end", lines[#lines])

  local module = assert(docs.lookup(view({ db }), "cosmic.fs"))
  local module_lines = assert(docs.render(view({ db }), module[1]))
  assert(module_lines[5] == "  function Fs.read(path: string): string | nil, string -- The whole of a file.  " ..
      "(3 uses, 1 example)",
    module_lines[5])
  assert(module_lines[6] == "  function Fs.write(path: string, data: string): boolean, string -- " ..
      "Writes the whole of a file.",
    module_lines[6])
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
  assert(module_lines[5] == "  function Fs.read(path: string): string | nil, string -- The whole of a file.  " ..
      "(4 uses, 2 examples)",
    module_lines[5])
end

--- A module's examples can be split by topic: `cosmic/fs_config_example.tl`
--- pairs with [`cosmic.fs`] as [`cosmic/fs_example.tl`] does, and each file's
--- `Example.read` is kept, the name being free in each.
local function test_a_topic_example_pairs_with_its_module(dir: string)
  local db = built(dir, fs_tree({
    ["cosmic/fs_example.tl"] = fs_example("read", "Reads a file back.",
      "  print(Fs.read(\"aa\"))"),
    ["cosmic/fs_config_example.tl"] = fs_example("read", "Reads a config file.",
      "  print(Fs.read(\"bb\"))"),
  }))
  local read = assert(docs.lookup(view({ db }), "Fs.read"))
  local headers: {string} = {}
  for _, line in ipairs((assert(docs.render(view({ db }), read[1])))) do
    if line:match("^  example ") then headers[#headers + 1] = line end
  end
  assert(#headers == 2, table.concat(headers, " | "))
  assert(headers[1] == "  example read (cosmic/fs_config_example.tl:8):", headers[1])
  assert(headers[2] == "  example read (cosmic/fs_example.tl:8):", headers[2])
end

--- The module an example pairs with, by its file, from the examples
--- the tree `files` ships.
local function paired(dir: string, files: {string: string}): {string: string}
  local db = built(dir, files)
  local out: {string: string} = {}
  for _, row in ipairs((assert(Sqlite.text_rows(db, "SELECT file, module FROM examples")))) do
    out[row[1]] = row[2]
  end
  return out
end

--- A worked example `Example.<name>` that calls nothing: each file's
--- own name, as the fixture keys a compile by its source.
local function bare_example(name: string): string
  return source("local record Example", "end", "", "function Example." .. name .. "()", "end",
    "", "return Example")
end

--- A topic example pairs with the longest module or declaration its
--- name starts with, on a `_` boundary: `cosmic.json_yaml` over
--- `cosmic.json`, a test ([`cosmic.json_test`]) never, and
--- `cosmic/jsonx_example.tl` and `cosmic/js_example.tl` with neither.
local function test_a_topic_example_pairs_with_the_longest_module(dir: string)
  local found = paired(dir, {
    ["cosmic/json.tl"] = source("return { json = true }"),
    ["cosmic/json_yaml.tl"] = source("return { yaml = true }"),
    ["cosmic/json_test.tl"] = source("local function test_it() end"),
    ["cosmic/json_test_helpers_example.tl"] = bare_example("helpers"),
    ["cosmic/sys.d.tl"] = source("local record sys", "end", "return sys"),
    ["cosmic/sys_socket_example.tl"] = bare_example("socket"),
    ["cosmic/json_example.tl"] = bare_example("plain"),
    ["cosmic/json_flow_example.tl"] = bare_example("flow"),
    ["cosmic/json_yaml_example.tl"] = bare_example("yaml"),
    ["cosmic/json_yaml_flow_example.tl"] = bare_example("yaml_flow"),
    ["cosmic/jsonx_example.tl"] = bare_example("jsonx"),
    ["cosmic/js_example.tl"] = bare_example("js"),
  })
  assert(found["cosmic/json_example.tl"] == "cosmic.json", found["cosmic/json_example.tl"])
  assert(found["cosmic/json_flow_example.tl"] == "cosmic.json",
    found["cosmic/json_flow_example.tl"])
  assert(found["cosmic/json_yaml_example.tl"] == "cosmic.json_yaml",
    found["cosmic/json_yaml_example.tl"])
  assert(found["cosmic/json_yaml_flow_example.tl"] == "cosmic.json_yaml",
    found["cosmic/json_yaml_flow_example.tl"])
  assert(found["cosmic/jsonx_example.tl"] == nil, found["cosmic/jsonx_example.tl"])
  assert(found["cosmic/js_example.tl"] == nil, found["cosmic/js_example.tl"])
  assert(found["cosmic/json_test_helpers_example.tl"] == "cosmic.json",
    found["cosmic/json_test_helpers_example.tl"])
  assert(found["cosmic/sys_socket_example.tl"] == "cosmic.sys",
    found["cosmic/sys_socket_example.tl"])
end

--- Examples from several files of one module list by file, then line,
--- whatever order their rows were written in: written by hand, since
--- the build writes them in that order already.
local function test_examples_list_by_file_then_line()
  local db = database({
    { "cosmic.fs", "read", "function", "function Fs.read()", "Reads.", "cosmic/fs.tl", "3",
      nil, "Fs.read" },
  }, {})
  for _, row in ipairs({ { "cosmic/fs_tls_example.tl", "1" }, { "cosmic/fs_example.tl", "5" } }) do
    assert(Sqlite.run(db,
      "INSERT INTO examples (module, name, text, file, line, source) " ..
        "VALUES ('cosmic.fs', 'read', 'A sentinel read.', ?1, ?2, " ..
        "'function Example.read() Fs.read(\"x\") end')",
      { { text = row[1] }, { integer = math.tointeger(tonumber(row[2])) } }))
  end
  assert(db:exec("INSERT INTO examples_fts(examples_fts) VALUES ('rebuild')"))
  local read = assert(docs.lookup(view({ db }), "Fs.read"))
  local headers: {string} = {}
  for _, line in ipairs((assert(docs.render(view({ db }), read[1])))) do
    if line:match("^  example ") then headers[#headers + 1] = line end
  end
  assert(#headers == 2, table.concat(headers, " | "))
  assert(headers[1] == "  example read (cosmic/fs_example.tl:5):", headers[1])
  assert(headers[2] == "  example read (cosmic/fs_tls_example.tl:1):", headers[2])
  local searched = assert(docs.lookup(view({ db }), "sentinel"))
  assert(#searched == 2, tostring(#searched))
  assert(searched[1].file == "cosmic/fs_example.tl", searched[1].file)
  assert(searched[2].file == "cosmic/fs_tls_example.tl", searched[2].file)
end

--- FTS5 tokenizes on `_`, so `Hash.hex` and [`Hash.hex_sha256`] share
--- their first two tokens; an example that only ever calls
--- [`Hash.hex_sha256`] must not also match `Hash.hex`.
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
--- mentions -- never in [`Fs.read`]'s own doc comment -- still finds
--- [`cosmic.fs`], and renders the matching comment and checked source.
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
--- recorded without the module's own record (`write`, [`Writer.write`]).
--- Written by hand: `Writer.add_file` is a use through a typed
--- value, which only a compile finds (see [`build.docs_fixture`]).
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
  -- `Writer` is no module's own record here, so it is a use of the
  -- [`Writer.write`] recorded as such and of no bare `write`.
  assert(#assert(docs.uses(view({ db }), "Writer.write")) == 1)
  assert(#assert(docs.uses(view({ db }), "Zip.Writer.add_file")) == 1)
  assert(#assert(docs.uses(view({ db }), "cosmic.Zip.Writer.add_file")) == 0,
    "one name past the record, and no more")
end

--- A qualifier is the record of the module the use is of: [`Fs.read`] is
--- not a use of another module's `read`, though both are recorded as
--- `read`; the module's last name answers too, in either case, and a
--- bare `read` still finds every one.
local function test_a_qualifier_names_the_module_it_is_a_use_of(dir: string)
  local db = built(dir, {
    ["cosmic/fs.tl"] = source(
      "local record Fs",
      "end",
      "--- Reads.",
      "function Fs.read(): string return '' end",
      "return Fs"),
    ["cosmic/csv.tl"] = source(
      "local record Csv",
      "end",
      "--- Reads rows.",
      "function Csv.read(): string return '' end",
      "return Csv"),
    ["app/main.tl"] = source(
      "local Fs = require('cosmic.fs')",
      "local Csv = require('cosmic.csv')",
      "local _ = Fs.read()",
      "local _ = Csv.read()",
      "local _ = Csv.read()"),
  })
  local function modules(query: string): string
    local out: {string} = {}
    for _, use in ipairs((assert(docs.uses(view({ db }), query)))) do
      out[#out + 1] = use.module
    end
    return table.concat(out, ",")
  end
  assert(modules("Fs.read") == "cosmic.fs", modules("Fs.read"))
  assert(modules("fs.read") == "cosmic.fs", modules("fs.read"))
  assert(modules("Csv.read") == "cosmic.csv,cosmic.csv", modules("Csv.read"))
  -- In file and line order, whatever each is a use of.
  assert(modules("read") == "cosmic.fs,cosmic.csv,cosmic.csv", modules("read"))
  assert(modules("Sys.read") == "", modules("Sys.read"))
  -- What `docs` counts is what `uses` lists.
  local found = assert(docs.lookup(view({ db }), "Csv.read"))
  assert(found[1].uses == 2, tostring(found[1].uses))
end

--- A method on a nested record is found by the name its uses are
--- recorded under (`Box.grow`), and counts them. The use is written by
--- hand: it is through a typed value, which only a compile finds.
local function test_a_nested_record_method_meets_its_uses(dir: string)
  local thing = built(dir, { ["app/thing.tl"] = source(
    "local record Thing",
    "  record Box",
    "  end",
    "end",
    "",
    "--- Grows the box.",
    "function Thing.Box:grow()",
    "end",
    "",
    "--- Opens the lid.",
    "function Thing.Box.Lid:open()",
    "end",
    "",
    "return Thing") })
  local caller = database({}, {
    { "app.thing", "Box.grow", "app.main", "app/main.tl", "3" },
  }, { "app.main" })
  local found = assert(docs.lookup(view({ thing, caller }), "Box.grow"))
  assert(found.exact and #found == 1, tostring(#found))
  assert(found[1].source_symbol == "Thing.Box:grow", found[1].source_symbol)
  assert(found[1].uses == 1, tostring(found[1].uses))
  -- A method is called with `:`, and found spelled so too.
  for _, query in ipairs({ "Thing.Box:grow", "Box:grow" }) do
    local called = assert(docs.lookup(view({ thing }), query))
    assert(called.exact and #called == 1, query)
  end
  local lid = assert(docs.lookup(view({ thing }), "Lid:open"))
  assert(lid.exact and #lid == 1 and lid[1].symbol == "Box.Lid.open", "Lid:open")
  -- `cosmic docs` points at `cosmic uses <source_symbol>`, which must answer.
  for _, query in ipairs({ "Thing.Box.grow", "Thing.Box:grow", "Box:grow", "grow" }) do
    assert(#assert(docs.uses(view({ thing, caller }), query)) == 1, query)
  end
  assert(#assert(docs.uses(view({ thing, caller }), "Lid:grow")) == 0)
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

--- An earlier database owns a module it holds even when the module
--- documents nothing: a later database's symbols and examples of it stay
--- hidden.
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

  -- A module's own row, whose source spelling is empty, is among what
  -- its name matches.
  local own = assert(Sqlite.text_rows(db, "SELECT d.kind FROM docs d WHERE " ..
      symbols.named_where("d"), { { text = "cosmic.fs" } }))
  assert(#own == 1 and own[1][1] == "module", tostring(#own))
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

--- A module that is only a declaration -- [`cosmic.sys`], generated from
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
--- hand: that copy is [`build.embed`]'s shape, not the build's.
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
--- the store's databases, here one of the test's own.
local function test_an_unreadable_own_database_is_left_out(dir: string)
  local store = built(dir, fs_tree())
  assert(Fs.mkdirs(dir .. "/o"))
  assert(Fs.write(dir .. "/o/cosmic.db", "not a database"))
  local before = assert(sys.getcwd())
  assert(sys.chdir(dir))
  local sources = docs.databases({ store })
  assert(sys.chdir(before))
  assert(#sources.handles == 1 and sources.handles[1] == store, tostring(#sources.handles))
  local looked = assert(docs.view(sources.handles, sources.public))
  local found = assert(docs.lookup(looked, "Fs.read"))
  assert(#found > 0 and found.exact)
end

--- A record's page lists each field with its type and the first
--- sentence of what it says, and an enum's page its values.
local function test_a_record_page_lists_its_fields_and_an_enum_its_values(dir: string)
  local db = built(dir, { ["cosmic/thing.tl"] = source(
    "--- Things.",
    "",
    "local record Thing",
    "  --- What `make` may be told. Every field is optional.",
    "  record Options",
    "    --- How many to make. It defaults to one.",
    "    count: integer",
    "    label: string",
    "  end",
    "  --- The shapes there are.",
    "  enum Shape",
    "    \"round\"",
    "    \"flat\"",
    "  end",
    "end",
    "",
    "function Thing.make(opts?: Thing.Options): Thing.Shape",
    "  return \"round\"",
    "end",
    "",
    "return Thing") })
  local looked = view({ db })
  local options = assert(docs.lookup(looked, "Thing.Options"))
  local shown = table.concat(assert(docs.render(looked, options[1])), "\n")
  assert(shown:find("  fields:\n    count: integer -- How many to make.\n    label: string",
    1, true), shown)
  local shape = assert(docs.lookup(looked, "Thing.Shape"))
  shown = table.concat(assert(docs.render(looked, shape[1])), "\n")
  assert(shown:find("  values:\n    \"flat\"\n    \"round\"", 1, true), shown)
  local page = assert(docs.lookup(looked, "cosmic.thing"))
  shown = table.concat(assert(docs.render(looked, page[1])), "\n")
  assert(shown:find("\n  record Thing.Options\n    count: integer -- How many to make.\n" ..
      "    label: string", 1, true), shown)
end

--- A public source shows none of a module's own: a `local` record and
--- its fields, a `local` function, a `_` field. Another source shows them
--- by name, but a module's listing never does.
local function test_a_public_source_hides_a_modules_own_symbols(dir: string)
  local db = built(dir, { ["cosmic/thing.tl"] = source(
    "--- Things.",
    "",
    "local record Cursor",
    "  at: integer",
    "end",
    "",
    "local record Thing",
    "  record Options",
    "    count: integer",
    "    _cache: string",
    "  end",
    "end",
    "",
    "local function step(cursor: Cursor)",
    "end",
    "",
    "local function walk()",
    "end",
    "",
    "function Thing.walk(): string",
    "  walk()",
    "  return \"\"",
    "end",
    "",
    "function Thing.make(opts?: Thing.Options): string",
    "  step({ at = 1 })",
    "  return \"\"",
    "end",
    "",
    "return Thing") })
  local public = assert(docs.view({ db }, { true }))
  for _, name in ipairs({ "Cursor", "Cursor.at", "step", "Options._cache" }) do
    local found = assert(docs.lookup(public, name))
    assert(#found == 0 or found[1].source_symbol ~= name, name)
  end
  local options = assert(docs.lookup(public, "Thing.Options"))
  local shown = table.concat(assert(docs.render(public, options[1])), "\n")
  assert(shown:find("    count: integer", 1, true) and not shown:find("_cache", 1, true), shown)
  local page = assert(docs.lookup(public, "cosmic.thing"))
  shown = table.concat(assert(docs.render(public, page[1])), "\n")
  assert(not shown:find("Cursor", 1, true) and not shown:find("_cache", 1, true), shown)
  -- A public function is not hidden by a private one of the same name.
  assert(shown:find("function Thing.walk(): string", 1, true), shown)
  local walked = assert(docs.lookup(public, "walk"))
  assert(#walked == 1 and walked[1].source_symbol == "Thing.walk", tostring(#walked))

  local own = view({ db })
  assert(#assert(docs.lookup(own, "Cursor")) == 1)
  assert(#assert(docs.lookup(own, "step")) == 1)
  page = assert(docs.lookup(own, "cosmic.thing"))
  shown = table.concat(assert(docs.render(own, page[1])), "\n")
  assert(not shown:find("Cursor", 1, true), shown)
end

--- A count of one is written in the singular, in a listing and on a
--- symbol's page.
local function test_a_count_of_one_is_singular(dir: string)
  local db = built(dir, {
    ["cosmic/fs.tl"] = source(
      "--- Files.",
      "",
      "local record Fs",
      "end",
      "",
      "--- The whole of a file.",
      "function Fs.read(path: string): string",
      "  return path",
      "end",
      "",
      "return Fs"),
    ["build/boot.tl"] = source(
      "local Fs = require(\"cosmic.fs\")",
      "",
      "local text = Fs.read(\"boot\")",
      "return text"),
  })
  local looked = view({ db })
  local page = assert(docs.lookup(looked, "cosmic.fs"))
  local text = table.concat(assert(docs.render(looked, page[1])), "\n")
  assert(text:find("(1 use)", 1, true) and not text:find("1 uses", 1, true), text)
  local read = assert(docs.lookup(looked, "Fs.read"))
  text = table.concat(assert(docs.render(looked, read[1])), "\n")
  assert(text:find("used in 1 place;", 1, true), text)
end

--- A module page cuts a field's note at a word near 100 characters; the
--- record's own page keeps the sentence.
local function test_a_module_page_truncates_a_long_field_note(dir: string)
  local words = string.rep("word ", 30)
  local db = built(dir, { ["cosmic/thing.tl"] = source(
    "--- Things.",
    "",
    "local record Thing",
    "  record Options",
    "    --- " .. words .. "end.",
    "    count: integer",
    "  end",
    "end",
    "",
    "function Thing.make(opts?: Thing.Options): string",
    "  return \"\"",
    "end",
    "",
    "return Thing") })
  local looked = view({ db })
  local page = assert(docs.lookup(looked, "cosmic.thing"))
  local shown = table.concat(assert(docs.render(looked, page[1])), "\n")
  local line = assert(shown:match("\n    (count: integer[^\n]*)"))
  assert(#line < 130 and line:sub(-3) == "…", line)
  assert(not line:find("end.", 1, true), line)
  local options = assert(docs.lookup(looked, "Thing.Options"))
  shown = table.concat(assert(docs.render(looked, options[1])), "\n")
  assert(shown:find("word end.", 1, true), shown)
end

--- A worked example is copied out of its file, so its page shows the
--- file's `require` lines the body uses, above the function: `Fs` here,
--- but not `Hash`, which the body never names.
local function test_an_example_shows_the_requires_it_uses(dir: string)
  local db = built(dir, fs_tree({
    ["cosmic/fs_example.tl"] = fs_example("read", "Reads a file back.",
      "  print(Fs.read(\"x\"))"),
  }))
  local looked = view({ db })
  local page = table.concat(assert(docs.render(looked,
    assert(docs.lookup(looked, "Fs.read"))[1])), "\n")
  local at = assert(page:find("    local Fs = require(\"cosmic.fs\")\n", 1, true), page)
  local body = assert(page:find("    function Example.read()", 1, true), page)
  assert(at < body, page)
  assert(not page:find("cosmic.hash", 1, true), page)
end

--- An example is attached to every symbol it calls, so [`Fs.read`] is
--- called by a `truncate` example too: the one named `read` comes first
--- however the file orders them, and a page shows two, naming the rest.
local function test_examples_rank_by_name_and_are_capped(dir: string)
  local function example(name: string, body: string): string
    return source("--- About " .. name .. ".", "function Example." .. name .. "()",
      body, "end", "")
  end
  local db = built(dir, fs_tree({
    ["cosmic/fs_example.tl"] = source(
      "local Fs = require(\"cosmic.fs\")",
      "",
      "local record Example",
      "end",
      "") ..
      example("truncate", "  Fs.write(\"a\", \"b\")\n  print(Fs.read(\"a\"))\n  print(Fs.read(\"a\"))") ..
      example("copy_tree", "  print(Fs.read(\"a\"))") ..
      example("write", "  print(Fs.read(\"a\"))\n  print(Fs.read(\"a\"))\n  print(Fs.read(\"a\"))") ..
      example("read", "  print(Fs.read(\"a\"))") ..
      "\nreturn Example\n",
  }))
  local looked = view({ db })
  local shown = assert(docs.render(looked, assert(docs.lookup(looked, "Fs.read"))[1]))
  local headers: {string} = {}
  local more = ""
  for _, line in ipairs(shown) do
    if line:match("^  example ") then headers[#headers + 1] = line end
    if line:match("^  %d+ more example") then more = line end
  end
  assert(#headers == 2, table.concat(headers, " | "))
  assert(headers[1]:match("^  example read "), headers[1])
  assert(headers[2]:match("^  example write "), headers[2])
  assert(more:match("^  2 more examples: "), more)
  assert(more:find("truncate", 1, true) and more:find("copy_tree", 1, true), more)
end

--- A top-level call in an example file, as cosmic/test_example.tl's
--- [`Test.needs`] is, sits outside every example, so the file's first
--- example carries it: the function called has an example, and it
--- shows the call.
local function test_a_top_level_call_is_carried_by_the_first_example(dir: string)
  local db = built(dir, {
    ["cosmic/thing.tl"] = source(
      "--- Things.",
      "",
      "local record Thing",
      "end",
      "",
      "--- Declares something.",
      "function Thing.declare(value: string)",
      "end",
      "",
      "--- Does another thing.",
      "function Thing.other()",
      "end",
      "",
      "return Thing"),
    ["cosmic/thing_example.tl"] = source(
      "local Thing = require(\"cosmic.thing\")",
      "local Fs = require(\"cosmic.fs\")",
      "",
      "Thing.declare{ value = \"x\" }",
      "",
      "local record Example",
      "end",
      "",
      "--- The call at the top.",
      "function Example.first()",
      "  print(Fs)",
      "  Thing.other()",
      "end",
      "",
      "function Example.second()",
      "  print(1)",
      "end",
      "",
      "return Example"),
  })
  local looked = view({ db })
  local page = table.concat(assert(docs.render(looked,
    assert(docs.lookup(looked, "Thing.declare"))[1])), "\n")
  assert(page:find("example first", 1, true), page)
  assert(page:find("    Thing.declare{ value = \"x\" }\n", 1, true), page)
  assert(page:find("    local Thing = require(\"cosmic.thing\")\n", 1, true), page)
  assert(page:find("    local Fs = require", 1, true), page)
  assert(not page:find("example second", 1, true), page)
  -- Another symbol the same first example shows is not one the call is about.
  local other = table.concat(assert(docs.render(looked,
    assert(docs.lookup(looked, "Thing.other"))[1])), "\n")
  assert(other:find("example first", 1, true) and not other:find("Thing.declare", 1, true), other)
  assert(other:find("local Thing = require", 1, true) and other:find("local Fs = require", 1, true), other)
end

--- A name that only ends in the symbol's is no call of it, and a method
--- is a call through any value: `MyFs.read` does not lead [`Fs.read`]'s
--- page, and `db:exec` counts for [`Handle.exec`].
local function test_example_ranking_reads_whole_names_and_method_calls(dir: string)
  local db = built(dir, fs_tree({
    ["cosmic/fs_example.tl"] = source(
      "local Fs = require(\"cosmic.fs\")",
      "",
      "local record Example",
      "end",
      "",
      "function Example.alpha()",
      "  print(MyFs.read(1))",
      "  print(MyFs.read(2))",
      "end",
      "",
      "function Example.beta()",
      "  print(Fs.read(3))",
      "end",
      "",
      "return Example"),
  }))
  local looked = view({ db })
  local shown = assert(docs.render(looked, assert(docs.lookup(looked, "Fs.read"))[1]))
  local headers: {string} = {}
  for _, line in ipairs(shown) do
    if line:match("^  example ") then headers[#headers + 1] = line end
  end
  assert(headers[1] and headers[1]:match("^  example beta "), table.concat(headers, " | "))
end

--- Methods and fields a public type takes from an internal record, by
--- alias (`type Box = raw.Box`) or by extending it, are listed on the
--- public type's page with their notes, and each answers to its own
--- dotted name. A same-module alias (`type Config = Config`) lists the
--- record's fields.
local function test_a_public_type_lists_what_it_takes_from_another(dir: string)
  local db = built(dir, {
    ["cosmic/internal/raw.tl"] = source(
      "--- Raw things.",
      "",
      "local record raw",
      "  --- One box.",
      "  record Box",
      "    --- Grows the box by `n`.",
      "    grow: function(Box, n: integer): boolean",
      "    --- How many things it holds.",
      "    size: integer",
      "    _hidden: integer",
      "  end",
      "  interface Base",
      "    --- The label.",
      "    label: string",
      "  end",
      "end",
      "",
      "return raw"),
    ["cosmic/thing.tl"] = source(
      "--- Things.",
      "",
      "local type raw = require(\"cosmic.internal.raw\")",
      "",
      "local record Config",
      "  --- The depth.",
      "  depth: integer",
      "end",
      "",
      "local record Thing",
      "  --- A box.",
      "  type Box = raw.Box",
      "  --- Settings.",
      "  type Config = Config",
      "  --- Named settings.",
      "  record Named is raw.Base",
      "    --- Its own.",
      "    own: string",
      "  end",
      "end",
      "",
      "return Thing"),
  })
  local looked = assert(docs.view({ db }, { true }))
  local function page(query: string): string
    return table.concat(assert(docs.render(looked, assert(docs.lookup(looked, query))[1])), "\n")
  end
  local box = page("Thing.Box")
  assert(box:find("  methods:\n    grow(n: integer): boolean -- Grows the box by `n`.", 1, true), box)
  assert(box:find("    size: integer -- How many things it holds.", 1, true), box)
  assert(not box:find("_hidden", 1, true), box)
  local config = page("Thing.Config")
  assert(config:find("  fields:\n    depth: integer -- The depth.", 1, true), config)
  local named = page("Thing.Named")
  assert(named:find("    own: string -- Its own.", 1, true), named)
  assert(named:find("  inherited fields:\n    label: string -- The label.", 1, true), named)
  local grow = assert(docs.lookup(looked, "Thing.Box.grow"))
  assert(#grow == 1 and grow[1].source_symbol == "Thing.Box.grow", tostring(#grow))
  local depth = assert(docs.lookup(looked, "Thing.Config.depth"))
  assert(#depth == 1 and depth[1].signature == "depth: integer", tostring(#depth))
end

--- A type of one public module aliased or extended in another, under
--- whatever name that module binds its module to (`B`, not `Base`), as
--- `type Entry = B.Entry` and `record Item is B.Entry`: the page lists
--- what it takes, each member answers to its own dotted name once, an
--- alias of that alias in a third module follows on, and a cycle of
--- aliases across modules names nothing. A type the module declares
--- under the bound name, in a record enclosing the reference, hides the
--- bound module there.
local function test_a_type_takes_members_through_a_required_module(dir: string)
  local db = built(dir, {
    ["cosmic/base.tl"] = source(
      "--- Bases.",
      "local record Base",
      "  --- One entry.",
      "  interface Entry",
      "    --- Its path.",
      "    path: string",
      "    --- Its body.",
      "    open: function(Entry): string",
      "  end",
      "end",
      "",
      "return Base"),
    ["cosmic/user.tl"] = source(
      "--- Users.",
      "local B = require(\"cosmic.base\")",
      "",
      "local record User",
      "  --- An entry, as the base has it.",
      "  type Entry = B.Entry",
      "  --- An entry of its own.",
      "  record Item is B.Entry",
      "    --- Its size.",
      "    size: integer",
      "  end",
      "end",
      "",
      "return User"),
    ["cosmic/shadow.tl"] = source(
      "--- Shadows.",
      "local B = require(\"cosmic.base\")",
      "",
      "local record Shadow",
      "  --- Its own B.",
      "  record B",
      "    --- Its own entry.",
      "    record Entry",
      "      --- Its mark.",
      "      mark: integer",
      "    end",
      "  end",
      "  --- The nested B's entry.",
      "  type Entry = B.Entry",
      "end",
      "",
      "return Shadow"),
    ["cosmic/third.tl"] = source(
      "--- Thirds.",
      "local type U = require(\"cosmic.user\")",
      "",
      "local record Third",
      "  --- The user's entry.",
      "  type Entry = U.Entry",
      "end",
      "",
      "return Third"),
    ["cosmic/loop_a.tl"] = source(
      "--- One side.",
      "local LB = require(\"cosmic.loop_b\")",
      "",
      "local record LoopA",
      "  --- The other side's.",
      "  type A = LB.B",
      "end",
      "",
      "return LoopA"),
    ["cosmic/loop_b.tl"] = source(
      "--- The other side.",
      "local LA = require(\"cosmic.loop_a\")",
      "",
      "local record LoopB",
      "  --- The first side's.",
      "  type B = LA.A",
      "end",
      "",
      "return LoopB"),
  })
  local looked = assert(docs.view({ db }, { true }))
  local function page(query: string): string
    return table.concat(assert(docs.render(looked, assert(docs.lookup(looked, query))[1])), "\n")
  end
  local entry = page("User.Entry")
  assert(entry:find("  fields:\n    path: string -- Its path.", 1, true), entry)
  assert(entry:find("  methods:\n    open(): string -- Its body.", 1, true), entry)
  local item = page("User.Item")
  assert(item:find("    size: integer -- Its size.", 1, true), item)
  assert(item:find("  inherited fields:\n    path: string -- Its path.", 1, true), item)
  local function found(query: string): string
    local rows = assert(docs.lookup(looked, query))
    local out: {string} = {}
    for _, row in ipairs(rows) do
      out[#out + 1] = row.module .. " " .. row.source_symbol .. " " .. row.signature
    end
    return table.concat(out, " | ")
  end
  assert(found("User.Entry.path") == "cosmic.user User.Entry.path path: string",
    found("User.Entry.path"))
  assert(found("User.Item.path") == "cosmic.user User.Item.path path: string",
    found("User.Item.path"))
  assert(found("Third.Entry.open") == "cosmic.third Third.Entry.open open: function(Entry): string",
    found("Third.Entry.open"))
  assert(found("LoopA.A.path") == "", found("LoopA.A.path"))
  assert(found("Shadow.Entry.mark") == "cosmic.shadow Shadow.Entry.mark mark: integer",
    found("Shadow.Entry.mark"))
  -- Base.Entry.path, which answers by its last names, is not Shadow's.
  assert(not found("Shadow.Entry.path"):find("cosmic.shadow", 1, true),
    found("Shadow.Entry.path"))
end

--- A binary carries a user guide as its own doc row, with no module
--- row beside it. A public source lists it with the guide's first
--- sentence, finds it by its bare name, and shows the whole prose; a
--- guide the binary does not carry is not there.
local function test_a_public_source_lists_and_finds_a_user_guide(_: string)
  local db = database({
    { "cosmic.fs", "", "module", "", "Files.", "cosmic/fs.tl", "1" },
    { "doc.guides.quickstart", "", "module", "",
      "A tour of the library. It shows each module.\n\n## first step\n\nDo this.",
      "doc/guides/quickstart.md", "1" },
    { "doc.guides.portable-runtime", "", "module", "", "How it is built.",
      "doc/guides/portable-runtime.md", "1" },
  }, {}, { "cosmic.fs" })
  local public = assert(docs.view({ db }, { true }))
  local listed: {string} = {}
  for _, summary in ipairs((assert(docs.index(public)))) do
    listed[#listed + 1] = summary.module .. "|" .. summary.text
  end
  assert(table.concat(listed, "\n") == "cosmic.fs|Files.\n" ..
      "doc.guides.quickstart|A tour of the library.", table.concat(listed, "\n"))
  local found = assert(docs.lookup(public, "quickstart"))
  assert(#found == 1 and found[1].module == "doc.guides.quickstart", tostring(#found))
  local lines = table.concat(assert(docs.render(public, found[1])), "\n")
  assert(lines:find("## first step", 1, true) ~= nil, lines)
  assert(#assert(docs.lookup(public, "portable-runtime")) == 0, "an internal guide is public")
end

--- The helpers an example carries show between its requires and its
--- function, on the page of a symbol it calls and on another's, and only
--- the function counts toward "the shorter" in the ranking.
local function test_an_example_page_shows_its_helpers_above_the_function(dir: string)
  local db = built(dir, fs_tree({
    ["cosmic/fs_example.tl"] = source(
      "local Fs = require(\"cosmic.fs\")",
      "",
      "local record Example",
      "end",
      "",
      "local function path(): string",
      "  return \"x\"",
      "end",
      "",
      "--- Reads a file back.",
      "function Example.read()",
      "  print(Fs.read(path()))",
      "end",
      "",
      "return Example"),
  }))
  local looked = view({ db })
  local page = table.concat(assert(docs.render(looked,
    assert(docs.lookup(looked, "Fs.read"))[1])), "\n")
  assert(page:find('    local Fs = require("cosmic.fs")\n\n    local function path(): string\n' ..
      '      return "x"\n    end\n\n    function Example.read()', 1, true), page)
end

--- With a top-level call also carried, a page of a symbol the call is
--- not about keeps the helpers and drops the call.
local function test_helpers_stay_when_the_calls_are_dropped(dir: string)
  local db = built(dir, {
    ["cosmic/thing.tl"] = source(
      "--- Things.",
      "",
      "local record Thing",
      "end",
      "",
      "--- Declares something.",
      "function Thing.declare(value: string)",
      "end",
      "",
      "--- Does another thing.",
      "function Thing.other()",
      "end",
      "",
      "return Thing"),
    ["cosmic/thing_example.tl"] = source(
      "local Thing = require(\"cosmic.thing\")",
      "",
      "Thing.declare{ value = \"x\" }",
      "",
      "local record Example",
      "end",
      "",
      "local function again()",
      "  Thing.other()",
      "end",
      "",
      "--- The call at the top.",
      "function Example.first()",
      "  again()",
      "end",
      "",
      "return Example"),
  })
  local looked = view({ db })
  local other = table.concat(assert(docs.render(looked,
    assert(docs.lookup(looked, "Thing.other"))[1])), "\n")
  assert(not other:find("Thing.declare", 1, true), other)
  assert(other:find('    local Thing = require("cosmic.thing")\n\n    local function again()', 1, true), other)
end

--- What a lookup answers, an entry to a line, in order.
local function listed(found: docs.Lookup): string
  local lines: {string} = { tostring(found.exact) }
  for _, entry in ipairs(found) do
    lines[#lines + 1] = entry.module .. " " .. entry.symbol .. " " .. entry.source_symbol ..
      " " .. entry.kind .. " " .. tostring(entry.uses)
  end
  return table.concat(lines, "\n")
end

--- A lookup finds the same rows through the indexes of `docs` as with
--- none, as in a database written before they existed, a public view's
--- hiding of a module's `local` declarations included; and finding a
--- name reads its candidates through the index of last names. A local
--- declaration hides only its own module's symbols (cosmic.box's `Fs`
--- leaves [`Fs.read`] shown), and a module's own name answers its page.
local function test_a_lookup_answers_alike_with_the_indexes_or_without(dir: string)
  local db = built(dir, fs_tree({
    ["cosmic/box.tl"] = source(
      "local record Box",
      "end",
      "",
      "--- Makes it larger.",
      "function Box:grow(by: integer)",
      "end",
      "",
      "--- Reads it, privately.",
      "local function read(): string",
      "  return \"\"",
      "end",
      "",
      "--- Named as another module's record is.",
      "local function Fs(): string",
      "  return \"\"",
      "end",
      "",
      "--- Reads it.",
      "function Box.read(): string",
      "  return read() .. Fs()",
      "end",
      "",
      "return Box"),
  }))
  local plan = assert(Sqlite.text_rows(db, "EXPLAIN QUERY PLAN SELECT d.symbol FROM docs d WHERE " ..
      symbols.named_where("d"), { { text = "grow" } }))
  local steps: {string} = {}
  for _, row in ipairs(plan) do steps[#steps + 1] = row[#row] end
  assert(table.concat(steps, "\n"):find("docs_by_last_name", 1, true) ~= nil,
    table.concat(steps, "\n"))
  local queries = { "read", "Fs.read", "grow", "Box.grow", "Box:grow", "cosmic.fs", "fs", "box",
    "cosmic.box", "write", "Box", "nothing" }
  local function every(public: boolean): {string}
    local out: {string} = {}
    local looked = assert(docs.view({ db }, { public }))
    for _, query in ipairs(queries) do
      local found, trouble = docs.lookup(looked, query)
      out[#out + 1] = query .. ": " .. (found ~= nil and listed(found) or "nil " .. trouble)
    end
    return out
  end
  local public = assert(docs.view({ db }, { true }))
  local read = assert(docs.lookup(public, "Fs.read"))
  assert(read.exact and #read == 1 and read[1].module == "cosmic.fs", listed(read))
  local page = assert(docs.lookup(public, "cosmic.fs"))
  assert(page.exact and #page == 1 and page[1].kind == "module", listed(page))
  local indexed_public, indexed_private = every(true), every(false)
  local names = assert(Sqlite.text_rows(db,
    "SELECT name FROM sqlite_schema WHERE type = 'index' AND tbl_name = 'docs' AND sql IS NOT NULL"))
  local present: {string: boolean} = {}
  for _, row in ipairs(names) do present[row[1]] = true end
  assert(present["docs_by_last_name"] and present[schema.local_index], table.concat(
    (function(): {string}
      local all: {string} = {}
      for name in pairs(present) do all[#all + 1] = name end
      return all
    end)(), " "))
  -- The fixture's handle is read-only; a writable one on its file drops
  -- them, which the read-only handle reads on its next query.
  local files = assert(Fs.list(dir))
  local path: string = nil
  for _, name in ipairs(files) do
    if name:match("^cosmic%-%d+%.db$") then path = dir .. "/" .. name end
  end
  local writable = assert(Sqlite.open(assert(path), { writable = true }))
  for _, row in ipairs(names) do assert(writable:exec("DROP INDEX " .. row[1])) end
  assert(writable:close())
  local plain_public, plain_private = every(true), every(false)
  for index, line in ipairs(indexed_public) do
    assert(line == plain_public[index], line .. "\n--\n" .. plain_public[index])
    assert(indexed_private[index] == plain_private[index], indexed_private[index])
  end
end
