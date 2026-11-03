--- A test that type-checks a snippet against the standard library, under the pure store
--- (the sandboxed default, [`build.closure_store`]'s `write`): the store keeps the text the checker
--- reads of the modules the test requires itself, and of those it follows to type them, so the checker
--- answers as it does from the whole store, while it withholds the text of every other module.

local Store = require("cosmic.store")
local standalone = require("build.standalone")
-- The modules the snippets require, named as [`cosmic.test`] documents: by `local type`.
local type _fs = require("cosmic.fs")
local type _zip = require("cosmic.zip")

--- [`standalone.compile`] with its cache in the test's own directory.
local function compile(tmp: string, source: string): standalone.Main?, string
  return standalone.compile("x.tl", source, { XDG_CACHE_HOME = tmp .. "/cache" })
end

--- This is the pure store: the source of [`cosmic.stream`], which the test does not name and [`cosmic.zip`] requires, is
--- withheld, where the full closure store would hold it.
local function test_the_store_is_the_pure_one()
  assert(Store.withheld("cosmic.stream") ~= nil, "the source of a module the test does not name is not withheld")
end

local function test_a_snippet_that_requires_a_module_the_test_requires_is_typed(tmp: string)
  local chunk, trouble = compile(tmp, [[
local Fs = require("cosmic.fs")
return function(argv: {string}): integer
  local text = Fs.read("/nonexistent")
  return #argv + (if text == nil then 1 else 0 end)
end
]])
  assert(chunk ~= nil, trouble)
end

--- The checker types [`cosmic.zip`] from its text, and through it what it requires ([`cosmic.stream`], [`cosmic.fs`]),
--- which the test does not require itself.
local function test_a_snippet_is_typed_through_the_modules_the_one_it_requires_follows(tmp: string)
  local chunk, trouble = compile(tmp, [[
local Zip = require("cosmic.zip")
return function(argv: {string}): integer
  local _ = Zip
  return #argv
end
]])
  assert(chunk ~= nil, trouble)
end

--- What the checker refuses of a snippet is what the whole store makes it say: the type of [`Fs.read`] is known.
local function test_the_checker_refuses_a_wrong_use_of_a_required_module_in_its_words(tmp: string)
  local chunk, trouble = compile(tmp, [[
local Fs = require("cosmic.fs")
return function(argv: {string}): integer
  local size: integer = Fs.read("/nonexistent")
  return #argv + size
end
]])
  assert(chunk == nil and trouble:find("(not_assignable)", 1, true) ~= nil, trouble)
end
