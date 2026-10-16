--- The translator from Teal to the new checker's grammar ([`lang.translate`]):
--- one test for each row of the draft's table, written as the Teal in and
--- the text out, then what holds for every translation: the lines and
--- comments of a respelling stay where they were, a translation parses with
--- no error and translating it again changes nothing.
local Cover = require("lang.lexer_cover")
local Lexer = require("lang.lexer")
local Parser = require("lang.parser")
local Translate = require("lang.translate")

--- The lines joined, each ended by a line break.
local function lines(...: string): string
  return table.concat({ ... }, "\n") .. "\n"
end

--- The translation of `source`, held to parse with no error.
local function clean(source: string, name?: string): Translate.Result
  local result = Translate.translate(source, name or "t.tl")
  local first = result.errors[1]
  assert(first == nil, "error " .. (first and first.code or "") .. ": " .. (first and first.msg or "") ..
      " in\n" .. result.text)
  return result
end

--- Asserts that `source` translates to `want` with no error.
local function translates(source: string, want: string, name?: string)
  local got = clean(source, name).text
  assert(got == want, "wanted\n" .. want .. "but got\n" .. got)
end

-- T | nil

local function test_a_union_with_nil_is_an_optional()
  translates(lines(
    "local a: string | nil",
    "local b: nil | string",
    "local c: {string} | nil",
    "local d: {string: integer} | nil",
    "local e: Stream.Reader | nil",
    "local f: Cache<K, V> | nil",
    "local g: mut {string} | nil"), lines(
      "local a: string?",
      "local b: string?",
      "local c: {string}?",
      "local d: {string: integer}?",
      "local e: Stream.Reader?",
      "local f: Cache<K, V>?",
      "local g: mut {string}?"))
end

local function test_two_members_or_more_stay_in_parentheses()
  translates(lines(
    "local a: A | B | nil",
    "local b: nil | A | B",
    "local c: A | nil | B",
    "local d: A | B | C | nil"), lines(
      "local a: (A | B)?",
      "local b: (A | B)?",
      "local c: (A | B)?",
      "local d: (A | B | C)?"))
end

local function test_a_return_list_that_begins_with_a_parenthesized_optional_is_written_in_parentheses()
  -- `(A | B)?, string` would read `(A | B)` as the whole list.
  translates(lines(
    "local function f(): A | B | nil, string",
    "end",
    "local function g(): A | B | nil",
    "end",
    "local function h(): string, A | B | nil",
    "end",
    "local k: function(): nil | (function()), integer"), lines(
      "local function f(): ((A | B)?, string)",
      "end",
      "local function g(): (A | B)?",
      "end",
      "local function h(): string, (A | B)?",
      "end",
      "local k: function(): ((function())?, integer)"))
end

local function test_a_function_type_is_parenthesized_before_the_question_mark()
  translates(lines(
    "local a: (function(): R) | nil",
    "local b: function(x: A | nil): R | nil",
    "local c: {(function()) | nil}"), lines(
      "local a: (function(): R)?",
      "local b: function(x: A?): R?",
      "local c: {(function())?}"))
end

local function test_a_union_inside_a_union_or_a_type_argument_is_translated_too()
  translates(lines(
    "local a: {string: integer | nil} | nil",
    "local b: Cache<K, V | nil>",
    "local c: {A | nil}",
    "local d = x as string | nil"), lines(
      "local a: {string: integer?}?",
      "local b: Cache<K, V?>",
      "local c: {A?}",
      "local d = x as string?"))
end

local function test_unions_inside_a_member_close_before_the_union_around_them()
  translates(lines(
    "local a: nil | function(): nil | string",
    "local b: nil | string | function(): nil | integer"), lines(
      "local a: (function(): string?)?",
      "local b: (string | function(): integer?)?"))
end

local function test_an_optional_member_keeps_its_question_mark()
  translates("local a: A? | nil\n", "local a: A?\n")
  translates("local a: A? | B | nil\n", "local a: (A? | B)?\n")
end

local function test_a_union_over_several_lines_keeps_its_lines()
  translates(lines(
    "local m: A",
    "  | B",
    "  | nil",
    "local n = 1"), lines(
      "local m: (A",
      "  | B)?",
      "",
      "local n = 1"))
end

local function test_returns_and_parameters_and_fields_are_translated()
  translates(lines(
    "local function f(a: string | nil, b: integer): Reader | nil, string",
    "  return nil, \"\"",
    "end",
    "local record R",
    "  x: string | nil",
    "  g: function(R): integer | nil, string",
    "end"), lines(
      "local function f(a: string?, b: integer): Reader?, string",
      "  return nil, \"\"",
      "end",
      "local record R",
      "  x: string?",
      "  g: function(R): integer?, string",
      "end"))
