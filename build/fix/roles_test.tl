--- [`build.fix.roles`] over tiny sources: the part each token plays, read from the tree and not from its
--- neighbours, and the regions that hold a type's tokens.
local Lexer = require("lang.lexer")
local Parser = require("lang.parser")
local Roles = require("build.fix.roles")

--- The tokens of `source` as one line, each as `text=role`, or `text=role@region` for a token in a type.
local function roles_of(source: string): string
  local lexed = Lexer.lex(source, "f.tl")
  local parsed = Parser.parse(lexed, "f.tl", "tl")
  for _, err in ipairs(parsed.errors) do
    error(source .. ": " .. err.msg)
  end
  local roled = Roles.of(parsed.chunk)
  local out: mut {string} = {}
  for i = 1, Lexer.count(lexed.tokens) - 1 do
    local region = Roles.region(roled, i)
    out[#out + 1] = Lexer.text(lexed.tokens, i) .. "=" .. Roles.role(roled, i) ..
      (if region == 0 then "" else "@" .. tostring(region) end)
  end
  return table.concat(out, " ")
end

local function test_a_minus_is_binary_or_unary_by_its_place_in_the_tree()
  assert(roles_of("x = a - -b") == "x=word ==word a=word -=word -=unary b=word", roles_of("x = a - -b"))
  assert(roles_of("x = not b") == "x=word ==word not=word b=word", "not keeps its space")
end

local function test_a_paren_is_a_call_a_group_or_a_pattern_by_its_place_in_the_tree()
  assert(roles_of("x = f((a))") ==
      "x=word ==word f=word (=call_open (=group_open a=word )=paren_close )=paren_close", roles_of("x = f((a))"))
  assert(roles_of("match f() do | (true, v) then end") ==
      "match=word f=word (=call_open )=paren_close do=word |=word (=group_open true=word ,=comma v=word " ..
      ")=paren_close then=word end=word", roles_of("match f() do | (true, v) then end"))
end

local function test_a_colon_is_a_method_call_or_a_declaration_by_its_place_in_the_tree()
  assert(roles_of("local a: T = t:m()") ==
      "local=word a=word :=colon T=word@4 ==word t=word :=method_colon m=word (=call_open )=paren_close",
    roles_of("local a: T = t:m()"))
end

local function test_a_bracket_is_an_index_a_key_or_wide_by_what_it_holds()
  assert(roles_of("x = t[1] + {[2] = 3, [ [[k]] ] = 4}") ==
      "x=word ==word t=word [=index_open 1=word ]=index_close +=word {=table_open [=key_open 2=word ]=key_close " ..
      "==word 3=word ,=comma [=word [[k]]=word ]=word ==word 4=word }=table_close",
    roles_of("x = t[1] + {[2] = 3, [ [[k]] ] = 4}"))
  assert(roles_of("x = t[ [[a]] ]") == "x=word ==word t=word [=wide_open [[a]]=word ]=word", "an index of a long string")
end

local function test_an_empty_table_and_a_table_with_entries_have_different_braces()
  assert(roles_of("x = {{}}") == "x=word ==word {=table_open {=empty_open }=empty_close }=table_close",
    roles_of("x = {{}}"))
end

local function test_the_angle_brackets_of_an_attribute_and_of_type_parameters_are_not_comparisons()
  assert(roles_of("local a <const> = 1 < 2") ==
      "local=word a=word <=attr_open const=word >=attr_close ==word 1=word <=word 2=word", roles_of("local a <const> = 1 < 2"))
  assert(roles_of("local function f<T>(a: T) end") ==
      "local=word function=word f=word <=angle_open T=word >=angle_close (=call_open a=word :=colon T=word@10 " ..
      ")=paren_close end=word", roles_of("local function f<T>(a: T) end"))
end

local function test_the_tokens_of_a_type_form_one_region_named_by_its_first_token()
  assert(roles_of("local m: {string: R<K>} = x as function(a: integer): string") ==
      "local=word m=word :=colon {=word@4 string=word@4 :=word@4 R=word@4 <=word@4 K=word@4 >=word@4 }=word@4 " ..
      "==word x=word as=word function=word@15 (=word@15 a=word@15 :=word@15 integer=word@15 )=word@15 " ..
      ":=word@15 string=word@15", roles_of("local m: {string: R<K>} = x as function(a: integer): string"))
end

local function test_a_field_of_a_class_has_its_question_mark_and_bracketed_name_roled()
  assert(roles_of("local record R\n  a?: T\n  [\"b c\"]: U\nend") ==
      "local=word record=word R=word a=word@4 ?=word@4 :=word@4 T=word@4 [=word@4 \"b c\"=word@4 ]=word@4 " ..
      ":=word@4 U=word@4 end=word", roles_of("local record R\n  a?: T\n  [\"b c\"]: U\nend"))
  -- A class holds code, and its fields are roled one by one.
  assert(roles_of("local class C\n  a?: T\n  [\"b c\"]: U\nend") ==
      "local=word class=word C=word a=word ?=question :=colon T=word@7 [=key_open \"b c\"=word ]=key_close " ..
      ":=colon U=word@12 end=word", roles_of("local class C\n  a?: T\n  [\"b c\"]: U\nend"))
end

local function test_the_parentheses_of_a_parenthesized_type_are_in_its_region()
  assert(roles_of("x = f(a as (T | U))") ==
      "x=word ==word f=word (=call_open a=word as=word (=word@7 T=word@7 |=word@7 U=word@7 )=word@7 )=paren_close",
    roles_of("x = f(a as (T | U))"))
end
