--- Tests of [`build.main_locals`]: the locals of the Lua the generator writes are counted by probing it, so each choice of
--- the generator (a class table, an import read as a value, a `<const>` folded) is in the count by construction.
local Grammar = require("build.compile_grammar")
local LuaTail = require("build.lua_tail")
local MainLocals = require("build.main_locals")
local Test = require("cosmic.test")

Test.policy{}

local function source(...: string): string
  return table.concat({ ... }, "\n") .. "\n"
end

--- The Lua the generator writes for the module `main` of `text`, beside the module `other` of `others`.
local function lua_of(text: string, others?: string): string
  local files: mut {Grammar.Source} = {}
  if others ~= nil then
    files[1] = { path = "other.tl", relative = "other.tl", text = others, declaration = false }
  end
  files[#files + 1] = { path = "main.tl", relative = "main.tl", text = text, declaration = false }
  local compiled = Grammar.compile(files)
  local made = assert(compiled[#compiled])
  local code = made.code
  assert(code ~= nil, made.trouble)
  return code
end

--- The locals the main chunk of `text` holds.
local function held(text: string, others?: string): integer
  return assert(MainLocals.over(lua_of(text, others), 0))
end

local function test_every_name_and_function_counts()
  assert(held(source("local a, b = 1, 2", "local c: integer? = nil", "local function d() end", "return { a, b, c, d }")) == 4)
end

local function test_a_const_is_counted_only_where_lua_gives_it_a_register()
  assert(held(source("local N <const> = 6", "local S <const> = \"s\"", "local T <const> = { 1 }",
    "local F <const> = 1.5", "local u = 1", "return { N, S, T, F, u }")) == 2)
end

local function test_a_class_is_a_local_whether_its_methods_are_inside_or_outside_it()
  assert(held(source("local class Box", "  size: integer", "  function grow(self)", "    self.size = self.size + 1", "  end",
    "end", "return Box")) == 1)
  assert(held(source("local class Empty", "end", "return Empty")) == 1)
  assert(held(source("local class Plain", "  size: integer", "end", "function Plain.make(): Plain", "  return { size = 0 }",
    "end", "return Plain")) == 1)
end

local function test_a_record_and_a_type_are_a_local_only_where_the_generator_writes_one()
  assert(held(source("local record Shape", "  x: integer", "end", "local type Alias = Shape", "local s: Alias = { x = 1 }",
    "return s")) == 1)
  assert(held(source("local record Table", "end", "function Table.f() end", "return Table")) == 1)
end

local function test_an_import_is_a_local_where_it_is_read_as_a_value()
  local other = source("local record Other", "  x: integer", "end", "function Other.x(): integer return 1 end",
    "return Other")
  assert(held(source("local type Other = require(\"other\")", "local o: Other = { x = 1 }", "return o"), other) == 1)
  assert(held(source("local Other = require(\"other\")", "return Other.x()"), other) == 1)
  assert(held(source("local type Other = require(\"other\")", "return Other.x()"), other) == 1)
end

local function test_a_local_in_a_body_or_a_block_is_not_one_of_the_chunks_unless_it_is_open_with_them()
  assert(held(source("local function f()", "  local inner = 1", "  return inner", "end", "return f")) == 1)
  -- A block's locals are held while it runs, so the most the chunk holds at once counts them.
  assert(held(source("local a = 1", "do", "  local b, c = 2, 3", "  a = a + b + c", "end", "return a")) == 3)
end

local function test_a_chunk_that_does_not_compile_has_no_count()
  assert(MainLocals.over("local x =", 0) == nil)
  assert(MainLocals.over("local x =", 10) == nil)
end

--- A chunk of `names` locals in lines of `per` names each.
local function wide(names: integer, per: integer): string
  local lines: mut {string} = {}
  local index = 0
  while index < names do
    local line: mut {string} = {}
    for _ = 1, per do
      index = index + 1
      line[#line + 1] = "v" .. tostring(index)
    end
    lines[#lines + 1] = "local " .. table.concat(line, ", ") .. " = " .. table.concat(line, ", ")
  end
  return table.concat(lines, "\n") .. "\n"
end

local function test_names_are_counted_however_many_stand_in_a_line()
  -- Few lines, many names: a count of lines that start a `local` would not see these.
  assert(MainLocals.over(wide(150, 30), 0) == 150)
  assert(MainLocals.over(wide(150, 30), 100) == 150)
  assert(MainLocals.over(wide(100, 25), 100) == nil)
  assert(MainLocals.over(wide(101, 1), 100) == 101)
  assert(MainLocals.over(wide(200, 50), 0) == 200)
  assert(MainLocals.over(wide(201, 50), 0) == nil)
end

local function test_a_refusal_for_registers_is_no_count_of_locals()
  local arguments: mut {string} = {}
  for index = 1, 175 do
    arguments[#arguments + 1] = tostring(index)
  end
  -- 60 locals and a call of 175 arguments compile, but not with 20 more locals in front: the registers run out first.
  local lua = wide(60, 20) .. "return f(" .. table.concat(arguments, ", ") .. ")\n"
  local fits, _ = LuaTail.fits_with(lua, 0)
  local spare, why = LuaTail.fits_with(lua, 20)
  assert(fits and not spare and why:find("too many local variables", 1, true) == nil, why)
  -- Under a limit of 100, 100 more locals in front leave the call no registers: not a count of locals, so nothing is told.
  assert(MainLocals.over(lua, 100) == nil)
  assert(MainLocals.over(wide(60, 20), 50) == 60)
end
