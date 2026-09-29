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

--- Two modules whose comments link to each other's symbols, to their
--- own, to a file and to a heading of one, beside links that name
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
      "return text"),
  })
end

--- Each link that resolves is a row: what it names, where it is, its
--- form and its source. One to a file is kept by its path from the root.
local function test_a_resolved_link_is_a_row(dir: string)
  local db = linking_tree(dir)
  same(rows(db, "SELECT from_file, line, column, kind, module, symbol, path, anchor, " ..
    "form, source, text FROM links ORDER BY from_file, line, column"), {
    "build/boot.tl 3 15 symbol cosmic.fs read   shortcut comment `Fs.read`",
    "build/boot.tl 3 31 symbol cosmic.fs    shortcut comment `cosmic.fs`",
    "build/boot.tl 3 55 file   doc/meta.md  reference comment the notes",
    "cosmic/fs.tl 6 26 symbol cosmic.fs write   shortcut doc `Fs.write`",
    "cosmic/fs.tl 7 5 anchor   doc/meta.md every-example-runs inline doc the rule",
  })
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
  same(listed("Fs.read"), {
    "build/boot.tl:5 cosmic.fs read #",
    "build/boot.tl:3 link cosmic.fs read #",
  })
  same(listed("cosmic.fs"), { "build/boot.tl:3 link cosmic.fs  #" })
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
  local write = page("Fs.write")
  assert(write:find("\n  linked from 1 place; cosmic uses Fs.write", 1, true) ~= nil, write)
  local read = page("Fs.read")
  assert(read:find("\n  used in 1 place and linked from 1; cosmic uses Fs.read", 1, true) ~= nil,
    read)
  local module = page("cosmic.fs")
  assert(module:find("(1 use, 1 link)", 1, true) ~= nil, module)
  assert(module:find("\n  linked from 1 place; cosmic uses cosmic.fs", 1, true) ~= nil, module)
  assert(db:close())
end

--- A project on disk at `root`: `greet`, whose comment links to
--- `target` and to a heading of notes.md.
local function write_project(root: string, target: string)
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
    "function greet.bye(): string",
    "  return \"bye\"",
    "end",
    "",
    "return greet")))
end

--- Builds the project at `root` into `out` through `handle` and
--- answers its links, each as `line kind symbol path#anchor`.
local function build_links(handle: work.Handle, out: string): {string}
  assert(work.stage(handle, false))
  local result = assert(importer.compile(handle, built, "link-index-test"))
  assert(writer.write_result(handle, out, result))
  local db = assert(Sqlite.open(out, false))
  local found = rows(db, "SELECT line, kind, symbol, path || '#' || anchor FROM links " ..
    "ORDER BY line, column")
  assert(db:close())
  return found
end

--- A row follows what it is a function of: a comment's link edited, and
--- a file it names coming to be, each move the projection's rows at the
--- next build, though no module's key moves for the file.
local function test_a_row_follows_its_link_and_its_file(tmp: string)
  local root = assert(Fs.absolute(tmp)) .. "/project"
  write_project(root, "greet.hello")
  local handle = assert(work.open(root))
  local out = root .. "/o/cosmic.db"
  same(build_links(handle, out), { "1 symbol hello #" })
  assert(Fs.write(root .. "/notes.md", source("# Usage")))
  same(build_links(handle, out), { "1 symbol hello #", "1 anchor  notes.md#usage" })
  write_project(root, "greet.bye")
  same(build_links(handle, out), { "1 symbol bye #", "1 anchor  notes.md#usage" })
  assert(Fs.write(root .. "/notes.md", source("# Other")))
  same(build_links(handle, out), { "1 symbol bye #" })
  assert(work.close(handle))
end
