--- The tests of [`build.lua_tail`]: the tail a test module's Lua gets and the bytecode of any module's, whichever compiler wrote it.
local LuaTail = require("build.lua_tail")
local Hits = require("build.coverage_hits")
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

--- A module with `lead` above it: a function that takes one branch of two, and a chunk that calls it.
local function branching(lead: string): string
  return lead .. table.concat({
    "local function count(x, flag)",
    "  if flag then",
    "    x = x + 1",
    "  else",
    "    x = x - 1",
    "  end",
    "  return x",
    "end",
    "return count(0, true)",
  }, "\n") .. "\n"
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
--- sits, as a stripped one is, runs as the chunk does, and says no position in what it raises. The core counts
--- each instruction of it that runs (core/coverage.c, under the window build.test has open around this test) at
--- its ordinal, past the base, which the chunk compiled from either text places at that text's own lines: the
--- branch it took is reached, and the one it did not is not.
local function test_a_numbered_chunk_moves_with_no_text_and_its_instructions_are_counted_by_each_text()
  local plain_source = branching("")
  local noted_source = branching("-- a note\n\n\n-- another\n")
  local plain = assert(LuaTail.bytecode_of(plain_source, "lua_tail_numbered_probe", "probe.tl"))
  local noted = assert(LuaTail.bytecode_of(noted_source, "lua_tail_numbered_probe", "probe.tl"))
  assert(plain ~= noted, "the chunks differ in no line, so this shows nothing")
  local numbered = assert(LuaTail.numbered(plain, "lua_tail_numbered_probe"))
  assert(numbered == assert(LuaTail.numbered(noted, "lua_tail_numbered_probe")),
    "a comment and blank lines moved the numbered chunk")
  local changed = (branching(""):gsub("x %+ 1", "x + 2"))
  assert(numbered ~= assert(LuaTail.numbered(assert(LuaTail.bytecode_of(changed, "lua_tail_numbered_probe",
    "probe.tl")), "lua_tail_numbered_probe")), "a constant did not move the numbered chunk")
  local chunk = assert(load(numbered, "=lua_tail_numbered_probe", "b", {}))
  local ok, ran = pcall(function(): any return chunk() end)
  assert(ok and ran == 1, "the numbered chunk does not run as the chunk does: " .. tostring(ran))
  local failing = assert(load(assert(LuaTail.numbered(assert(LuaTail.bytecode_of("local x = 1\nreturn x.field\n",
    "lua_tail_numbered_failing", "failing.tl")), "lua_tail_numbered_failing")), "=lua_tail_numbered_failing", "b", {}))
  local raised, why = pcall(function() failing() end)
  assert(not raised and tostring(why):find("%d%d%d%d%d") == nil, "a numbered chunk said a position: " .. tostring(why))
  local counted = assert(Hits.snapshot()["lua_tail_numbered_probe"], "no instruction of the numbered chunk was counted")
  for bytecode, source in pairs({ [plain] = plain_source, [noted] = noted_source }) do
    local lines = assert(LuaTail.instruction_lines(bytecode, "lua_tail_numbered_probe"))
    local reached: mut {integer:boolean} = {}
    for line in pairs(counted) do
      assert(line > LuaTail.ordinal_base, "a numbered instruction was counted on a line of no ordinal")
      reached[assert(lines[line - LuaTail.ordinal_base], "an ordinal past the chunk's instructions")] = true
    end
    assert(reached[line_of(source, "    x = x + 1")] == true, "the branch taken is not reached")
    assert(reached[line_of(source, "  return x")] == true, "the function's return is not reached")
    assert(reached[line_of(source, "    x = x - 1")] == nil, "the branch not taken is reached")
  end
end

--- A finalizer runs with hooks held off (lgc.c's GCTM), so the line hook counts no line of its body, and nor does
--- the core in a numbered chunk: its body is reached in neither, while the code that made and collected the value is.
local function test_a_finalizer_of_a_numbered_chunk_is_counted_as_the_text_is()
  local source = table.concat({
    "local setmetatable, collectgarbage = ...",
    "local seen = 0",
    "local function make()",
    "  return setmetatable({}, { __gc = function()",
    "    seen = seen + 1",
    "  end })",
    "end",
    "make()",
    "collectgarbage()",
    "collectgarbage()",
    "return seen",
  }, "\n") .. "\n"
  -- What the chunk calls, handed to it, so it runs in an environment of its own.
  local metatables = assert(load("return setmetatable", "=lua_tail_finalizer_library", "t"))
  local function collect() collectgarbage("collect") end
  local function ran(chunk: function(...: any): any...): integer
    local ok, seen = pcall(function(): any return chunk(metatables(), collect) end)
    assert(ok, tostring(seen))
    return math.tointeger(seen) or 0
  end
  local text = assert(load(source, "@lua_tail_finalizer_text", "t", {}))
  local numbered_code = assert(LuaTail.numbered(assert(LuaTail.bytecode_of(source, "lua_tail_finalizer_numbered",
    "finalizer.tl")), "lua_tail_finalizer_numbered"))
  local numbered = assert(load(numbered_code, "=lua_tail_finalizer_numbered", "b", {}))
  -- Twice each, so the second finds the source and its page held, and could count them without the hook.
  assert(ran(text) >= 1 and ran(text) >= 1, "the finalizer did not run, so this shows nothing")
  assert(ran(numbered) >= 1 and ran(numbered) >= 1, "the finalizer did not run, so this shows nothing")
  local hits = Hits.snapshot()
  local by_text = assert(hits["lua_tail_finalizer_text"], "the text's lines were not counted")
  assert(by_text[8] == true and by_text[5] == nil, "the line hook counted a finalizer's body, so this shows nothing")
  local counted = assert(hits["lua_tail_finalizer_numbered"], "the numbered chunk's instructions were not counted")
  local lines = assert(LuaTail.instruction_lines(assert(LuaTail.bytecode_of(source, "lua_tail_finalizer_numbered",
    "finalizer.tl")), "lua_tail_finalizer_numbered"))
  local reached: mut {integer:boolean} = {}
  for line in pairs(counted) do
    reached[assert(lines[line - LuaTail.ordinal_base], "an ordinal past the chunk's instructions")] = true
  end
  assert(reached[8] == true, "the call that made the value was not reached")
  assert(reached[5] == nil, "the finalizer's body was counted, which the line hook of the text does not count")
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
