--- Programs in the new checker's grammar, for the tests of the `__fact` hook of the test worker
--- ([`build.fact_hook_test`], [`build.fact_hook_tool_test`]): each is compiled by [`build.compile_grammar`] with the
--- wraps of [`lang.fact_wraps`], and the Lua is run where the hook is defined.
---
--- A SOUND program narrows places and reads them as the narrowing says. An UNSOUND one is accepted by the checker and
--- is wrong at run time in one place, which a test plants and the hook must find: `assert` that does not raise, and a
--- function that writes a field the checker took to be fixed behind its back (a cast, in the host's Lua).
local Grammar = require("build.compile_grammar")

local record Programs
  --- Reads `x` after a test of it and answers `none` for nil.
  sound: string
  --- Narrows an enum, a class and a tag as well as nil: `paint`, `pet` and `area` read what their tests took the value to be,
  --- and `dog`, `cat`, `square` and `circle` make values for them. `area_after` and `pet_after` call a function between the
  --- test and the read, which can make the conclusion false (the class of a value, the tag of a record).
  shapes: string
  --- Reads `x` after `assert(x)`: unsound where `assert` does not raise. The read is at line 3, column 10 of `unsound_assert.tl`.
  unsound_assert: string
  --- Reads the fixed field `b.value` after a test of it and a call that may clear it: unsound where the call does. The
  --- read is at line 7, column 12 of `unsound_poke.tl`.
  unsound_poke: string
  --- The Lua of `text`, the module `name` (a file name ending `.tl`), with the wraps of the `__fact` hook where `facts`.
  --- Fails where the checker finds an error in it.
  compiled: function(name: string, text: string, facts: boolean): string
end

local DECLARATIONS <const> = [[
do
  local record Lib
    assert: function<A>(v: A?): A
    tostring: function(v: any): string
  end
  global assert <const> = Lib.assert
  global tostring <const> = Lib.tostring
end
]]

local SOUND <const> = table.concat({
  "local function read(x: string?): string",
  "  if x == nil then",
  "    return \"none\"",
  "  end",
  "  return x",
  "end",
  "local record Api",
  "  read: function(string?): string",
  "end",
  "local api: Api = { read = read }",
  "return api",
  "",
}, "\n")

local SHAPES <const> = table.concat({
  "local enum Color",
  "  \"red\"",
  "  \"green\"",
  "end",
  "local class Dog",
  "  name: string",
  "end",
  "local class Cat",
  "  lives: integer",
  "end",
  "local enum Square_kind \"square\" end",
  "local enum Circle_kind \"circle\" end",
  "local record Square",
  "  kind: Square_kind",
  "  side: integer",
  "end",
  "local record Circle",
  "  kind: Circle_kind",
  "  radius: integer",
  "end",
  "local function paint(c: Color | integer): string",
  "  if c is Color then",
  "    return c",
  "  end",
  "  return tostring(c)",
  "end",
  "local function pet(p: (Dog | Cat)?): string",
  "  if p is Dog then",
  "    return p.name",
  "  end",
  "  return \"other\"",
  "end",
  "local function area(s: Square | Circle): integer",
  "  if s.kind == \"square\" then",
  "    return s.side",
  "  end",
  "  return 0",
  "end",
  "local function area_after(s: Square | Circle, poke: function()): integer",
  "  if s.kind == \"square\" then",
  "    poke()",
  "    return s.side",
  "  end",
  "  return 0",
  "end",
  "local function pet_after(p: (Dog | Cat)?, poke: function()): string",
  "  if p is Dog then",
  "    poke()",
  "    return p.name",
  "  end",
  "  return \"other\"",
  "end",
  "local function dog(): Dog",
  "  local d: Dog = { name = \"rex\" }",
  "  return d",
  "end",
  "local function cat(): Cat",
  "  local c: Cat = { lives = 9 }",
  "  return c",
  "end",
  "local function square(): Square",
  "  local s: Square = { kind = \"square\", side = 4 }",
  "  return s",
  "end",
  "local function circle(): Circle",
  "  local c: Circle = { kind = \"circle\", radius = 2 }",
  "  return c",
  "end",
  "local function area_between(s: Square | Circle, poke: function()): integer",
  "  if s.kind == \"square\" then",
  "    local before = s.side",
  "    poke()",
  "    return before + s.side",
  "  end",
  "  return 0",
  "end",
  "local enum Ta_kind \"a\" end",
  "local enum Tb_kind \"b\" end",
  "local enum Tc_kind \"c\" end",
  "local record Ta",
  "  kind: Ta_kind",
  "end",
  "local record Tb",
  "  kind: Tb_kind",
  "end",
  "local record Tc",
  "  kind: Tc_kind",
  "end",
  "local record Tbox",
  "  s: Ta | Tb | Tc",
  "end",
  "local function tag_only(b: Tbox, poke: function()): string",
  "  if b.s.kind == \"a\" then return \"a\" end",
  "  poke()",
  "  local k = b.s.kind",
  "  if k == \"b\" then return \"b\" end",
  "  return k",
  "end",
  "local function all_return(x: Ta | Tb | Tc): integer",
  "  if x.kind == \"a\" then return 1 elseif x.kind == \"b\" then return 2 elseif x.kind == \"c\" then return 3 end",
  "end",
  "local function all_assign(x: Ta | Tb | Tc): integer",
  "  local r: integer",
  "  if x.kind == \"a\" then r = 1 elseif x.kind == \"b\" then r = 2 elseif x.kind == \"c\" then r = 3 end",
  "  return r",
  "end",
  "local record Api",
  "  paint: function(Color | integer): string",
  "  pet: function((Dog | Cat)?): string",
  "  area: function(Square | Circle): integer",
  "  area_after: function(Square | Circle, function()): integer",
  "  area_between: function(Square | Circle, function()): integer",
  "  tag_only: function(Tbox, function()): string",
  "  all_return: function(Ta | Tb | Tc): integer",
  "  all_assign: function(Ta | Tb | Tc): integer",
  "  pet_after: function((Dog | Cat)?, function()): string",
  "  dog: function(): Dog",
  "  cat: function(): Cat",
  "  square: function(): Square",
  "  circle: function(): Circle",
  "end",
  "local api: Api = { paint = paint, pet = pet, area = area, area_after = area_after, area_between = area_between, tag_only = tag_only, all_return = all_return, all_assign = all_assign, pet_after = pet_after, dog = dog, cat = cat, square = square, circle = circle }",
  "return api",
  "",
}, "\n")

local UNSOUND_ASSERT <const> = table.concat({
  "local function read(x: string?): string",
  "  assert(x)",
  "  return x",
  "end",
  "local record Api",
  "  read: function(string?): string",
  "end",
  "local api: Api = { read = read }",
  "return api",
  "",
}, "\n")

local UNSOUND_POKE <const> = table.concat({
  "local record Box",
  "  value: string?",
  "end",
  "local function read(b: Box, poke: function()): string",
  "  if b.value ~= nil then",
  "    poke()",
  "    return b.value",
  "  end",
  "  return \"none\"",
  "end",
  "local record Api",
  "  read: function(Box, function()): string",
  "end",
  "local api: Api = { read = read }",
  "return api",
  "",
}, "\n")

local function compiled(name: string, text: string, facts: boolean): string
  local made = Grammar.compile({
    { path = "globals.d.tl", relative = "globals.d.tl", text = DECLARATIONS, declaration = true },
    { path = name, relative = name, text = text, declaration = false },
  }, facts)
  local file = assert(made[2])
  local problems = ""
  for _, list in ipairs({ file.syntax_errors, file.type_errors }) do
    for _, each in ipairs(list) do
      problems = problems .. "\n" .. name .. ":" .. tostring(each.y) .. ":" .. tostring(each.x) .. ": " .. each.msg
    end
  end
  assert(problems == "", "the program does not compile:" .. problems)
  return (assert(file.code, file.trouble))
end

local programs: Programs = {
  sound = SOUND, shapes = SHAPES, unsound_assert = UNSOUND_ASSERT,
  unsound_poke = UNSOUND_POKE, compiled = compiled,
}

return programs
