--- The translator from Teal to the new checker's grammar ([`lang.translate`]):
--- one test for each row of the draft's table, written as the Teal in and
--- the text out, then what holds for every translation: the lines and
--- comments of a respelling stay where they were, a translation parses with
--- no error and translating it again changes nothing.
local Cover = require("lang.lexer_cover")
local Lexer = require("lang.lexer")
local Parser = require("lang.parser")
local Programs = require("lang.check_programs")
local Test = require("cosmic.test")
local Translate = require("lang.translate")

Test.policy{}

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

local function test_a_separator_not_between_two_digits_is_left_to_be_refused()
  -- the fork refuses these as malformed numbers, so the program is not made right by dropping the `_`
  for _, source in ipairs({ "local a = 1__0\n", "local a = 1_\n", "local a = 0x_F\n", "local a = 0xF_\n",
      "local a = 1_0__0\n", "local a = 1_000_\n" }) do
    local result = Translate.translate(source, "t.tl")
    assert(result.text == source, source .. " became " .. result.text)
  end
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

-- unary operators over a power

--- The fork binds a unary operator to its operand before a `^`; Lua and the new grammar bind the `^` first.
local function test_a_unary_operator_over_a_power_is_parenthesized_as_the_fork_reads_it()
  translates(lines(
    "local a = -x ^ 2",
    "local b = not y ^ z",
    "local c = - - x ^ 2 ^ 3",
    "local d = 1 + #t ^ 2 * 3",
    "local e = w ^ -x ^ 2",
    "local f = -(x ^ 2)",
    "local g = (-x) ^ 2",
    "local h = -x * 2",
    "return a"), lines(
      "local a = (-x) ^ 2",
      "local b = (not y) ^ z",
      "local c = (- - x) ^ 2 ^ 3",
      "local d = 1 + (#t) ^ 2 * 3",
      "local e = w ^ (-x) ^ 2",
      "local f = -(x ^ 2)",
      "local g = (-x) ^ 2",
      "local h = -x * 2",
      "return a"))
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
    "local g = x and ((\"s\") as string) or \"\"",
    "local h = x and true or w",
    "return c and 1 or 2"), lines(
      "local a = if n == 1 then \"item\" else \"items\" end",
      "local b = if x then 1 else 2 end",
      "local c = if x then { 1 } else y end",
      "local d = if x then f .. \"z\" else w end",
      "local e = if x then #t + 1 else 0 end",
      "local f = if x then function() end else nil end",
      "local g = if x then ((\"s\") as string) else \"\" end",
      "local h = if x then true else w end",
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
  -- A cast is a promise about the type and no value: `y as string` is false or nil when `y` is.
  local source = lines("local a = c and y or z", "local b = c and f() or z", "local d = c and not y or z",
    "local e = c and false or z", "local g = c and (y as string) or z", "local h = c and f() as {string} or z")
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
    "local helper = tonumber(\"1\")",
    "function R:f(): integer",
    "  return self.n + helper",
    "end"))
  local h = result.hazards[1]
  assert(#result.hazards == 1 and h.class == "R" and h.method == "f" and h.name == "helper" and h.y == 5,
    #result.hazards .. " hazards")
end

-- class literals

local function test_a_call_of_the_metatable_of_a_class_on_a_literal_is_the_literal_and_the_metatable_goes()
  local result = clean(lines(
    "local record Counter",
    "  n: integer",
    "  bump: function(Counter, integer): integer",
    "end",
    "",
    "local counter_mt: metatable<Counter> = { __index = Counter }",
    "",
    "function Counter:bump(by: integer): integer",
    "  self.n = self.n + by",
    "  return self.n",
    "end",
    "",
    "local function make(start: integer): Counter",
    "  return setmetatable({ n = start }, counter_mt)",
    "end",
    "",
    "local c: Counter = setmetatable({ n = 1 }, counter_mt)",
    "local d = setmetatable({",
    "  n = 2,",
    "}, counter_mt)",
    "local e <close> = setmetatable({ n = 3 }, counter_mt)",
    "return make(c.n)"))
  assert(result.text == lines(
    "local class Counter",
    "  mut n: integer",
    "",
    "  function bump(self, by: integer): integer",
    "    self.n = self.n + by",
    "    return self.n",
    "  end",
    "end",
    "",
    "local function make(start: integer): Counter",
    "  return { n = start }",
    "end",
    "",
    "local c: Counter = { n = 1 }",
    "local d: Counter = {",
    "  n = 2,",
    "}",
    "local e <close>: Counter = { n = 3 }",
    "return make(c.n)"), result.text)
  assert(result.counts.class_literal == 1 and table.concat(result.metatables, " ") == "counter_mt")
end

local function test_the_metatable_of_a_class_stays_with_every_call_when_one_of_them_is_not_a_literal()
  local source = lines(
    "local record Box",
    "  n: integer",
    "  get: function(Box): integer",
    "end",
    "",
    "local box_mt: metatable<Box> = { __index = Box }",
    "",
    "function Box:get(): integer",
    "  return self.n",
    "end",
    "",
    "local function adopt(t: {string: any}): Box",
    "  return setmetatable(t, box_mt)",
    "end",
    "",
    "local a: Box = setmetatable({ n = 1 }, box_mt)",
    "return a")
  local result = clean(source)
  assert(result.text:find("local box_mt: metatable<Box> = { __index = Box }", 1, true) ~= nil, result.text)
  assert(result.text:find("setmetatable({ n = 1 }, box_mt)", 1, true) ~= nil and result.counts.class_literal == nil)
  assert(#result.metatables == 0)
end

local function test_a_metatable_with_more_than_an_index_keeps_its_close_and_its_calls()
  -- A value made with the metatable would lose a `__close` that moved into the class.
  local source = lines(
    "local record Handle",
    "  fd: integer",
    "  get: function(Handle): integer",
    "end",
    "",
    "local handle_mt: metatable<Handle> = {",
    "  __index = Handle,",
    "  __close = function(self: Handle)",
    "    self.fd = -1",
    "  end,",
    "  __gc = function(self: Handle)",
    "    self.fd = -1",
    "  end,",
    "}",
    "",
    "function Handle:get(): integer",
    "  return self.fd",
    "end",
    "",
    "local h <close>: Handle = setmetatable({ fd = 1 }, handle_mt)",
    "return h")
  local result = clean(source)
  assert(result.text:find("__close = function(self: Handle)", 1, true) ~= nil, result.text)
  assert(result.text:find("__gc = function(self: Handle)", 1, true) ~= nil, result.text)
  assert(result.text:find("setmetatable({ fd = 1 }, handle_mt)", 1, true) ~= nil, result.text)
  assert(result.text:find("function __close", 1, true) == nil, "the class does not take the close: " .. result.text)
  assert(result.counts.class_literal == nil and #result.metatables == 0)
  -- the same metatable with an index and a close alone is the class's
  local plain = clean((source:gsub("  __gc = function%(self: Handle%)\n    self.fd = %-1\n  end,\n", "")))
  assert(plain.text:find("function __close(self)", 1, true) ~= nil and plain.text:find("handle_mt", 1, true) == nil, plain.text)
  assert(plain.counts.class_literal == 1)
end

local function test_a_literal_is_the_class_only_where_the_place_says_so()
  local head = lines(
    "local record Box",
    "  n: integer",
    "  get: function(Box): integer",
    "end",
    "",
    "local box_mt: metatable<Box> = { __index = Box }",
    "",
    "function Box:get(): integer",
    "  return self.n",
    "end",
    "")
  for _, place in ipairs({
      "local x: Stream.Reader = setmetatable({ n = 1 }, box_mt)",
      "local function f(): string\n  return setmetatable({ n = 1 }, box_mt)\nend",
      "local function f(): Box?\n  return setmetatable({ n = 1 }, box_mt)\nend",
      "local function f(): Box, string\n  return setmetatable({ n = 1 }, box_mt)\nend",
      "local x, y = setmetatable({ n = 1 }, box_mt)",
      "local x = f(setmetatable({ n = 1 }, box_mt))",
      "local x: Box = setmetatable({ n = 1 } as Box, box_mt)",
      "local t: Box = {}\nt.next = setmetatable({ n = 1 }, box_mt)",
  }) do
    local result = clean(head .. place .. "\n")
    assert(result.text:find("setmetatable(", 1, true) ~= nil and result.text:find("box_mt: metatable<Box>", 1, true) ~= nil,
      "converted at\n" .. place .. "\n" .. result.text)
    assert(result.counts.class_literal == nil)
  end
end

local function test_a_table_with_the_methods_of_a_class_as_its_index_is_the_literal_too()
  local result = clean(lines(
    "local record Pt",
    "  x: integer",
    "  get: function(Pt): integer",
    "end",
    "",
    "function Pt:get(): integer",
    "  return self.x",
    "end",
    "",
    "local p: Pt = setmetatable({ x = 1 }, { __index = Pt })",
    "local q: Pt = setmetatable({ x = 1 }, { __index = Pt, __mode = \"k\" })",
    "return p, q"))
  assert(result.text:find("local p: Pt = { x = 1 }\n", 1, true) ~= nil, result.text)
  assert(result.text:find("local q: Pt = setmetatable({ x = 1 }, { __index = Pt, __mode = \"k\" })", 1, true) ~= nil, result.text)
  assert(result.counts.class_literal == 1 and #result.metatables == 0)
end

local function test_a_record_with_no_method_is_no_class_and_its_calls_stay()
  local source = lines(
    "local record Plain",
    "  n: integer",
    "end",
    "",
    "local plain_mt: metatable<Plain> = { __index = Plain }",
    "",
    "local p: Plain = setmetatable({ n = 1 }, plain_mt)",
    "return p")
  assert(clean(source).text == source)
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

local function test_the_close_of_the_metatable_literal_of_a_record_becomes_a_method_of_its_class()
  -- The class carries `__close`, which an interface that declares it needs; the literal keeps the rest.
  translates(lines(
    "local record R",
    "  open: boolean",
    "  close: function(R)",
    "end",
    "",
    "local r_mt: metatable<R> = {",
    "  __index = R,",
    "  __close = function(self: R)",
    "    self:close()",
    "  end,",
    "}",
    "",
    "function R:close()",
    "  self.open = false",
    "end",
    "",
    "return R"), lines(
      "local class R",
      "  mut open: boolean",
      "",
      "  function close(self)",
      "    self.open = false",
      "  end",
      "",
      "  function __close(self)",
      "    self:close()",
      "  end",
      "end",
      "",
      "local r_mt: metatable<R> = {",
      "  __index = R,",
      "}",
      "",
      "return R"))
end

local function test_the_close_field_a_record_declares_goes_with_its_docs_to_the_method()
  translates(lines(
    "local record R",
    "  open: boolean",
    "  --- Closes it.",
    "  metamethod __close: function(R)",
    "  close: function(R)",
    "end",
    "",
    "local r_mt: metatable<R> = {",
    "  __close = function(self: R)",
    "    self:close()",
    "  end,",
    "}",
    "",
    "function R:close()",
    "  self.open = false",
    "end",
    "",
    "return R"), lines(
      "local class R",
      "  mut open: boolean",
      "",
      "  function close(self)",
      "    self.open = false",
      "  end",
      "",
      "  --- Closes it.",
      "  function __close(self)",
      "    self:close()",
      "  end",
      "end",
      "",
      "local r_mt: metatable<R> = {",
      "}",
      "",
      "return R"))
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
  local result = clean(lines("local record R", "end", "local x = tonumber(\"2\")", "function R:get(): integer", "  return x", "end"))
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

local function test_a_table_of_data_with_many_semicolons_is_translated_in_one_read()
  local items = ("1; k = 2; {3; 4}; "):rep(100)
  local result = clean("local t = {" .. items .. "}\n")
  assert(result.reads == 2 and not result.text:find(";", 1, true), result.reads .. " reads")
  assert(result.text:sub(1, 30) == "local t = {1, k = 2, {3, 4}, 1")
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

-- A field that declares a method's type and the `function R:m` that defines it agree on the parameters, or the program is refused.

local function test_a_field_and_a_method_that_give_other_numbers_of_parameters_leave_the_class_declaring_the_name_twice()
  -- the fork reads `function(integer)` as a function that takes an integer, and the method as one that takes `self` too
  local result = Translate.translate(lines(
    "local record R",
    "  m: function(integer)",
    "end",
    "function R:m(x: integer)",
    "end"), "t.tl")
  local first = result.errors[1]
  assert(first ~= nil and first.code == "duplicate_field" and first.msg:find("`m`", 1, true) ~= nil and
      first.fix:find("make the method give the same parameters", 1, true) ~= nil and #result.errors == 1,
    "errors: " .. tostring(#result.errors) .. " in\n" .. result.text)
  assert(result.text == lines(
    "local class R",
    "  m: function(integer)",
    "",
    "  function m(self, x: integer)",
    "  end",
    "end"), result.text)
  -- the field with more parameters than the method, and a method that takes none
  local more = Translate.translate(lines(
    "local record R",
    "  m: function(R, integer, string)",
    "end",
    "function R:m(x)",
    "end"), "t.tl")
  local more_first = more.errors[1]
  assert(more_first ~= nil and more_first.code == "duplicate_field", more.text)
  local none = Translate.translate(lines(
    "local record R",
    "  m: function()",
    "end",
    "function R:m()",
    "end"), "t.tl")
  local none_first = none.errors[1]
  assert(none_first ~= nil and none_first.code == "duplicate_field", none.text)
end

local function test_a_field_and_a_method_that_give_the_same_parameters_are_one_method_with_the_types_of_the_field()
  local result = clean(lines(
    "local record R",
    "  total: integer",
    "  m: function(R, integer): integer",
    "end",
    "function R:m(x)",
    "  return x + self.total",
    "end"))
  assert(result.text == lines(
    "local class R",
    "  total: integer",
    "",
    "  function m(self, x: integer): integer",
    "    return x + self.total",
    "  end",
    "end"), result.text)
  -- a variadic or a type parameter of the field leaves the count to the checker
  clean(lines(
    "local record V",
    "  m: function(V, integer...)",
    "end",
    "function V:m(...)",
    "end"))
end

local function test_the_method_of_a_field_that_agrees_runs_with_the_declared_types()
  local result = clean(lines(
    "local record R",
    "  total: integer",
    "  m: function(R, integer): integer",
    "end",
    "function R:m(x)",
    "  return x + self.total",
    "end",
    "local r: R = { total = 3 }",
    "print(r:m(4))"))
  local x = Programs.execute(result.text, true)
  assert(x.ran and x.fault == nil and x.printed[1] == "7", tostring(x.fault) .. " in\n" .. x.lua)
  -- the types of the field are the method's: a call with another type is refused
  local wrong = Programs.run((result.text:gsub("print%(r:m%(4%)%)", "print(r:m('a'))")))
  assert(Programs.codes(wrong) == "not_assignable", Programs.codes(wrong))
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
    for i, text in ipairs(want.text) do
      if text == word and want.kind[i] == "keyword" then before[#before + 1] = Lexer.y(want, i) end
    end
    for i, text in ipairs(got.text) do
      if text == word and got.kind[i] == "keyword" then after[#after + 1] = Lexer.y(got, i) end
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

-- A function that answers nothing may say so with an empty return list, which a doctest's helper does; reading its list
-- for a union in parentheses must not look at a first type that is not there.
local function test_an_empty_return_list_is_read_and_left_as_it_is()
  local source = lines(
    "local into = function(...: any): ()",
    "end",
    "local function done(): ()",
    "end",
    "local t: function(): ()",
    "return into")
  local result = Translate.translate(source, "t.tl")
  assert(result.text:sub(1, #"local into = function(...: any): ()") == "local into = function(...: any): ()", result.text)
  assert(result.text:find("local function done(): ()", 1, true) ~= nil, result.text)
end

-- a function a method reads moves above the class

local function test_a_local_function_between_the_record_and_a_method_that_reads_it_moves_above_the_record()
  local result = clean(lines(
    "--- A counter.",
    "local record R",
    "  n: integer",
    "end",
    "",
    "--- Bumps `r`.",
    "local function bump(r: R): integer",
    "  return r.n + 1",
    "end",
    "",
    "function R:next(): integer",
    "  return bump(self)",
    "end"))
  assert(#result.hazards == 0, #result.hazards .. " hazards")
  local at_function, at_class = result.text:find("local function bump", 1, true), result.text:find("local class R", 1, true)
  assert(at_function ~= nil and at_class ~= nil and at_function < at_class, result.text)
  -- its docs go with it, and the record keeps its own
  assert(result.text:find("--- Bumps `r`.\nlocal function bump", 1, true) ~= nil and
      result.text:find("--- A counter.\nlocal class R", 1, true) ~= nil, result.text)
  assert(select(2, result.text:gsub("local function bump", "")) == 1, result.text)
end

local function test_a_function_moves_with_the_functions_it_reads_in_the_order_it_had()
  local result = clean(lines(
    "local record R",
    "  n: integer",
    "end",
    "local function first(r: R): integer",
    "  return r.n",
    "end",
    "local function second(r: R): integer",
    "  return first(r) + 1",
    "end",
    "local function unread(r: R): integer",
    "  return r.n - 1",
    "end",
    "function R:next(): integer",
    "  return second(self)",
    "end"))
  assert(#result.hazards == 0, #result.hazards .. " hazards")
  local a, b = result.text:find("local function first", 1, true), result.text:find("local function second", 1, true)
  local c, d = result.text:find("local class R", 1, true), result.text:find("local function unread", 1, true)
  assert(a ~= nil and b ~= nil and c ~= nil and d ~= nil and a < b and b < c and c < d, result.text)
end

local function test_a_literal_the_function_reads_moves_with_it_and_a_value_made_by_a_call_keeps_it()
  local moved = clean(lines(
    "local record R",
    "  n: integer",
    "end",
    "local step = 2",
    "local function bump(r: R): integer",
    "  return r.n + step",
    "end",
    "function R:next(): integer",
    "  return bump(self)",
    "end"))
  assert(#moved.hazards == 0, #moved.hazards .. " hazards")
  local at_step, at_bump, at_class = moved.text:find("local step = 2", 1, true), moved.text:find("local function bump", 1, true),
    moved.text:find("local class R", 1, true)
  assert(at_step ~= nil and at_bump ~= nil and at_class ~= nil and at_step < at_bump and at_bump < at_class, moved.text)
  local kept = clean(lines(
    "local record R",
    "  n: integer",
    "end",
    "local step = tonumber(\"2\")",
    "local function bump(r: R): integer",
    "  return r.n + step",
    "end",
    "function R:next(): integer",
    "  return bump(self)",
    "end"))
  local result = kept
  local names: {string} = {}
  for _, h in ipairs(result.hazards) do
    names[#names + 1] = h.name
  end
  table.sort(names)
  assert(table.concat(names, " ") == "bump", table.concat(names, " "))
  assert(result.text:find("local class R", 1, true) < result.text:find("local function bump", 1, true), result.text)
end

local function test_a_function_that_reads_the_record_as_a_value_stays()
  local result = clean(lines(
    "local record R",
    "  n: integer",
    "  make: function(): R",
    "end",
    "local function fresh(): R",
    "  return R.make()",
    "end",
    "function R:again(): R",
    "  return fresh()",
    "end"))
  assert(#result.hazards == 1 and result.hazards[1].name == "fresh", #result.hazards .. " hazards")
end

local function test_a_function_that_names_a_type_in_a_local_annotation_moves_with_the_type_unless_the_type_is_a_class()
  local moved = clean(lines(
    "local record R",
    "  n: integer",
    "end",
    "local record Pair",
    "  a: integer",
    "end",
    "local function pair(r: R): integer",
    "  local p: Pair = { a = r.n }",
    "  return p.a",
    "end",
    "function R:both(): integer",
    "  return pair(self)",
    "end"))
  assert(#moved.hazards == 0, #moved.hazards .. " hazards")
  local at_type, at_function, at_class = moved.text:find("local record Pair", 1, true), moved.text:find("local function pair", 1, true),
    moved.text:find("local class R", 1, true)
  assert(at_type ~= nil and at_function ~= nil and at_class ~= nil and at_type < at_function and at_function < at_class, moved.text)
  -- a class with methods of its own stays where it was written, and the function that names it in its body with it
  local stays = clean(lines(
    "local record R",
    "  n: integer",
    "end",
    "local record Pair",
    "  a: integer",
    "end",
    "local function pair(r: R): integer",
    "  local p: Pair = { a = r.n }",
    "  return p.a",
    "end",
    "function R:both(): integer",
    "  return pair(self)",
    "end",
    "function Pair:twice(): integer",
    "  return self.a * 2",
    "end"))
  assert(#stays.hazards == 1 and stays.hazards[1].name == "pair", #stays.hazards .. " hazards")
  -- the same function that names the type in its signature alone moves
  local signature = clean(lines(
    "local record R",
    "  n: integer",
    "end",
    "local record Pair",
    "  a: integer",
    "end",
    "local function pair(r: R): Pair",
    "  return { a = r.n }",
    "end",
    "function R:both(): integer",
    "  return pair(self).a",
    "end",
    "function Pair:twice(): integer",
    "  return self.a * 2",
    "end"))
  assert(#signature.hazards == 0 and signature.text:find("local function pair", 1, true) < signature.text:find("local class R", 1, true),
    signature.text)
end

local function test_a_function_two_records_read_is_moved_once()
  local result = clean(lines(
    "local record A",
    "  n: integer",
    "end",
    "local record B",
    "  n: integer",
    "end",
    "local function shared(n: integer): integer",
    "  return n + 1",
    "end",
    "function A:f(): integer",
    "  return shared(self.n)",
    "end",
    "function B:g(): integer",
    "  return shared(self.n)",
    "end"))
  assert(select(2, result.text:gsub("local function shared", "")) == 1, result.text)
  local moved_at, first_at = result.text:find("local function shared", 1, true), result.text:find("local class A", 1, true)
  assert(moved_at < first_at, result.text)
end

local function test_a_function_that_shares_its_line_with_another_statement_stays_and_its_reader_is_a_hazard()
  -- moving a span from the middle of a line would leave the rest of the line behind or take it along
  for _, line in ipairs({
      "local y = 2 local function bump(r: R): integer return r.n + y end",
      "local function bump(r: R): integer return r.n end local y = 2",
  }) do
    local result = clean(lines(
      "local record R",
      "  n: integer",
      "end",
      line,
      "function R:next(): integer",
      "  return bump(self)",
      "end"))
    assert(#result.hazards >= 1, "no hazard for " .. line .. "\n" .. result.text)
    local at_function, at_class = result.text:find("local function bump", 1, true), result.text:find("local class R", 1, true)
    assert(at_function ~= nil and at_class ~= nil and at_function > at_class, result.text)
  end
end

local function test_a_function_the_second_record_reads_through_another_finds_what_the_first_took_already_above()
  local result = clean(lines(
    "local record A",
    "  n: integer",
    "end",
    "local record B",
    "  n: integer",
    "end",
    "local function shared(n: integer): integer",
    "  return n + 1",
    "end",
    "local function twice(n: integer): integer",
    "  return shared(n) * 2",
    "end",
    "function A:f(): integer",
    "  return shared(self.n)",
    "end",
    "function B:g(): integer",
    "  return twice(self.n)",
    "end"))
  assert(#result.hazards == 0, #result.hazards .. " hazards\n" .. result.text)
  assert(select(2, result.text:gsub("local function shared", "")) == 1, result.text)
  assert(select(2, result.text:gsub("local function twice", "")) == 1, result.text)
  local shared_at, twice_at = result.text:find("local function shared", 1, true), result.text:find("local function twice", 1, true)
  local a_at, b_at = result.text:find("local class A", 1, true), result.text:find("local class B", 1, true)
  assert(shared_at < a_at and a_at < twice_at and twice_at < b_at, result.text)
end

local function test_a_record_and_a_table_a_function_reads_move_above_the_record_with_it()
  local result = clean(lines(
    "local record R",
    "  n: integer",
    "end",
    "local record Info",
    "  n: integer",
    "end",
    "local info: Info = { n = 0 }",
    "local function look(): integer",
    "  local seen: Info = info",
    "  return seen.n",
    "end",
    "function R:size(): integer",
    "  return look()",
    "end"))
  assert(#result.hazards == 0, #result.hazards .. " hazards")
  local at_class, at_table, at_look, at_type = result.text:find("local class R", 1, true), result.text:find("local info:", 1, true),
    result.text:find("local function look", 1, true), result.text:find("local record Info", 1, true)
  assert(at_class ~= nil and at_table ~= nil and at_look ~= nil and at_type ~= nil, result.text)
  assert(at_type < at_table and at_table < at_look and at_look < at_class, result.text)
end

local function test_a_record_that_declares_a_type_of_its_own_stays_where_it_was_written()
  local result = clean(lines(
    "local record R",
    "  n: integer",
    "end",
    "local record Leaf",
    "  type Other = R",
    "  n: integer",
    "end",
    "local function leaf(): Leaf",
    "  return { n = 1 }",
    "end",
    "function R:get(): integer",
    "  local l: Leaf = leaf()",
    "  return l.n",
    "end"))
  assert(result.text:find("local record Leaf", 1, true) > result.text:find("local class R", 1, true), result.text)
end