end

-- T... and ? T

local function test_a_variadic_parameter_type_is_written_with_the_dots_first()
  translates(lines(
    "local a: function(string...): integer",
    "local b: function(x: integer, y: string...)",
    "local c: function(): string..."), lines(
      "local a: function(...: string): integer",
      "local b: function(x: integer, ...: string)",
      "local c: function(): string..."))
end

local function test_an_omittable_parameter_type_takes_a_name_from_its_place()
  translates("local a: function(? integer, string, ? boolean)\n", "local a: function(arg1?: integer, string, arg3?: boolean)\n")
end

-- goto continue

local function test_goto_continue_is_continue_and_the_label_is_blanked()
  translates(lines(
    "for i = 1, 3 do",
    "  if i == 2 then goto continue end",
    "  print(i)",
    "  ::continue::",
    "end"), lines(
      "for i = 1, 3 do",
      "  if i == 2 then continue end",
      "  print(i)",
      "",
      "end"))
end

local function test_continue_is_translated_in_each_kind_of_loop()
  translates(lines(
    "while a do",
    "  goto continue",
    "  ::continue::",
    "end",
    "for k, v in pairs(t) do",
    "  goto continue",
    "  ::continue::",
    "end",
    "repeat",
    "  goto continue",
    "  ::continue::",
    "until b"), lines(
      "while a do",
      "  continue",
      "",
      "end",
      "for k, v in pairs(t) do",
      "  continue",
      "",
      "end",
      "repeat",
      "  continue",
      "",
      "until b"))
end

local function test_a_goto_that_is_not_a_continue_is_left_to_be_refused()
  -- The jump leaves a nested function, or the loop it is in has no label: the
  -- translator writes no `continue` that would mean another jump.
  local result = Translate.translate(lines(
    "for i = 1, 3 do",
    "  local f = function()",
    "    goto continue",
    "  end",
    "  for j = 1, 2 do",
    "    goto continue",
    "  end",
    "  ::continue::",
    "end"), "t.tl")
  local codes: {string: integer} = {}
  for _, e in ipairs(result.errors) do
    codes[e.code] = (codes[e.code] or 0) + 1
  end
  assert(codes.label_or_goto == 3 and result.text:find("goto continue", 1, true), result.text)
  assert(result.text:find("::continue::", 1, true), "the label is left with the gotos that reach it")
end

-- the lexer's cut forms

local function test_a_semicolon_is_removed_and_a_table_separator_is_a_comma()
  translates(lines(
    "local a = 1; local b = 2;",
    ";",
    "local t = { x = 1; y = 2 }",
    "local u = { f = function() return 1; end; }"), lines(
      "local a = 1 local b = 2",
      "",
      "local t = { x = 1, y = 2 }",
      "local u = { f = function() return 1 end, }"))
end

local function test_a_long_comment_becomes_line_comments_on_the_same_lines()
  translates(lines(
    "--[[ one ]]",
    "local a = 1 --[[ two",
    "  three ]]",
    "  --[==[",
    "  four",
    "  ]==]",
    "local b = 2"), lines(
      "-- one",
      "local a = 1 -- two",
      "-- three",
      "  --",
      "  -- four",
      "  --",
      "local b = 2"))
end

local function test_a_long_comment_followed_by_code_is_left_to_be_refused()
  local result = Translate.translate("--[[ one ]] local a = 1\n", "t.tl")
  assert(result.text == "--[[ one ]] local a = 1\n" and result.errors[1].code == "long_comment")
end

local function test_digit_separators_and_hexadecimal_floats_are_written_plainly()
  translates("local a = 1_000_000 + 0xFF_FF + 1e1_0\n", "local a = 1000000 + 0xFFFF + 1e10\n")
  translates("local a = 0x1p4 + 0x.8 + 0x1.8p1\n", "local a = 16.0 + 0.5 + 3.0\n")
end

-- declarations

local function test_a_record_or_enum_declared_as_a_type_is_declared_with_its_word()
  translates(lines(
    "local type Point = record",
    "  x: number",
    "end",
    "local type Color = enum",
    "  \"red\"",
    "end",
    "local type Gen<T> = record",
    "  v: T",
    "end",
    "local type Shape = interface",
    "  area: function(self: Shape): number",
    "end"), lines(
      "local record Point",
      "  x: number",
      "end",
      "local enum Color",
      "  \"red\"",
      "end",
      "local record Gen<T>",
      "  v: T",
      "end",
      "local interface Shape",
      "  area: function(self: Shape): number",
      "end"))
