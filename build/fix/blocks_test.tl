--- [`build.fix.blocks`] over tiny sources: the level of each token, and the token a comment before a closer is
--- measured by.
local Blocks = require("build.fix.blocks")
local Lexer = require("lang.lexer")
local Parser = require("lang.parser")
local Test = require("cosmic.test")

Test.policy{}

--- The tokens of `source` as one line, each as `text` followed by its level, and for a closer `^` and the index of
--- its anchor.
local function levels_of(source: string): string
  local lexed = Lexer.lex(source, "f.tl")
  local parsed = Parser.parse(lexed, "f.tl", "tl")
  for _, err in ipairs(parsed.errors) do
    error(source .. ": " .. err.msg)
  end
  local levels = Blocks.of(parsed.chunk)
  local out: mut {string} = {}
  for i = 1, Lexer.count(lexed.tokens) - 1 do
    local anchor = levels.anchors[i]
    out[#out + 1] = Lexer.text(lexed.tokens, i) .. tostring(levels.depths[i] or -1) ..
      (if anchor == nil then "" else "^" .. tostring(anchor) end)
  end
  return table.concat(out, " ")
end

local function test_a_body_is_a_level_in_and_its_closer_is_level_with_the_construct()
  local got = levels_of("if a then b() elseif c then d() else e() end")
  assert(got == "if0 a0 then0 b1 (1 )1 elseif0^4 c0 then0 d1 (1 )1 else0^10 e1 (1 )1 end0^14", got)
end

local function test_the_statements_of_a_chunk_are_at_level_zero()
  local got = levels_of("x = 1\ny = 2")
  assert(got == "x0 =0 10 y0 =0 20", got)
end

local function test_bodies_nest()
  local got = levels_of("do while a do x() end end")
  assert(got == "do0 while1 a1 do1 x2 (2 )2 end1^5 end0^2", got)
end

local function test_a_repeat_is_closed_by_its_until_and_the_condition_is_level_with_it()
  local got = levels_of("repeat x() until y")
  assert(got == "repeat0 x1 (1 )1 until0^2 y0", got)
end

local function test_a_function_written_in_an_expression_opens_a_body()
  local got = levels_of("f(function() return 1 end)")
  assert(got == "f0 (0 function0 (0 )0 return1 11 end0^6 )0", got)
end

local function test_the_arms_of_a_match_are_level_with_it()
  local got = levels_of("match f() do\n| (true) then x()\n| (false) then end")
  assert(got == "match0 f0 (0 )0 do0 |0 (0 true0 )0 then0 x1 (1 )1 |0^11 (0 false0 )0 then0 end0^18", got)
end

local function test_the_members_of_a_declaration_are_a_level_in()
  local got = levels_of("local record R x: integer record I y: integer end end")
  assert(got == "local0 record0 R0 x1 :1 integer1 record1 I1 y2 :2 integer2 end1^9 end0^7", got)
  got = levels_of("local enum E \"a\" end")
  assert(got == "local0 enum0 E0 \"a\"1 end0^4", got)
end

local function test_a_method_of_a_class_has_its_body_a_level_further()
  local got = levels_of("local class C function m(self) return 1 end end")
  assert(got == "local0 class0 C0 function1 m1 (1 self1 )1 return2 12 end1^9 end0^4", got)
end

local function test_a_body_with_nothing_in_it_is_measured_by_the_token_that_opened_it()
  local got = levels_of("if a then end")
  assert(got == "if0 a0 then0 end0^3", got)
  got = levels_of("local record R end")
  assert(got == "local0 record0 R0 end0^3", got)
end

local function test_a_chunk_without_a_statement_has_the_anchor_zero()
  local lexed = Lexer.lex("-- c\n", "f.tl")
  local levels = Blocks.of(Parser.parse(lexed, "f.tl", "tl").chunk)
  assert(levels.anchors[1] == 0, tostring(levels.anchors[1]))
  assert(levels.depths[1] == 0)
end
