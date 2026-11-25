--- Searches in words, over the standard library's own documentation as
--- a project outside cosmic's tree sees it: each query a person would
--- type finds the symbol they meant among its first three results. Kept
--- in a module of its own because it reads every module's rows
--- (`store`), so it runs again on any edit to a doc comment.

local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local Test = require("cosmic.test")
local docs = require("build.docs")
local Doc = require("cosmic.doc")
local String = require("cosmic.string")

Test.policy{
  grants = { { path = "core", letters = "r" }, { path = "o/cosmic.db", letters = "r" } },
}

local record Query
  query: string
  reaches: {string}
end

--- The queries, each with the symbols any one of which must be among the
--- first three results. A trailing `.` names every symbol under a
--- prefix (`Hash.` is any of `Hash`'s).
local QUERIES: {Query} = {
  { query = "read a file", reaches = { "Fs.read" } },
  { query = "reading files", reaches = { "Fs.read" } },
  { query = "run a program", reaches = { "Child.run" } },
  { query = "parse json", reaches = { "Json.decode" } },
  { query = "write a test", reaches = { "Layout", "cosmic.layout", "cosmic.test" } },
  { query = "sleep", reaches = { "Clock.sleep" } },
  { query = "http get", reaches = { "Http.get" } },
  { query = "sha256", reaches = { "Hash." } },
  { query = "temporary directory", reaches = { "Fs.mkdtemp" } },
  { query = "command line options", reaches = { "Flags.parse" } },
}

local function shown(entry: Doc.Entry): string
  if entry.symbol == "" then return entry.module end
  return entry.source_symbol
end

local function names(view: Doc.View, query: string): {string}
  local found = assert(Doc.lookup(view, query))
  local out: mut {string} = {}
  for _, entry in ipairs(found) do
    if #out == 3 then break end
    out[#out + 1] = shown(entry)
  end
  return out
end

--- What a person types finds what they meant: the words are stemmed
--- ("reading files" finds a comment that says "a file"), a query that no one
--- symbol matches whole still finds the ones that match part of it, and
--- a member named for a word comes before prose that only says it.
local function test_a_search_in_words_finds_the_symbol_meant()
  local databases: {Sqlite.Handle} = Store.databases()
  local public: mut {boolean} = {}
  for index = 1, #databases do public[index] = true end
  local view = assert(docs.view(databases, public))
  for _, row in ipairs(QUERIES) do
    local top = names(view, row.query)
    local found = false
    for _, reach in ipairs(row.reaches) do
      for _, name in ipairs(top) do
        if name == reach or (reach:sub(-1) == "." and
            String.starts_with(name, reach)) then
          found = true
        end
      end
    end
    assert(found, "'" .. row.query .. "' should reach " .. table.concat(row.reaches, " or ") ..
        " in its first three answers, not " .. table.concat(top, ", "))
  end
end

--- The tool records the public standard library as public and nothing
--- else: a module of the library any module may require, a declaration of
--- it that is no module ([`cosmic.sys`]), and no internal module, no test,
--- and no module a closed directory keeps to itself (`cosmic.web.router`,
--- where `cosmic.web.input` says `--- @public`). A public source covers
--- exactly these.
local function test_the_tool_records_the_public_library()
  local databases: {Sqlite.Handle} = Store.databases()
  local binary = assert(databases[#databases], "the tool has a database")
  local rows = assert(binary:rows(
    "SELECT (SELECT count(*) FROM public_modules WHERE path IN ('cosmic.fs', 'cosmic.sys', 'cosmic.web', " ..
      "'cosmic.web.input', 'cosmic.http.server')), " ..
      "(SELECT count(*) FROM public_modules WHERE path LIKE 'cosmic.internal.%' OR path LIKE '%\\_test' ESCAPE '\\' " ..
      "OR path NOT LIKE 'cosmic.%'), " ..
      "(SELECT count(*) FROM public_modules WHERE path IN ('cosmic.web.router', 'cosmic.template.lex')), " ..
      "(SELECT count(*) FROM modules WHERE path LIKE 'cosmic.%' AND path NOT LIKE 'cosmic.internal.%' " ..
      "AND file NOT GLOB 'cosmic/*/*' AND path NOT IN (SELECT path FROM public_modules)), " ..
      "(SELECT group_concat(path, ' ' ORDER BY path) FROM modules WHERE kind = 'module' AND path LIKE 'cosmic.%' " ..
      "AND path NOT LIKE 'cosmic.internal.%' AND path NOT IN (SELECT path FROM public_modules))"))
  local row = assert(rows[1])
  assert(row:integer(1) == 5, "a module any module may require is public, a declaration among them: " .. tostring(row:integer(1)))
  assert(row:integer(2) == 0, "an internal module, a test or a module outside the library is recorded: " .. tostring(row:integer(2)))
  assert(row:integer(3) == 0, "a module a closed directory keeps to itself is recorded: " .. tostring(row:integer(3)))
  assert(row:integer(4) == 0, "a module directly under cosmic/ is not recorded: " .. tostring(row:integer(4)))
  -- Every module of the library a closed directory keeps. One more here is a module whose docs a project has lost:
  -- say `--- @public` in it, or name it here on purpose.
  local kept = "cosmic.agent.prompt_data cosmic.agent.prompt_text cosmic.agent.run_text cosmic.agent.run_text_data cosmic.agent.where_text cosmic.http.wire cosmic.mcp.wire cosmic.sandbox.policy cosmic.template.codegen cosmic.template.context " ..
    "cosmic.template.dialect.html cosmic.template.lex cosmic.template.markup cosmic.template.parse " ..
    "cosmic.web.builtin cosmic.web.csrf_field cosmic.web.csrf_meta cosmic.web.dev_tag cosmic.web.error_page cosmic.web.errors " ..
    "cosmic.web.htmx_head cosmic.web.markup_data cosmic.web.negotiate cosmic.web.request cosmic.web.router"
  assert(row:text(5) == kept, "the modules the library keeps to itself: " .. row:text(5))
end
