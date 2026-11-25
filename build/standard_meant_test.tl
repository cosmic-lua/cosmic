--- What a `require` of a `cosmic.*` name the binary has no module of may have meant, read from the docs.

local Doc = require("cosmic.doc")
local StandardMeant = require("build.standard_meant")
local Test = require("cosmic.test")

Test.policy{}

local function summary(module: string, text: string): Doc.Summary
  return { module = module, text = text, closed = "" }
end

--- Docs of three modules, where [`cosmic.codec`] has a function `base64`.
local DOCS <const>: StandardMeant.Docs = {
  index = { summary("cosmic.codec", "Byte-to-text encodings: hexadecimal and base64."),
    summary("cosmic.compress", "Compression and expansion: deflate, gzip and zstd."),
    summary("cosmic.fs", "Files and directories."), summary("cosmic.web.route", "Routes, under web.") },
  exact = function(word: string): {{string}}
    if word ~= "base64" then return {} end
    return { { "cosmic.codec", "base64" } }
  end,
}

local function test_a_wrong_module_name_finds_the_module_that_has_it()
  local base64 = StandardMeant.of("cosmic.base64", DOCS)
  assert(#base64 == 1 and base64[1] == "`cosmic.codec` (has `Codec.base64`)", table.concat(base64, " | "))
  -- A name an edit from a module's comes first, with what the module is for; a word of a summary names its module.
  local fz = StandardMeant.of("cosmic.fz", DOCS)
  assert(#fz == 1 and fz[1] == "`cosmic.fs` (Files and directories.)", table.concat(fz, " | "))
  local gzip = StandardMeant.of("cosmic.gzip", DOCS)
  assert(#gzip == 1 and gzip[1] == "`cosmic.compress` (Compression and expansion: deflate, gzip and zstd.)", gzip[1])
  assert(#StandardMeant.of("app.thing", DOCS) == 0 and #StandardMeant.of("cosmic.zzqqxx", DOCS) == 0)
  -- A module below another (cosmic.web.route) is not named.
  assert(#StandardMeant.of("cosmic.route", DOCS) == 0)
end
