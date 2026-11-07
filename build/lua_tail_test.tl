--- The tests of [`build.lua_tail`]: the tail a test module's Lua gets and the bytecode of any module's, whichever compiler wrote it.
local LuaTail = require("build.lua_tail")
local Test = require("cosmic.test")

Test.policy{}

local function test_a_test_module_hands_its_tests_back_on_the_table_require_gives()
  local code = LuaTail.with_test_tail("local function test_a() return 1 end\nlocal function test_b() return 2 end\n",
    { "test_a", "test_b" })
  assert(code:sub(-#"\nreturn { test_a = test_a, test_b = test_b }\n") == "\nreturn { test_a = test_a, test_b = test_b }\n", code)
  local loaded = assert(load(code, "=tail", "t"))() as {string: function(): integer} -- checked: cast_refused
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

--- Stripped, a chunk is the same for two sources that differ in a comment, a blank line, a local's
--- name or where a statement sits; one that differs in what it does is not.
local function test_stripped_bytecode_ignores_what_the_core_does_not_run()
  local function stripped(source: string): string
    local compiled = assert(LuaTail.bytecode_of(source, "m", "m.tl"))
    return (assert(LuaTail.stripped(compiled, "m")))
  end
  local plain = stripped("local x = 1\nreturn x\n")
  assert(plain == stripped("-- a comment\n\n\nlocal  x = 1 -- another\nreturn x\n"), "a comment moved it")
  assert(plain == stripped("local renamed = 1\nreturn renamed\n"), "a local's name moved it")
  assert(plain ~= stripped("local x = 2\nreturn x\n"), "a constant did not move it")
  assert(plain ~= stripped("local x = 1\nreturn x, x\n"), "an instruction did not move it")
  -- Nor does where a function is defined, which `string.dump` keeps of a stripped chunk: its line, and
  -- the padding the code that follows needs.
  local function defined(lead: string): string
    return stripped(lead .. "local function f(a) return a + 1 end\nreturn function(b) return f(b) end\n")
  end
  assert(defined("") == defined("\n\n-- note\n"), "a function that moved down the file moved it")
  assert(defined("") == defined(string.rep("\n", 300)), "a function that moved a long way moved it")
  assert(load(defined("\n\n"), "=m", "b", {}) ~= nil, "it is no chunk Lua loads")
  assert(defined("") ~= stripped("local function f(a) return a + 2 end\nreturn function(b) return f(b) end\n"))
  -- Which the unstripped chunks differ in, or the cases above show nothing.
  assert(LuaTail.bytecode_of("local x = 1\nreturn x\n", "m", "m.tl") ~=
      LuaTail.bytecode_of("\n\nlocal x = 1\nreturn x\n", "m", "m.tl"))
  local refused, why = LuaTail.stripped("not a chunk", "m")
  assert(refused == nil and why:find("m", 1, true) ~= nil, tostring(why))
end

--- The module `m` with `lead` above it: a function of more instructions than Lua places between two absolute
--- lines, which fails on its last line, and a chunk that calls it.
local function raising(lead: string): string
  local body: mut {string} = { lead, "local function count(x)" }
  for _ = 1, 150 do body[#body + 1] = "  x = x + 1" end
  body[#body + 1] = "  return x.field"
  body[#body + 1] = "end"
  body[#body + 1] = "return count(0)"
  return table.concat(body, "\n") .. "\n"
end

--- The line of `source` the statement `statement` is on.
local function line_of(source: string, statement: string): integer
  local line = 0
  for text in (source .. "\n"):gmatch("([^\n]*)\n") do
    line = line + 1
    if text == statement then return line end
  end
  error("no line is " .. statement)
end

--- Numbered, a chunk is the same for two sources that differ in a comment, a blank line or where a function
--- sits, as a stripped one is, and runs as the chunk does; a line Lua reports of it is an instruction's ordinal,
--- past the base, which the chunk compiled from either text places at that text's own line.
local function test_a_numbered_chunk_moves_with_no_text_and_its_lines_are_placed_by_each_text()
  local plain_source = raising("")
  local noted_source = raising("-- a note\n\n\n-- another")
  local plain = assert(LuaTail.bytecode_of(plain_source, "m", "m.tl"))
  local noted = assert(LuaTail.bytecode_of(noted_source, "m", "m.tl"))
  assert(plain ~= noted, "the chunks differ in no line, so this shows nothing")
  local numbered = assert(LuaTail.numbered(plain, "m"))
  assert(numbered == assert(LuaTail.numbered(noted, "m")), "a comment and blank lines moved the numbered chunk")
  local banged = (raising(""):gsub("x %+ 1", "x + 2"))
  assert(numbered ~= assert(LuaTail.numbered(assert(LuaTail.bytecode_of(banged, "m", "m.tl")), "m")),
    "a constant did not move the numbered chunk")
  local chunk = assert(load(numbered, "=m", "b", {}))
  local ok, why = pcall(function() chunk() end)
  assert(not ok, "the chunk did not raise")
  assert(tostring(why):match(": attempt to index a number value") ~= nil, tostring(why))
  local reported = assert(math.tointeger(tonumber(tostring(why):match("^m:(%d+): "))), tostring(why))
  assert(reported > LuaTail.ordinal_base, "the line Lua reports is no instruction's ordinal: " .. tostring(why))
  for bytecode, source in pairs({ [plain] = plain_source, [noted] = noted_source }) do
    local lines = assert(LuaTail.instruction_lines(bytecode, "m"))
    assert(lines[reported - LuaTail.ordinal_base] == line_of(source, "  return x.field"),
      "the ordinal Lua reported is not placed at the line that raised")
  end
end

--- The source line of each instruction, in a numbered chunk's order: the chunk's own, then those of each function
--- it defines, and the line each such function is defined on; a line no statement is on holds none, and a chunk
--- with no line information is refused.
local function test_each_instruction_is_placed_at_the_line_of_its_statement()
  local source = "local x = 1\n\nlocal function f()\n  return x\nend\nreturn f()\n"
  local bytecode = assert(LuaTail.bytecode_of(source, "m", "m.tl"))
  local lines = assert(LuaTail.instruction_lines(bytecode, "m"))
  local seen: mut {integer:boolean} = {}
  for _, line in ipairs(lines) do seen[line] = true end
  assert(seen[1] == true and seen[4] == true and seen[6] == true,
    "a statement's line holds no instruction: " .. table.concat(lines, ","))
  assert(seen[2] == nil, "a blank line holds an instruction")
  -- `f`'s own: its `return` and the `end` it closes on, after the chunk's.
  assert(lines[#lines - 2] == 4 and lines[#lines] == 5 and lines[1] == 1,
    "the instructions of a function the chunk defines are not after the chunk's: " .. table.concat(lines, ","))
  -- `f` is defined on line 3, and its instructions follow the chunk's own, which end on its last line.
  local defines = assert(LuaTail.defined_lines(bytecode, "m"))
  local before, defined_on = next(defines)
  assert(defined_on == 3 and next(defines, before) == nil and before ~= nil and lines[before] == 6 and
      lines[before + 1] == 4, "f is not defined on its line, after the chunk's instructions")
  -- A numbered chunk says `f` is defined on the line of that count, which is what a traceback names it by.
  local numbered_defines = assert(LuaTail.defined_lines(assert(LuaTail.numbered(bytecode, "m")), "m"))
  assert(numbered_defines[before] == LuaTail.ordinal_base + before)
  local refused, why = LuaTail.instruction_lines(assert(LuaTail.stripped(bytecode, "m")), "m")
  assert(refused == nil and why:find("m", 1, true) ~= nil, tostring(why))
end