end

local function test_an_alias_and_an_import_are_not_changed()
  local source = lines(
    "local type Key = string",
    "local type sqlite = require(\"cosmic.internal.sqlite\")",
    "local type Gen<T> = Types.Gen<T>")
  translates(source, source)
end

local function test_metamethod_close_is_a_field()
  translates(lines(
    "local record Guard",
    "  metamethod __close: function(Guard)",
    "  id: integer",
    "end"), lines(
      "local record Guard",
      "  __close: function(Guard)",
      "  id: integer",
      "end"))
  translates(lines(
    "local record hash",
    "  record Hasher",
    "    userdata",
    "    metamethod __close: function(Hasher, any)",
    "  end",
    "end",
    "return hash"), lines(
      "local record hash",
      "  record Hasher",
      "    userdata",
      "    __close: function(Hasher, any)",
      "  end",
      "end",
      "return hash"), "t.d.tl")
end

local function test_readonly_is_dropped()
  translates(lines(
    "local record R",
    "  readonly name: string",
    "  readonly [\"end\"]: string",
    "  readonly: boolean",
    "end"), lines(
      "local record R",
      "  name: string",
      "  [\"end\"]: string",
      "  readonly: boolean",
      "end"))
end

-- ternaries

local function test_a_ternary_with_a_middle_that_is_never_false_is_an_if_expression()
  translates(lines(
    "local a = n == 1 and \"item\" or \"items\"",
    "local b = x and 1 or 2",
    "local c = x and { 1 } or y",
    "local d = x and f .. \"z\" or w",
    "local e = x and #t + 1 or 0",
    "local f = x and function() end or nil",
    "local g = x and (y as string) or \"\"",
    "return c and 1 or 2"), lines(
      "local a = if n == 1 then \"item\" else \"items\" end",
      "local b = if x then 1 else 2 end",
      "local c = if x then { 1 } else y end",
      "local d = if x then f .. \"z\" else w end",
      "local e = if x then #t + 1 else 0 end",
      "local f = if x then function() end else nil end",
      "local g = if x then (y as string) else \"\" end",
      "return if c then 1 else 2 end"))
end

local function test_a_chain_of_ternaries_is_one_if_with_elseif()
  translates("local a = x and 1 or y and 2 or z and 3 or 4\n", "local a = if x then 1 elseif y then 2 elseif z then 3 else 4 end\n")
end

local function test_a_ternary_in_an_operand_or_an_argument_is_translated_in_place()
  translates(lines(
    "local a = (x and \"a\" or \"b\") .. (y and 2 + 1 or \"n\")",
    "f(x and 1 or 2, g(y and 3 or 4))",
    "local b = x and (y and 1 or 2) or 3"), lines(
      "local a = (if x then \"a\" else \"b\" end) .. (if y then 2 + 1 else \"n\" end)",
      "f(if x then 1 else 2 end, g(if y then 3 else 4 end))",
      "local b = x and (if y then 1 else 2 end) or 3"))
end

local function test_a_ternary_over_several_lines_keeps_its_lines()
  translates(lines(
    "local j = x",
    "  and \"a\"",
    "  or \"b\""), lines(
      "local j = if x",
      "  then \"a\"",
      "  else \"b\" end"))
end

local function test_a_ternary_whose_middle_needs_its_type_stays()
  -- `y` may be false or nil, so `c and y or z` is not `if c then y else z end`
  -- until the type report says it is neither.
  local source = lines("local a = c and y or z", "local b = c and f() or z", "local d = c and not y or z", "local e = c and true or z")
  translates(source, source)
end

-- classes

local function test_the_methods_of_a_record_move_into_a_class_with_self_written()
  translates(lines(
    "--- A counter.",
    "local record Counter",
    "  --- The count.",
    "  count: integer",
    "  --- Adds `by`.",
    "  add: function(Counter, integer): integer",
    "  reset: function(Counter)",
    "end",
    "",
    "function Counter:add(by: integer): integer",
    "  self.count = self.count + by",
    "  return self.count",
    "end",
    "",
    "function Counter:reset()",
    "  self.count = 0",
    "end",
    "",
    "return Counter"), lines(
      "--- A counter.",
      "local class Counter",
      "  --- The count.",
      "  mut count: integer",
      "",
      "  --- Adds `by`.",
      "  function add(self, by: integer): integer",
      "    self.count = self.count + by",
      "    return self.count",
      "  end",
      "",
      "  function reset(self)",
      "    self.count = 0",
      "  end",
      "end",
      "",
      "return Counter"))
