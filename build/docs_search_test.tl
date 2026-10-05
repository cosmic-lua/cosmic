--- Searches in words, over the standard library's own documentation as
--- a project outside cosmic's tree sees it: each query a person would
--- type finds the symbol they meant among its first three answers. Kept
--- in a module of its own because it reads every module's rows
--- (`store`), so it runs again on any edit to a doc comment.

local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local Test = require("cosmic.test")
local docs = require("build.docs")
local String = require("cosmic.string")

Test.policy{
  grants = { { path = "core", letters = "r" }, { path = "o/cosmic.db", letters = "r" } },
}

--- The queries, each with the symbols any one of which must be among the
--- first three answers. A trailing `.` names every symbol under a
--- prefix (`Hash.` is any of `Hash`'s).
local QUERIES: {{string}} = {
  { "read a file", "Fs.read" },
  { "reading files", "Fs.read" },
  { "run a program", "Child.run" },
  { "parse json", "Json.decode" },
  { "write a test", "Layout", "cosmic.layout", "cosmic.test" },
  { "sleep", "Clock.sleep_ns" },
  { "http get", "Http.get" },
  { "sha256", "Hash." },
  { "temporary directory", "Fs.mkdtemp" },
  { "command line options", "Flags.parse" },
}

local function shown(entry: docs.Entry): string
  if entry.symbol == "" then return entry.module end
  return entry.source_symbol
end

local function names(view: docs.View, query: string): {string}
  local found = assert(docs.lookup(view, query))
  local out: {string} = {}
  for index = 1, math.min(3, #found) do
    out[#out + 1] = shown(found[index])
  end
  return out
end

--- What a person types finds what they meant: the words are stemmed
--- ("reading files" finds a comment that says "a file"), a query that no one
--- symbol answers whole still finds the ones that answer part of it, and
--- a member named for a word comes before prose that only says it.
local function test_a_search_in_words_finds_the_symbol_meant()
  local databases: {Sqlite.Handle} = Store.databases()
  local public: {boolean} = {}
  for index = 1, #databases do public[index] = true end
  local view = assert(docs.view(databases, public))
  for _, row in ipairs(QUERIES) do
    local top = names(view, row[1])
    local found = false
    for index = 2, #row do
      for _, name in ipairs(top) do
        if name == row[index] or (row[index]:sub(-1) == "." and
            String.starts_with(name, row[index])) then
          found = true
        end
      end
    end
    assert(found, "'" .. row[1] .. "' should reach " .. table.concat(row, " or ", 2) ..
        " in its first three answers, not " .. table.concat(top, ", "))
  end
end
