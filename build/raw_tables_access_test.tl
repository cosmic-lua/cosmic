--- The typed accessors of [`build.raw_tables`]: what they hand back, and
--- each way they refuse a table the core did not hand the wrapper. The
--- wrappers asked are required, so that the store's searchers answer.
local RawTables = require("build.raw_tables")
local Test = require("cosmic.test")
local _child = require("cosmic.child")
local _hash = require("cosmic.hash")
local _net = require("cosmic.net")

Test.policy{}

--- The message `body` raises, or "" when it raises none.
local function refused(body: function()): string
  local ok, err = pcall(body)
  if ok then return "" end
  return tostring(err)
end

local function test_each_accessor_hands_the_table_of_its_wrapper_by_default()
  assert(type(RawTables.process().spawn) == "function")
  assert(type(RawTables.socket().listen) == "function")
  assert(type(RawTables.hash().digest) == "function")
end

local function test_the_table_is_the_core_s_own_and_not_a_copy()
  assert(rawequal(RawTables.process(), RawTables.process()))
  assert(rawequal(RawTables.process(), RawTables.fields("cosmic.child")))
  assert(rawequal(RawTables.socket("cosmic.net"), RawTables.socket()))
  assert(rawequal(RawTables.hash(), RawTables.fields("cosmic.hash")))
end

local function test_a_wrapper_with_no_raw_table_is_refused_saying_how_to_get_one()
  local why = refused(function() local _ = RawTables.process("cosmic.nothing_of_the_kind") end)
  assert(why:find("cosmic.nothing_of_the_kind is handed no raw table", 1, true) ~= nil, why)
  assert(why:find('local _ = require("cosmic.nothing_of_the_kind")', 1, true) ~= nil, why)
end

local function test_a_table_of_another_wrapper_is_refused_naming_the_member_it_lacks()
  local why = refused(function() local _ = RawTables.socket("cosmic.child") end)
  assert(why:find("cosmic.child is handed a raw table with no function `listen`", 1, true) ~= nil, why)
  why = refused(function() local _ = RawTables.process("cosmic.net") end)
  assert(why:find("cosmic.net is handed a raw table with no function `spawn`", 1, true) ~= nil, why)
  why = refused(function() local _ = RawTables.hash("cosmic.child") end)
  assert(why:find("cosmic.child is handed a raw table with no function `digest`", 1, true) ~= nil, why)
end

--- What a searcher in front of the store's hands the wrapper "test.offered" as its extra value, as `offer` makes it: a
--- chunk, since a searcher's extra value is untyped.
local function offered(offer: string, body: function())
  local chunk = assert(load("local searchers, adding = ... if adding then " ..
      "for i = #searchers, 1, -1 do searchers[i + 1] = searchers[i] end " ..
      "searchers[1] = function(asked) if asked == 'test.offered' then return function() end, " .. offer .. " end end " ..
      "else for i = 1, #searchers do searchers[i] = searchers[i + 1] end end", "=offer", "t", {}))
  chunk(package.searchers, true)
  local ok, err = pcall(body)
  chunk(package.searchers, false)
  assert(ok, tostring(err))
end

local function test_a_table_with_a_key_that_is_no_name_is_refused()
  offered("{ 10, 20 }", function()
    local why = refused(function() local _ = RawTables.fields("test.offered") end)
    assert(why:find("test.offered is handed a raw table that is no table of the core's", 1, true) ~= nil, why)
  end)
end

local function test_an_extra_value_that_is_no_table_is_no_raw_table()
  offered("'a string'", function()
    local why = refused(function() local _ = RawTables.fields("test.offered") end)
    assert(why:find("test.offered is handed no raw table", 1, true) ~= nil, why)
  end)
end

local function test_a_table_of_named_members_is_handed_back_for_reflection()
  assert(type(RawTables.fields("cosmic.child")["spawn"]) == "function")
  offered("{ answer = 42 }", function()
    assert(RawTables.fields("test.offered")["answer"] == 42)
  end)
end
