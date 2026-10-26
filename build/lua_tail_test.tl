--- The tests of [`build.lua_tail`]: the tail a test module's Lua gets and the bytecode of any module's, whichever compiler wrote it.
local LuaTail = require("build.lua_tail")
local Test = require("cosmic.test")

Test.policy{}

local function test_a_test_module_hands_its_tests_back_on_the_table_require_gives()
  local code = LuaTail.with_test_tail("local function test_a() return 1 end\nlocal function test_b() return 2 end\n",
    { "test_a", "test_b" })
  assert(code:sub(-#"\nreturn { test_a = test_a, test_b = test_b }\n") == "\nreturn { test_a = test_a, test_b = test_b }\n", code)
  local loaded = assert(load(code, "=tail", "t"))() as {string: function(): integer}
  assert(loaded.test_a() == 1 and loaded.test_b() == 2)
end

local function test_a_module_with_no_tests_is_left_as_it_is()
  assert(LuaTail.with_test_tail("return 1\n", {}) == "return 1\n")
end

local function test_bytecode_is_the_dump_of_the_chunk_and_loads_back_as_it()
  local bytecode = assert(LuaTail.bytecode_of("return 6 * 7\n", "answer", "answer.tl"))
  assert(bytecode:sub(1, 4) == "\27Lua" and #bytecode > 20)
  local chunk = assert(load(bytecode, "=answer", "b", {}))
  assert(chunk() == 42)
end

local function test_a_chunk_lua_refuses_is_said_at_the_line_of_the_source_it_came_from()
  local bytecode, why = LuaTail.bytecode_of("local a = 1\nlocal b = = 2\n", "broken", "dir/broken.tl")
  assert(bytecode == nil and why:find("^dir/broken%.tl:2: ") ~= nil, tostring(why))
end