end

local function test_a_method_the_record_does_not_declare_moves_too()
  translates(lines(
    "local record R is Base",
    "  n: integer",
    "end",
    "--- Says hello.",
    "function R:hello(): string",
    "  return \"hi\"",
    "end"), lines(
      "local class R is Base",
      "  n: integer",
      "",
      "  --- Says hello.",
      "  function hello(self): string",
      "    return \"hi\"",
      "  end",
      "end"))
end

local function test_a_moved_method_keeps_the_lines_of_its_strings()
  local got = clean(lines(
    "local record R",
    "end",
    "function R:text(): string",
    "  return [[",
    "raw]] .. \"x\"",
    "end")).text
  assert(got == lines(
    "local class R",
    "  function text(self): string",
    "    return [[",
    "raw]] .. \"x\"",
    "  end",
    "end"), got)
end

local function test_a_record_with_an_array_part_or_userdata_stays_a_record()
  local source = lines("local record R is {R}", "end", "function R:f() end")
  local result = Translate.translate(source, "t.tl")
  assert(result.text == source and result.errors[1].code == "method_in_record")
end

local function test_a_name_declared_between_the_record_and_a_method_is_reported()
  local result = clean(lines(
    "local record R",
    "  n: integer",
    "end",
    "local helper = 1",
    "function R:f(): integer",
    "  return self.n + helper",
    "end"))
  local h = result.hazards[1]
  assert(#result.hazards == 1 and h.class == "R" and h.method == "f" and h.name == "helper" and h.y == 5,
    #result.hazards .. " hazards")
end

-- mut

local function test_a_field_assigned_after_creation_is_mut()
  translates(lines(
    "local record Counter",
    "  count: integer",
    "  label: string",
    "end",
    "local function bump(c: Counter)",
    "  c.count = c.count + 1",
    "end",
    "local function make(): Counter",
    "  local c: Counter = { count = 0, label = \"\" }",
    "  c.label = \"x\"",
    "  return c",
    "end"), lines(
      "local record Counter",
      "  mut count: integer",
      "  mut label: string",
      "end",
      "local function bump(c: Counter)",
      "  c.count = c.count + 1",
      "end",
      "local function make(): Counter",
      "  local c: Counter = { count = 0, label = \"\" }",
      "  c.label = \"x\"",
      "  return c",
      "end"))
end

local function test_a_field_a_method_assigns_through_self_is_mut()
  translates(lines(
    "local record Counter",
    "  count: integer",
    "  fixed: integer",
    "end",
    "function Counter:bump()",
    "  self.count = self.count + self.fixed",
    "end"), lines(
      "local class Counter",
      "  mut count: integer",
      "  fixed: integer",
      "",
      "  function bump(self)",
      "    self.count = self.count + self.fixed",
      "  end",
      "end"))
end

local function test_a_collection_a_field_holds_is_mut_when_it_is_changed_in_place()
  translates(lines(
    "local record Bag",
    "  items: {string}",
    "  seen: {string: boolean}?",
    "  read_only: {string}",
    "end",
    "local function add(b: Bag, x: string)",
    "  b.items[#b.items + 1] = x",
    "  table.insert(b.items, x)",
    "  b.seen[x] = true",
    "  return #b.read_only",
    "end"), lines(
      "local record Bag",
      "  items: mut {string}",
      "  seen: mut {string: boolean}?",
      "  read_only: {string}",
      "end",
      "local function add(b: Bag, x: string)",
      "  b.items[#b.items + 1] = x",
      "  table.insert(b.items, x)",
      "  b.seen[x] = true",
      "  return #b.read_only",
      "end"))
end

local function test_a_collection_parameter_the_function_changes_is_mut()
  translates(lines(
    "local function fill(xs: {integer}, ys: {integer}, zs: {string: boolean}, ws: {integer}?)",
    "  xs[1] = 0",
    "  table.sort(ys)",
    "  zs.k = true",
    "  ws[#ws + 1] = 1",
    "  return #xs",
    "end",
    "local function look(xs: {integer}): integer",
    "  return xs[1]",
    "end"), lines(
      "local function fill(xs: mut {integer}, ys: mut {integer}, zs: {string: boolean}, ws: mut {integer}?)",
      "  xs[1] = 0",
      "  table.sort(ys)",
      "  zs.k = true",
      "  ws[#ws + 1] = 1",
      "  return #xs",
      "end",
      "local function look(xs: {integer}): integer",
      "  return xs[1]",
      "end"))
end

local function test_a_write_is_credited_only_to_the_record_a_name_is_declared_as()
  -- `c` is another type in the callback, a local of another type shadows the
  -- parameter in the block, and `t` is nothing declared.
  local source = lines(
    "local record R",
    "  n: integer",
    "end",
    "local function f(c: R, t: any)",
    "  local g = function(c: Other) c.n = 1 end",
    "  if t then",
    "    local c: Other = t",
    "    c.n = 2",
    "  end",
    "  t.n = 3",
    "  return c.n",
    "end")
  translates(source, source)
end

local function test_a_name_bound_twice_is_taken_for_the_record_where_it_is_declared()
  translates(lines(
    "local record R",
    "  n: integer",
    "  m: integer",
    "end",
    "local function f(c: R, o: any)",
    "  c.n = 1",
    "  do",
    "    local c = o",
    "    c.m = 2",
    "  end",
    "end"), lines(
      "local record R",
      "  mut n: integer",
      "  m: integer",
      "end",
      "local function f(c: R, o: any)",
      "  c.n = 1",
      "  do",
      "    local c = o",
      "    c.m = 2",
      "  end",
      "end"))
end

local function test_a_class_that_writes_a_field_without_mut_is_given_it()
  translates(lines(
    "local class C",
    "  n: integer",
    "  function set(self)",
    "    self.n = 1",
    "  end",
    "end"), lines(
      "local class C",
      "  mut n: integer",
      "  function set(self)",
      "    self.n = 1",
      "  end",
      "end"))
end

-- the review's cases

local function test_a_method_that_reads_a_name_declared_again_between_is_reported_as_changing()
  local result = clean(lines(
    "local x = 1",
    "local record R",
    "  n: integer",
    "end",
    "local x = 2",
    "function R:get(): integer",
    "  return x + self.n",
    "end"))
  local h = result.hazards[1]
  assert(#result.hazards == 1 and h.kind == "shadow" and h.name == "x" and h.method == "get", #result.hazards .. " hazards")
end

local function test_a_name_declared_only_between_is_a_scope_hazard()
  local result = clean(lines("local record R", "end", "local x = 2", "function R:get(): integer", "  return x", "end"))
  assert(#result.hazards == 1 and result.hazards[1].kind == "scope")
end

local function test_a_long_comment_before_a_long_comment_that_code_follows_is_left()
  local source = "--[[a]] --[[b]] f()\n"
  local result = Translate.translate(source, "t.tl")
  assert(result.text == source and result.errors[1].code == "long_comment", result.text)
  -- Nothing but comments follow the first one, so both become line comments.
  translates("--[[a]] --[=[b]=]\nf()\n", "-- a -- b\nf()\n")
end

local function test_every_semicolon_between_table_items_is_a_comma()
  translates(lines(
    "local a = {1; 2; 3}",
    "local b = { x = 1; y = 2; z = 3; }",
    "local c = {1, 2; f = function() x(); y() end; 4}"), lines(
      "local a = {1, 2, 3}",
      "local b = { x = 1, y = 2, z = 3, }",
      "local c = {1, 2, f = function() x() y() end, 4}"))
end

local function test_a_goto_whose_label_is_not_the_end_of_its_innermost_loop_is_left_with_its_label()
  -- The goto in the inner loop reaches the outer loop's label: `continue`
  -- would leave the inner loop instead.
  local nested = lines("for i = 1, 3 do", "  for j = 1, 3 do", "    goto continue", "  end", "  ::continue::", "end")
  local result = Translate.translate(nested, "t.tl")
  assert(result.text == nested and result.errors[1].code == "label_or_goto", result.text)
  -- A label in a block inside the loop is the one a goto there reaches.
  local inner = lines("for i = 1, 3 do", "  do", "    goto continue", "    ::continue::", "  end", "end")
  result = Translate.translate(inner, "t.tl")
  assert(result.text == inner and result.errors[1].code == "label_or_goto", result.text)
  -- The same loop with every goto at its own level is translated.
  translates(lines("for i = 1, 3 do", "  if i then goto continue end", "  ::continue::", "end"),
    lines("for i = 1, 3 do", "  if i then continue end", "", "end"))
end

local function test_table_move_changes_only_the_collection_it_writes_to()
  translates(lines(
    "local function f(a: {integer}, b: {integer}, c: {integer})",
    "  table.move(a, 1, 2, 3, b)",
    "  table.move(c, 1, 2, 3)",
    "end"), lines(
      "local function f(a: {integer}, b: mut {integer}, c: mut {integer})",
      "  table.move(a, 1, 2, 3, b)",
      "  table.move(c, 1, 2, 3)",
      "end"))
end

local function test_mut_is_written_on_the_interface_and_every_record_that_implements_it()
  translates(lines(
    "local interface Shape",
    "  size: integer",
    "  tags: {string}",
    "end",
    "local record Square is Shape",
    "  size: integer",
    "  tags: {string}",
    "end",
    "local record Circle is Shape",
    "  size: integer",
    "  tags: {string}",
    "end",
    "local function grow(s: Square)",
    "  s.size = 1",
    "  table.insert(s.tags, \"x\")",
    "end"), lines(
      "local interface Shape",
      "  mut size: integer",
      "  tags: mut {string}",
      "end",
      "local record Square is Shape",
      "  mut size: integer",
      "  tags: mut {string}",
      "end",
      "local record Circle is Shape",
      "  mut size: integer",
      "  tags: mut {string}",
      "end",
      "local function grow(s: Square)",
      "  s.size = 1",
      "  table.insert(s.tags, \"x\")",
      "end"))
end

local function test_a_field_given_mut_in_a_record_of_an_interface_from_another_file_is_reported()
  local result = clean(lines(
    "local record Y is Other.Face",
    "  n: integer",
    "end",
    "local function f(y: Y)",
    "  y.n = 1",
    "end"))
  local h = result.hazards[1]
  assert(#result.hazards == 1 and h.kind == "interface" and h.class == "Y" and h.method == "n" and h.name == "Other.Face")
  assert(result.text:find("mut n: integer", 1, true))
end

local function test_a_method_takes_the_types_of_the_field_that_declared_it()
  translates(lines(
    "local record R",
    "  f: function(R, integer, string): string | nil",
    "  g: function(R, x: integer): integer",
    "end",
    "function R:f(x, y)",
    "  return nil",
    "end",
    "function R:g(x: integer): integer",
    "  return x",
    "end"), lines(
      "local class R",
      "",
      "  function f(self, x: integer, y: string): string?",
      "    return nil",
      "  end",
      "",
      "  function g(self, x: integer): integer",
      "    return x",
      "  end",
      "end"))
end

local function test_a_method_that_gives_other_types_than_its_field_is_reported()
  local result = clean(lines(
    "local record R",
    "  f: function(R, integer): string",
    "end",
    "function R:f(x: string): integer",
    "  return 1",
    "end"))
  local names: {string} = {}
  for _, h in ipairs(result.hazards) do
    names[#names + 1] = h.kind .. " " .. h.name
  end
  table.sort(names)
  assert(table.concat(names, ",") == "signature return,signature x", table.concat(names, ","))
end

local function test_an_omittable_parameter_takes_a_name_no_other_parameter_has()
  translates("local a: function(? integer, arg1: string, arg1_: string)\n",
    "local a: function(arg1__?: integer, arg1: string, arg1_: string)\n")
end

local function test_a_parenthesized_union_with_nil_is_an_optional_of_the_parentheses()
  translates("local a: (string | number) | nil\n", "local a: (string | number)?\n")
end

-- the second review's cases

local function test_a_semicolon_after_a_nested_table_separates_the_items_of_the_table_around_it()
  translates(lines(
    "local a = { a = { b = 1 }; c = 2 }",
    "local b = { {1; 2}; {3; 4} }",
    "local c = { {1; 2; 3}; 4; {5} }"), lines(
      "local a = { a = { b = 1 }, c = 2 }",
      "local b = { {1, 2}, {3, 4} }",
      "local c = { {1, 2, 3}, 4, {5} }"))
  -- A statement `;` after a closed table is still removed.
  translates("local a = {};\nlocal b = { 1 }; local c = 2\n", "local a = {}\nlocal b = { 1 } local c = 2\n")
end

local function test_an_interface_named_with_its_qualifier_in_the_same_file_is_linked()
  translates(lines(
    "local record Stream",
    "  interface Reader",
    "    n: integer",
    "  end",
    "end",
    "local record FdReader is Stream.Reader",
    "  n: integer",
    "end",
    "local function bump(r: FdReader)",
    "  r.n = 1",
    "end"), lines(
      "local record Stream",
      "  interface Reader",
      "    mut n: integer",
      "  end",
      "end",
      "local record FdReader is Stream.Reader",
      "  mut n: integer",
      "end",
      "local function bump(r: FdReader)",
      "  r.n = 1",
      "end"))
end

local function test_mut_goes_up_a_chain_of_interfaces_and_down_to_the_records_that_declare_the_field()
  local result = clean(lines(
    "local interface I",
    "  a: integer",
    "end",
    "local interface J is I",
    "end",
    "local record K is J",
    "  a: integer",
    "end",
    "local record L is J",
    "  a: integer",
    "end",
    "local record Other is J",
    "  b: integer",
    "end",
    "local function set(k: K)",
    "  k.a = 1",
    "end"))
  local _, muts = result.text:gsub("mut a: integer", "")
  assert(muts == 3 and not result.text:find("mut b", 1, true), result.text)
  assert(result.interfaces[1].name == "I" and result.interfaces[1].fields[1] == "a")
  assert(result.interfaces[2].name == "J" and result.interfaces[2].supers[1] == "I")
end

local function test_a_field_a_record_inherits_from_an_interface_of_another_file_and_assigns_is_reported()
  local result = clean(lines(
    "local record M is Other.Face",
    "end",
    "local function f(m: M)",
    "  m.inherited = 2",
    "end"))
  local h = result.hazards[1]
  assert(#result.hazards == 1 and h.kind == "interface" and h.class == "M" and h.method == "inherited" and
      h.name == "Other.Face")
end

local function test_a_method_takes_optional_marks_and_leaves_a_generic_field_alone()
  translates(lines(
    "local record R",
    "  f: function(R, integer, ? string)",
    "  h: function(R, {integer})",
    "end",
    "function R:f(x, y)",
    "end",
    "function R:h(xs)",
    "  xs[1] = 0",
    "end"), lines(
      "local class R",
      "",
      "  function f(self, x: integer, y?: string)",
      "  end",
      "",
      "  function h(self, xs: mut {integer})",
      "    xs[1] = 0",
      "  end",
      "end"))
  local result = Translate.translate(lines(
    "local record G",
    "  g: function<T>(G, T): T",
    "end",
    "function G:g(x)",
    "  return x",
    "end"), "t.tl")
  assert(result.hazards[1].kind == "signature" and result.hazards[1].name == "generic" and
      result.text:find("function g(self, x)", 1, true), result.text)
end

local function test_a_translation_with_a_carried_collection_type_is_its_own_translation()
  local once = clean(lines(
    "local record R",
    "  h: function(R, {integer}): integer | nil",
    "end",
    "function R:h(xs)",
    "  xs[1] = 0",
    "  return nil",
    "end"))
  assert(once.text:find("function h(self, xs: mut {integer}): integer?", 1, true), once.text)
  local twice = Translate.translate(once.text, "t.tl")
  assert(twice.text == once.text and next(twice.counts) == nil)
end

local function test_a_goto_split_from_its_label_name_across_lines_is_translated_with_its_label()
  translates(lines(
    "for i = 1, 3 do",
    "  if i then goto",
    "    continue end",
    "  ::continue::",
    "end"), lines(
      "for i = 1, 3 do",
      "  if i then ",
      "    continue end",
      "",
      "end"))
end

-- what stays

local function test_a_cast_is_and_the_forms_the_grammar_keeps_are_not_changed()
  local source = lines(
    "local a = x as string",
    "local b = y is integer",
    "local c <const> = 1",
    "local d <close> = f()",
    "local e: {string: boolean} = {}",
    "local record R is {R}",
    "  mut n?: integer",
    "end",
    "local function g(a: integer, ...: string): string...",
    "  return ...",
    "end",
    "for i = 10, 1, -1 do end",
    "repeat local z = 1 until z",
    "local k = if a then 1 else 2 end",
    "local s = 'x' .. [==[y]==] .. \"z\"")
  translates(source, source)
end

local function test_text_in_the_new_grammar_translates_to_itself()
  local source = lines(
    "local type Reply = function(): (true, string) | (false, string)",
    "local function show(fetch: Reply)",
    "  match fetch() do",
    "    | (true, body) then print(body)",
    "    | (false, why) then print(\"failed: \" .. why)",
    "  end",
    "end",
    "local class Counter is Resettable",
    "  label: string",
    "  mut count: integer",
    "  seen: mut {string}",
    "  function bump(self, by: integer): integer",
    "    self.count = self.count + by",
    "    return self.count",
    "  end",
    "end",
    "local c: Counter = { label = \"n\", count = 0, seen = {} }",
    "local noun = if c.count == 1 then \"item\" else \"items\" end",
    "local o: (A | B)? = nil",
    "is_reader: function(v: any): v is Reader")
  local result = Translate.translate(source, "t.tl")
  assert(result.text == source and next(result.counts) == nil and result.reads == 1)
end

-- what holds for any translation

--- Teal with every row in it, laid out so that a lines check means something.
local SAMPLE <const> = lines(
  "--- A module.",
  "local type Point = record -- a point",
  "  x: number | nil",
  "  metamethod __close: function(Point)",
  "end",
  "local a: A | B | nil = nil -- one",
  "--[[ long",
  "  comment ]]",
  "local n = 1_000 + 0x1p4; -- two",
  "for i = 1, 3 do",
  "  -- three",
  "  if i == 2 then goto continue end",
  "  local s = i == 1 and \"one\" or \"many\" -- four",
  "  ::continue::",
  "end",
  "local f: function(string..., ? integer): (function(): R) | nil")

local function count(text: string): integer
  local n = 1
  for _ in text:gmatch("\n") do
    n = n + 1
  end
  return n
end

local function test_a_respelling_keeps_every_line_where_it_was()
  local result = clean(SAMPLE)
  assert(count(result.text) == count(SAMPLE), result.text)
  local want = Lexer.lex(SAMPLE, "t.tl").tokens
  local got = Lexer.lex(result.text, "t.tl").tokens
  -- The first token of each statement is on the line it was on.
  for _, word in ipairs({ "local", "for" }) do
    local before: {integer} = {}
    local after: {integer} = {}
    for _, t in ipairs(want) do
      if t.text == word and t.kind == "keyword" then before[#before + 1] = t.y end
    end
    for _, t in ipairs(got) do
      if t.text == word and t.kind == "keyword" then after[#after + 1] = t.y end
    end
    assert(table.concat(before, ",") == table.concat(after, ","), word)
  end
end

local function test_every_comment_is_kept()
  local result = clean(SAMPLE)
  for _, comment in ipairs({ "--- A module.", "-- a point", "-- one", "-- two", "-- three", "-- four" }) do
    assert(result.text:find(comment, 1, true), comment)
  end
  assert(result.text:find("-- long", 1, true) and result.text:find("-- comment", 1, true))
end

local function test_a_translation_parses_clean_and_tiles_its_tokens()
  local result = clean(SAMPLE)
  local ok, why = Cover.check(result.text, Lexer.lex(result.text, "t.tl"))
  assert(ok, why)
  assert(#Parser.parse(Lexer.lex(result.text, "t.tl"), "t.tl", "tl").errors == 0)
end

local function test_translating_again_changes_nothing()
  local once = clean(SAMPLE)
  local twice = Translate.translate(once.text, "t.tl")
  assert(twice.text == once.text and next(twice.counts) == nil and twice.reads == 1)
end

local function test_each_row_is_counted()
  local result = clean(SAMPLE)
  for _, row in ipairs({ "nil_union", "variadic_type", "optional_type", "continue", "semicolon", "long_comment",
      "digit_separator", "hex_float", "type_declaration", "metamethod", "ternary" }) do
    assert((result.counts[row] or 0) >= 1, row)
  end
  assert(result.counts.nil_union == 3 and result.counts.continue == 1, "a goto and its label are one rewrite")
end

local function test_a_declaration_file_is_read_as_one()
  translates(lines(
    "local record io",
    "  metamethod __close: function(io, any)",
    "  open: function(string): io | nil, string",
    "end",
    "return io"), lines(
      "local record io",
      "  __close: function(io, any)",
      "  open: function(string): io?, string",
      "end",
      "return io"), "io.d.tl")
end

local function test_a_source_with_errors_of_its_own_is_translated_as_far_as_it_goes()
  local result = Translate.translate("local a: A | nil\nlocal b = = 1\n", "t.tl")
  assert(result.text == "local a: A?\nlocal b = = 1\n" and result.errors[1].code == "expected_expression")
end

local function test_the_forms_the_draft_has_rewritten_by_hand_are_the_errors_left()
  local codes: {string} = {}
  local result = Translate.translate(lines(
    "local a: {{string, integer}}",
    "local match = 1",
    "local b = f\"s\""), "t.tl")
  for _, e in ipairs(result.errors) do
    codes[#codes + 1] = e.code
  end
  assert(table.concat(codes, " ") == "tuple_type reserved_word string_call", table.concat(codes, " "))
end
