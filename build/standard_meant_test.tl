--- What a `require` of a `cosmic.*` name the binary has no module of may have meant, read from the docs.

local Doc = require("cosmic.doc")
local StandardMeant = require("build.standard_meant")
local Test = require("cosmic.test")

Test.policy{}

local function summary(module: string, text: string): Doc.Summary
  return { module = module, text = text, closed = "" }
end

--- Docs of a few modules, where [`cosmic.codec`] has a function `base64`.
local DOCS <const>: StandardMeant.Docs = {
  index = { summary("cosmic.codec", "Byte-to-text encodings: hexadecimal and base64."),
    summary("cosmic.compress", "Compression and expansion: deflate, gzip and zstd."),
    summary("cosmic.fs", "Files and directories."), summary("cosmic.web.route", "Routes, under web."),
    summary("cosmic.test", "Tests, the tool's own.") },
  exact = function(word: string): {{string}}
    if word ~= "base64" then return {} end
    return { { "cosmic.codec", "base64", "function" }, { "cosmic.fs", "base64", "field" } }
  end,
  takes = function(word: string): {{string}}
    if word ~= "path" then return {} end
    -- Four functions of one module take a `path` (one in each of two databases), and one of another.
    return { { "cosmic.fs", "Fs.basename" }, { "cosmic.fs", "Fs.dirname" }, { "cosmic.fs", "Fs.read" },
      { "cosmic.fs", "Fs.read" }, { "cosmic.fs", "Fs.write" }, { "cosmic.web.route", "Route.match" } }
  end,
}

local function test_a_wrong_module_name_finds_the_module_that_has_it()
  local base64 = StandardMeant.of("cosmic.base64", DOCS)
  assert(#base64 == 1 and base64[1] == "`cosmic.codec` (has `base64`)", table.concat(base64, " | "))
  -- A name an edit from a module's comes first, with what the module is for; a word of a summary names its module.
  local fz = StandardMeant.of("cosmic.fz", DOCS)
  assert(#fz == 1 and fz[1] == "`cosmic.fs` (Files and directories.)", table.concat(fz, " | "))
  local gzip = StandardMeant.of("cosmic.gzip", DOCS)
  assert(#gzip == 1 and gzip[1] == "`cosmic.compress` (Compression and expansion: deflate, gzip and zstd.)", gzip[1])
  -- The last part of a name finds a module below another, and a misspelled one.
  local route = StandardMeant.of("cosmic.route", DOCS)
  assert(#route == 1 and route[1] == "`cosmic.web.route` (Routes, under web.)", table.concat(route, " | "))
  assert(#StandardMeant.of("cosmic.web.rote", DOCS) == 1)
  -- A module named for a word its functions take names the module that has most of them; one function is not enough.
  local path = StandardMeant.of("cosmic.path", DOCS)
  assert(#path == 1 and path[1] == "`cosmic.fs` (4 functions take a `path`: basename, dirname, read, write)",
    table.concat(path, " | "))
  -- No name outside cosmic, none of the tool's own modules, and none for a word nothing holds.
  assert(#StandardMeant.of("app.thing", DOCS) == 0 and #StandardMeant.of("cosmic.zzqqxx", DOCS) == 0)
  assert(#StandardMeant.of("cosmic.tests", DOCS) == 0)
end

--- The driver's own answer wins; where it has none, the docs are asked.
local function test_wrap_asks_the_docs_where_the_tree_has_no_answer()
  local function none(_: string, _: string): {string} return {} end
  local function own(_: string, _: string): {string} return { "`b.m` (b/m.tl)" } end
  local wrapped = StandardMeant.wrap(none, DOCS)
  assert(table.concat(wrapped("cosmic.base64", "a.tl"), " | ") == "`cosmic.codec` (has `base64`)")
  assert(table.concat(StandardMeant.wrap(own, DOCS)("cosmic.base64", "a.tl"), " | ") == "`b.m` (b/m.tl)")
  -- With no docs to read (a test's store withholds them), it names nothing and raises nothing.
  assert(#StandardMeant.wrap(none)("cosmic.base64", "a.tl") == 0)
end
