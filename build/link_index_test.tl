local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local Test = require("cosmic.test")
local docs = require("build.docs")
local fixture = require("build.docs_fixture")
local importer = require("build.importer")
local teal = require("build.teal")
local work = require("build.work")
local writer = require("build.writer")

--- The docs fixture and the projects here build with the tree's own code.
Test.needs{ reads = { "core" } }

local built = assert(teal.load())

--- Lines as one source file's text.
local function source(...: string): string
  return table.concat({ ... }, "\n") .. "\n"
end

--- The rows of `sql` over `db`, each row's cells joined by spaces.
local function rows(db: Sqlite.Handle, sql: string): {string}
  local out: {string} = {}
  for _, row in ipairs((assert(Sqlite.text_rows(db, sql)))) do
    out[#out + 1] = table.concat(row, " ")
  end
  return out
end

local function same(got: {string}, want: {string})
  local a, b = table.concat(got, "\n"), table.concat(want, "\n")
  assert(a == b, "got:\n" .. a .. "\nwant:\n" .. b)
end

--- Modules whose comments link to another's symbols, to their own, to
--- a file and to a heading of one, beside links that name
--- nothing, a URL and a parameter, which are left out.
local function linking_tree(dir: string): Sqlite.Handle
  assert(Fs.mkdirs(dir .. "/doc"))
  assert(Fs.write(dir .. "/doc/meta.md", source("# Meta", "", "## Every example runs", "")))
  return fixture.database(dir, {
    ["cosmic/fs.tl"] = source(
      "--- Files and directories.",
      "",
      "local record Fs",
      "end",
      "",
      "--- The whole of a file; [`Fs.write`] writes one, as",
      "--- [the rule](../doc/meta.md#every-example-runs) shows.",
      "function Fs.read(path: string): string | nil, string",
      "  return nil, path",
      "end",
      "",
      "--- Writes the whole of `data` to [`path`].",
      "function Fs.write(path: string, data: string): boolean, string",
      "  return false, path .. data",
      "end",
      "",
      "return Fs"),
    ["build/boot.tl"] = source(
      "local Fs = require(\"cosmic.fs\")",
      "",
      "-- Reads with [`Fs.read`], as [`cosmic.fs`] says; see [the notes][notes].",
      "-- [notes]: /doc/meta.md",
      "local text = Fs.read(\"boot\")",
      "",
      "-- Not [here](nowhere.md), nor [`nothing`]; [the web](https://example.com).",
      "-- Twice on a line: [`Fs.write`], [again](Fs.write).",
      "return text"),
    ["cosmic/raw.d.tl"] = source(
      "--- Raw calls, which [`cosmic.fs.read`] wraps.",
      "local record raw",
      "  --- Opens.",
      "  open: function(path: string): integer",
      "end",
      "",
      "return raw"),
  })
end

--- Each link that resolves is a row: what it names, where it is, its
--- form and its source. One to a file is kept by its path from the root,
--- and one in a declaration under the module the declaration is.
local function test_a_resolved_link_is_a_row(dir: string)
  local db = linking_tree(dir)
  same(rows(db, "SELECT from_file, line, column, kind, module, symbol, path, anchor, " ..
    "form, source, text FROM links ORDER BY from_file, line, column"), {
    "build/boot.tl 3 15 symbol cosmic.fs read   shortcut comment `Fs.read`",
    "build/boot.tl 3 31 symbol cosmic.fs    shortcut comment `cosmic.fs`",
    "build/boot.tl 3 55 file   doc/meta.md  reference comment the notes",
    "build/boot.tl 8 21 symbol cosmic.fs write   shortcut comment `Fs.write`",
    "build/boot.tl 8 35 symbol cosmic.fs write   inline comment again",
    "cosmic/fs.tl 6 26 symbol cosmic.fs write   shortcut doc `Fs.write`",
    "cosmic/fs.tl 7 5 anchor   doc/meta.md every-example-runs inline doc the rule",
    "cosmic/raw.d.tl 1 22 symbol cosmic.fs read   shortcut doc `cosmic.fs.read`",
  })
  same(rows(db, "SELECT DISTINCT from_module FROM links WHERE from_file = 'cosmic/raw.d.tl'"),
    { "cosmic.raw" })
  assert(db:close())
end

--- `cosmic uses` lists a symbol's links beside its uses, and a file's
--- links by its path, with a heading's anchor or without.
local function test_uses_lists_links_to_a_symbol_and_a_file(dir: string)
  local db = linking_tree(dir)
  local view = assert(docs.view({ db }))
  local function listed(query: string): {string}
    local out: {string} = {}
    for _, use in ipairs((assert(docs.uses(view, query)))) do
      out[#out + 1] = use.from_file .. ":" .. use.line .. (use.link and " link " or " ") ..
        use.module .. " " .. use.symbol .. " " .. use.path .. "#" .. use.anchor
    end
    return out
  end
  -- Uses and links by where they are.
  same(listed("Fs.read"), {
    "build/boot.tl:3 link cosmic.fs read #",
    "build/boot.tl:5 cosmic.fs read #",
    "cosmic/raw.d.tl:1 link cosmic.fs read #",
  })
  -- Two links on one line to one symbol are one place.
  same(listed("Fs.write"), {
    "build/boot.tl:8 link cosmic.fs write #",
    "cosmic/fs.tl:6 link cosmic.fs write #",
  })
  same(listed("cosmic.fs"), { "build/boot.tl:3 link cosmic.fs  #" })
  -- A module's last name, as `cosmic docs` reads a bare name.
  same(listed("fs"), { "build/boot.tl:3 link cosmic.fs  #" })
  same(listed("doc/meta.md#every-example-runs"), {
    "cosmic/fs.tl:7 link   doc/meta.md#every-example-runs",
  })
  same(listed("./doc/meta.md"), {
    "build/boot.tl:3 link   doc/meta.md#",
    "cosmic/fs.tl:7 link   doc/meta.md#every-example-runs",
  })
  same(listed("doc/meta.md#meta"), {})
  assert(db:close())
end

--- A symbol's page says how many links name it, beside its uses.
local function test_a_page_counts_the_links_to_its_symbol(dir: string)
  local db = linking_tree(dir)
  local view = assert(docs.view({ db }))
  local function page(query: string): string
    local found = assert(docs.lookup(view, query))
    assert(#found == 1, query .. ": " .. #found)
    return table.concat(assert(docs.render(view, found[1])), "\n")
  end
  -- Two links on one line count once, as `cosmic uses` lists them.
  local write = page("Fs.write")
  assert(write:find("\n  linked from 2 places; cosmic uses Fs.write", 1, true) ~= nil, write)
  local read = page("Fs.read")
  assert(read:find("\n  used in 1 place and linked from 2; cosmic uses Fs.read", 1, true) ~= nil,
    read)
  local module = page("cosmic.fs")
  assert(module:find("(1 use, 2 links)", 1, true) ~= nil, module)
  assert(module:find("(2 links)", 1, true) ~= nil, module)
  assert(module:find("\n  linked from 1 place; cosmic uses cosmic.fs", 1, true) ~= nil, module)
  assert(db:close())
end

--- A project on disk at `root`: `greet`, whose comment links to
--- `target` and to a heading of notes.md, and whose farewell is named
--- `bye`; and `wave`, whose comment links to `greet.bye`.
local function write_project(root: string, target: string, bye: string)
  assert(Fs.mkdirs(root))
  assert(Fs.write(root .. "/greet.tl", source(
    "--- Greets; see [`" .. target .. "`] and [the notes](notes.md#usage).",
    "local record greet",
    "end",
    "",
    "--- Says hello.",
    "function greet.hello(): string",
    "  return \"hello\"",
    "end",
    "",
    "--- Says goodbye.",
    "function greet." .. bye .. "(): string",
    "  return \"bye\"",
    "end",
    "",
    "return greet")))
  assert(Fs.write(root .. "/wave.tl", source(
    "local greet = require(\"greet\")",
    "-- Waves as [`greet.bye`] does.",
    "return greet.hello")))
end

--- Builds the project `handle` holds into `out` and answers its links,
--- each as `file:line kind symbol path#anchor`.
local function build_links(handle: work.Handle, out: string): {string}
  assert(work.stage(handle, false))
  local result = assert(importer.compile(handle, built, "link-index-test"))
  assert(writer.write_result(handle, out, result))
  local db = assert(Sqlite.open(out, false))
  local found = rows(db, "SELECT from_file || ':' || line, kind, symbol, path || '#' || anchor " ..
    "FROM links ORDER BY from_file, line, column")
  assert(db:close())
  return found
end

--- A row follows what it is a function of: a comment's link edited, a
--- file it names coming to be and changing, and the symbol it names
--- renamed in another module, each move the projection's rows at the
--- next build, though no module's key moves for the file.
local function test_a_row_follows_its_link_and_its_file(tmp: string)
  local root = assert(Fs.absolute(tmp)) .. "/project"
  write_project(root, "greet.hello", "bye")
  local handle = assert(work.open(root))
  local out = root .. "/o/cosmic.db"
  same(build_links(handle, out), { "greet.tl:1 symbol hello #", "wave.tl:2 symbol bye #" })
  assert(Fs.write(root .. "/notes.md", source("# Usage")))
  same(build_links(handle, out), { "greet.tl:1 symbol hello #", "greet.tl:1 anchor  notes.md#usage",
    "wave.tl:2 symbol bye #" })
  write_project(root, "greet.bye", "bye")
  same(build_links(handle, out), { "greet.tl:1 symbol bye #", "greet.tl:1 anchor  notes.md#usage",
    "wave.tl:2 symbol bye #" })
  assert(Fs.write(root .. "/notes.md", source("# Other")))
  same(build_links(handle, out), { "greet.tl:1 symbol bye #", "wave.tl:2 symbol bye #" })
  -- `bye` renamed: wave.tl, unedited, names nothing any more.
  write_project(root, "greet.hello", "farewell")
  same(build_links(handle, out), { "greet.tl:1 symbol hello #" })
  assert(work.close(handle))
end

--- A member of a type an alias stands for is a row under the alias's
--- module, whether the link spells it from the alias, from its module
--- or through a required module, as `cosmic docs` reads it; so is a
--- field of the record a module's value is typed as, and not one of
--- another record the module exports.
local function test_a_member_through_an_alias_or_a_typed_value_is_a_row(dir: string)
  local db = fixture.database(dir, {
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
      "local record Thing",
      "  --- A box.",
      "  type Box = raw.Box",
      "end",
      "",
      "return Thing"),
    ["cosmic/verbs.tl"] = source(
      "--- Verbs.",
      "--- What a verb answers.",
      "local record Result",
      "  --- Whether it did.",
      "  ok: boolean",
      "end",
      "",
      "local record Module",
      "  --- The order.",
      "  order: {string}",
      "  --- Runs one.",
      "  run: function(): Result",
      "end",
      "",
      "local module: Module = { order = {}, run = function(): Result return { ok = true } end }",
      "",
      "return module"),
    ["build/boot.tl"] = source(
      "local Thing = require(\"cosmic.thing\")",
      "local Verbs = require(\"cosmic.verbs\")",
      "",
      "-- [`Thing.Box.grow`], [`cosmic.thing.Box.grow`]; not [`Thing.Box.shrink`].",
      "-- [`Verbs.order`], [`cosmic.verbs.order`]; not [`Verbs.chaos`], [`Verbs.ok`].",
      "return Thing"),
  })
  same(rows(db, "SELECT from_file, line, column, module, symbol FROM links " ..
    "WHERE from_file = 'build/boot.tl' ORDER BY line, column"), {
    "build/boot.tl 4 4 cosmic.thing Box.grow",
    "build/boot.tl 4 24 cosmic.thing Box.grow",
    "build/boot.tl 5 4 cosmic.verbs Module.order",
    "build/boot.tl 5 21 cosmic.verbs Module.order",
  })
  assert(db:close())
end

--- The links of `out`'s files that are no module, each as
--- `file:line:column source kind symbol path#anchor`.
local function file_links(out: string): {string}
  local db = assert(Sqlite.open(out, false))
  local found = rows(db, "SELECT from_file || ':' || line || ':' || column, source, kind, " ..
    "symbol, path || '#' || anchor FROM links WHERE from_module = '' " ..
    "ORDER BY from_file, line, column")
  assert(db:close())
  return found
end

--- What `cosmic uses` lists for `query` in the projection at `out`, each
--- as `file:line`.
local function places(out: string, query: string): {string}
  local db = assert(Sqlite.open(out, false))
  local found: {string} = {}
  for _, use in ipairs((assert(docs.uses(assert(docs.view({ db })), query)))) do
    found[#found + 1] = use.from_file .. ":" .. use.line .. (use.link and " link" or "")
  end
  assert(db:close())
  return found
end

--- Sets the modification time of each of `paths` under `root` to one
--- long past, the same for each call with the same `at`, so that a stage
--- trusts a stat of it.
local function settle(root: string, at: integer, paths: {string})
  for _, path in ipairs(paths) do
    assert(Fs.set_mtime(root .. "/" .. path, 1000000000 + at))
  end
end

--- A project's Markdown, wherever `cosmic fix` reads it (doc/'s prose
--- too, which the build reads nothing else of), and its Zig are indexed
--- as a module's comments are, each link under its file and no module,
--- and `cosmic uses` lists them.
local function test_a_markdown_or_zig_files_links_are_rows(tmp: string)
  local root = assert(Fs.absolute(tmp)) .. "/project"
  write_project(root, "greet.hello", "bye")
  assert(Fs.mkdirs(root .. "/doc"))
  assert(Fs.mkdirs(root .. "/.hidden"))
  assert(Fs.write(root .. "/README.md", source("# Greet", "",
    "Say it with [`greet.hello`], as [the notes](doc/notes.md#usage) say.")))
  assert(Fs.write(root .. "/doc/notes.md", source("# Usage", "", "Then [`greet.bye`].")))
  assert(Fs.write(root .. "/build.zig", source("// Builds what [`greet.hello`] greets.")))
  assert(Fs.write(root .. "/.hidden/away.md", source("Not [`greet.hello`].")))
  local handle = assert(work.open(root))
  local out = root .. "/o/cosmic.db"
  build_links(handle, out)
  assert(work.close(handle))
  same(file_links(out), {
    "README.md:3:13 text symbol hello #",
    "README.md:3:33 text anchor  doc/notes.md#usage",
    "build.zig:1:16 comment symbol hello #",
    "doc/notes.md:3:6 text symbol bye #",
  })
  same(places(out, "greet.hello"),
    { "README.md:3 link", "build.zig:1 link", "greet.tl:1 link", "wave.tl:3" })
  same(places(out, "doc/notes.md"), { "README.md:3 link" })
end

--- A file's links are read once for each text it holds: a stage that
--- finds every file as it was reads none of them again, and the
--- projection's signature stands; an edit to a Markdown file's text
--- moves the signature though no link moves, and one to a link moves
--- its row.
local function test_a_files_text_signs_the_projection(tmp: string)
  local root = assert(Fs.absolute(tmp)) .. "/project"
  write_project(root, "greet.hello", "bye")
  assert(Fs.write(root .. "/README.md", source("# Greet", "", "Say it with [`greet.hello`].")))
  local every = { "greet.tl", "wave.tl", "README.md" }
  settle(root, 1, every)
  local handle = assert(work.open(root))
  local function staged(): work.Staged
    local stage = assert(work.stage(handle, false))
    assert(work.commit(handle))
    return stage
  end
  local function signed(): string
    local result = assert(importer.compile(handle, built, "link-index-test"))
    return (assert(writer.signature(handle, result, "a writer")))
  end
  assert(staged().read == 3)
  local first = signed()
  local found = rows(handle.db, "SELECT sha256, kind FROM linked_texts")
  same(found, { assert(rows(handle.db, "SELECT sha256 FROM linked"))[1] .. " markdown" })
  -- Nothing moved: nothing is read again, and the signature stands.
  assert(staged().read == 0)
  assert(signed() == first)
  -- Prose alone moved.
  assert(Fs.write(root .. "/README.md", source("# Greet", "", "Say it with [`greet.hello`].",
    "", "Loudly.")))
  settle(root, 2, { "README.md" })
  assert(staged().read == 1)
  local prose = signed()
  assert(prose ~= first)
  -- A link moved.
  assert(Fs.write(root .. "/README.md", source("# Greet", "", "Say it with [`greet.bye`].")))
  settle(root, 3, { "README.md" })
  assert(staged().read == 1)
  assert(signed() ~= prose)
  local out = root .. "/o/cosmic.db"
  build_links(handle, out)
  same(file_links(out), { "README.md:3:13 text symbol bye #" })
  assert(work.close(handle))
end

--- In cosmic's own tree C is indexed too, at the column of its file a
--- link is at, and a tree of its own inside it (ci/) is not: its links
--- are that tree's.
local function test_a_c_comments_links_are_rows_but_not_ci(tmp: string)
  local root = assert(Fs.absolute(tmp)) .. "/tree"
  write_project(root, "greet.hello", "bye")
  assert(Fs.mkdirs(root .. "/core"))
  assert(Fs.mkdirs(root .. "/ci"))
  assert(Fs.write(root .. "/core/greet.c", source(
    "/* Greets as [`greet.hello`] does. */",
    "int greet (void);",
    "",
    "  // Then [`greet.bye`].")))
  assert(Fs.write(root .. "/ci/README.md", source("CI's own [`greet.hello`].")))
  local handle = assert(work.open(root))
  assert(work.stage(handle, true))
  local result = assert(importer.compile(handle, built, "link-index-test"))
  local out = root .. "/o/cosmic.db"
  assert(writer.write_result(handle, out, result))
  assert(work.close(handle))
  same(file_links(out), {
    "core/greet.c:1:14 comment symbol hello #",
    "core/greet.c:4:11 comment symbol bye #",
  })
  same(places(out, "greet.hello"), { "core/greet.c:1 link", "greet.tl:1 link", "wave.tl:3" })
end
