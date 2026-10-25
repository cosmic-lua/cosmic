--- A field a record declares `readonly` is set only in the table literal
--- that makes the record: a write through the record, an alias of it,
--- `self` or a literal key is refused with the code `readonly_field`, and
--- [`build.teal`]'s hint says where to give the value. The keyword is
--- type-level: it is erased from the emitted Lua, kept in a stub and a
--- declaration, and a field may still be named `readonly`.
local Test = require("cosmic.test")
local ast = require("build.ast")
local stub = require("build.stub")
local teal = require("build.teal")
local type compiler = require("build.compiler")

Test.policy{}

local built = assert(teal.load(true))

local head <const> = "local record R\n  readonly id: integer\n  n: integer\n" ..
  "  bump: function(R)\nend\n" ..
  "function R:bump()\n  self.n = self.n + 1\nend\n" ..
  "local r: R = { id = 1, n = 2 }\n"

local function type_errors(source: string): {compiler.Error}
  local _, result = built.gen(source, nil, nil, "tl")
  return assert(result).type_errors
end

--- The messages and codes of the type errors for `source`, one string.
local function shown(source: string): string
  local out: mut {string} = {}
  for _, e in ipairs(type_errors(source)) do
    out[#out + 1] = tostring(e.code) .. " " .. e.y .. ":" .. e.x .. " " .. e.msg
  end
  return table.concat(out, "; ")
end

--- Holds `source` to one error, a `readonly_field` of field `id` of
--- `record` (`R` unless given) at `y`:`x`, with the hint.
local function refused(source: string, y: integer, x: integer, record?: string, field?: string)
  local name = record or "R"
  local id = field or "id"
  local errors = type_errors(source)
  assert(#errors == 1, shown(source))
  local e = errors[1]
  assert(e.code == "readonly_field", shown(source))
  assert(e.key == id and e.subject == name, shown(source))
  assert(e.y == y and e.x == x, shown(source))
  assert(e.msg == "field '" .. id .. "' of '" .. name .. "' is read-only", e.msg)
  assert(teal.replacement(e, source) ==
      "field `" .. id .. "` of `" .. name .. "` is read-only: it is set only in the table literal that makes a `" ..
      name .. "`; give it its value there, or declare `" .. id .. "` without `readonly` if it changes after creation",
    tostring(teal.replacement(e, source)))
end

local function test_a_write_through_the_record_is_refused()
  refused(head .. "r.id = 2\n", 10, 2)
end

local function test_a_write_through_an_alias_is_refused()
  refused(head .. "local s = r\ns.id = 2\n", 11, 2)
end

local function test_a_write_through_self_is_refused()
  refused("local record R\n  readonly id: integer\n  reset: function(R)\nend\n" ..
      "function R:reset()\n  self.id = 0\nend\n", 6, 7)
end

local function test_a_write_to_the_literal_key_is_refused()
  refused(head .. 'r["id"] = 2\n', 10, 2)
end

local function test_a_write_among_several_targets_is_refused()
  refused(head .. "r.n, r.id = 1, 2\n", 10, 7)
end

local function test_the_literal_that_makes_the_record_sets_it()
  assert(shown(head .. "local again: R = { id = 3, n = 4 }\nr.n = again.id\nprint(r.id, again)\n") == "")
end

local function test_a_field_without_readonly_stays_writable()
  assert(shown(head .. 'r.n = 5\nr["n"] = 6\n') == "")
end

local function test_a_generic_record_and_an_interface_hold_their_fields()
  refused("local record Box<T>\n  readonly id: integer\n  v: T\nend\n" ..
      "local b: Box<string> = { id = 1, v = 'a' }\nb.v = 'b'\nb.id = 2\n", 7, 2, "Box")
  refused("local interface I\n  readonly id: integer\nend\n" ..
      "local record R is I\n  n: integer\nend\n" ..
      "local r: R = { id = 1, n = 2 }\nr.id = 2\n", 8, 2)
end

--- A write to the read-only field of one member of a union is refused too.
local function test_a_write_through_a_union_member_is_refused()
  refused("local record R\n  readonly id: integer\nend\n" ..
      "local function f(x: R | string)\n  if x is R then\n    x.id = 1\n  end\nend\n", 6, 6)
end

local function test_a_field_named_readonly_still_parses()
  local plain = "local record P\n  readonly: integer\n  readonly?: string\n  metamethod: boolean\nend\n" ..
    "local p: P = { readonly = 1, metamethod = true }\np.readonly = 2\np.readonly = p.readonly + 1\n"
  assert(shown(plain) == "", shown(plain))
  local named = "local record N\n  readonly readonly: integer\n  readonly metamethod: boolean\nend\n" ..
    "local n: N = { readonly = 1, metamethod = true }\nn.readonly = 2\n"
  local errors = type_errors(named)
  assert(#errors == 1 and errors[1].code == "readonly_field" and errors[1].key == "readonly", shown(named))
end

local function test_a_metamethod_cannot_be_read_only()
  local _, result = built.gen("local record R\n  readonly metamethod __call: function(R)\nend\nreturn R\n",
    nil, nil, "tl")
  local found = false
  for _, e in ipairs(assert(result).syntax_errors) do
    found = found or e.msg == "a metamethod cannot be read-only"
  end
  assert(found)
end

local function test_readonly_is_erased_from_the_emitted_lua()
  local with = "local record R\n  readonly id: integer\n  n: integer\nend\nlocal r: R = { id = 1, n = 2 }\nreturn r\n"
  local without = with:gsub("readonly ", "")
  local a = assert(built.gen(with, nil, nil, "tl"))
  local b = assert(built.gen(without, nil, nil, "tl"))
  assert(a == b, a .. "\nvs\n" .. b)
end

--- A stub keeps the keyword, types a program the same, and the checker
--- makes the same type of the module from either.
local function test_a_stub_keeps_the_keyword_and_types_the_same()
  local module = "local record R\n  readonly id: integer\n  n: integer\n  go: function(R)\nend\n" ..
    "function R.go(r: R)\n  r.n = 1\nend\nreturn R\n"
  local stubbed = stub.made((assert(ast.parse(built, module, "ro.tl")))).text
  assert(stubbed:find("readonly id: integer", 1, true) ~= nil, stubbed)
  local program = 'local R = require("ro")\nlocal r: R = { id = 1, n = 2 }\nr.id = 3\nr.n = 4\nreturn r\n'
  local function check(text: string): (string, compiler.Result)
    built.search_module = function(name: string, _all: boolean): string?, compiler.Handle?
      if name ~= "ro" then
        return nil
      end
      return "ro.tl", teal.served(text)
    end
    local env = assert(built.new_env({ defaults = teal.defaults() }))
    teal.strip(env)
    local result = built.check_string(program, env, "app.tl", "tl")
    local out: mut {string} = {}
    for _, e in ipairs(result.type_errors) do
      out[#out + 1] = tostring(e.code) .. " " .. e.y .. ":" .. e.x .. " " .. e.msg
    end
    return table.concat(out, "; "), result
  end
  local from_source, a = check(module)
  local from_stub, b = check(stubbed)
  assert(from_source == "readonly_field 3:2 field 'id' of 'R' is read-only", from_source)
  assert(from_stub == from_source, from_stub)
  assert(stub.difference(a.type, b.type) == nil, tostring(stub.difference(a.type, b.type)))
end

local function test_a_function_statement_on_a_value_is_refused_but_the_declaration_is_not()
  local record = "local record R\n  readonly id: integer\n  readonly cb: function(R)\nend\n"
  refused(record .. "local r: R = { id = 1, cb = function(_: R) end }\nfunction r.cb(_x: R) end\n", 6, 12, "R", "cb")
  refused(record .. "local r: R = { id = 1, cb = function(_: R) end }\nlocal c = r\nfunction c.cb(_x: R) end\n",
    7, 12, "R", "cb")
  -- The record type's own function is the declaration's implementation.
  assert(shown(record .. "function R.cb(_x: R) end\n") == "")
  assert(shown("local record M\n  readonly cb: function(M)\n  go: function(M)\nend\nfunction M:go()\nend\n" ..
      "function M.cb(_: M) end\n") == "")
end

local function test_a_key_typed_as_a_literal_or_an_enum_is_refused()
  refused(head .. "local k <const> = 'id'\nr[k] = 3\n", 11, 2)
  local enum = "local enum E\n  'id'\n  'n'\nend\n"
  refused(head .. enum .. "local function f(e: E)\n  r[e] = 1\nend\nprint(f)\n", 15, 4)
  local others = "local enum G\n  'n'\nend\n"
  assert(shown(head .. others .. "local function f(k: G)\n  r[k] = 1\nend\nprint(f)\n") == "")
  local many = "local record Q\n  readonly a: integer\n  readonly b: integer\nend\nlocal q: Q = { a = 1, b = 2 }\n" ..
    "local enum K\n  'a'\n  'b'\nend\nlocal function f(k: K)\n  q[k] = 1\nend\nprint(f)\n"
  local errors = type_errors(many)
  assert(#errors == 1 and errors[1].msg == "fields 'a', 'b' of 'Q' are read-only", shown(many))
  assert(assert(teal.replacement(errors[1], many)):find("fields `a`, `b` of `Q` are read-only", 1, true) ~= nil)
end

local function test_a_record_and_its_interface_agree_on_readonly()
  local both = "local interface I\n  readonly id: integer\nend\nlocal record R is I\n  readonly id: integer\nend\n" ..
    "local r: R = { id = 1 }\nprint(r)\n"
  assert(shown(both) == "", shown(both))
  local missing = "local interface I\n  readonly id: integer\nend\nlocal record R is I\n  id: integer\nend\n" ..
    "local r: R = { id = 1 }\nr.id = 2\n"
  assert(shown(missing):find("field 'id' is read-only in interface I but not in R: declare it `readonly id: integer` there",
    1, true) ~= nil, shown(missing))
  local extra = "local interface I\n  id: integer\nend\nlocal record R is I\n  readonly id: integer\nend\n" ..
    "local r: R = { id = 1 }\nprint(r)\n"
  assert(shown(extra):find("field 'id' is read-only in R but not in interface I: drop `readonly`", 1, true) ~= nil,
    shown(extra))
end

local function test_readonly_marks_a_field_not_a_nested_type()
  for _, nested in ipairs({ "record B\n  n: integer\n  end", "enum B\n  'a'\n  end", "type B = integer" }) do
    local _, result = built.gen("local record R\n  readonly " .. nested .. "\nend\nreturn R\n", nil, nil, "tl")
    local found = false
    for _, e in ipairs(assert(result).syntax_errors) do
      found = found or e.msg:find("'readonly' marks a field", 1, true) ~= nil
    end
    assert(found, nested)
  end
end

local function test_overloads_of_one_field_agree_on_readonly()
  for _, body in ipairs({ "  f: function(R)\n  readonly f: function(R, integer)\n",
      "  readonly f: function(R)\n  f: function(R, integer)\n" }) do
    local _, result = built.gen("local record R\n" .. body .. "end\nreturn R\n", nil, nil, "tl")
    local found = false
    for _, e in ipairs(assert(result).syntax_errors) do
      found = found or e.msg:find("field 'f' is declared both with and without 'readonly'", 1, true) ~= nil
    end
    assert(found, body)
  end
  local both = "local record R\n  readonly f: function(R)\n  readonly f: function(R, integer)\nend\nreturn R\n"
  assert(shown(both) == "", shown(both))
end

local function test_a_local_alias_of_the_record_type_defines_the_declared_function()
  local record = "local record R\n  readonly cb: function(R)\nend\n"
  assert(shown(record .. "local Q = R\nfunction Q.cb(_x: R) end\n") == "", shown(record .. "local Q = R\nfunction Q.cb(_x: R) end\n"))
  local value = record .. "local q: R = { cb = function(_x: R) end }\nfunction q.cb(_x: R) end\n"
  assert(shown(value):find("readonly_field", 1, true) ~= nil, shown(value))
end

local function test_the_disagreement_is_coded_and_told_the_field_s_type()
  local source = "local interface I\n  readonly id: integer\nend\nlocal record R is I\n  id: integer\nend\n"
  local errors = type_errors(source)
  assert(#errors == 1 and errors[1].code == "readonly_disagrees", shown(source))
  local e = errors[1]
  assert(e.key == "id" and e.subject == "R" and e.declared_in == "I" and e.expected == "integer" and
      e.readonly_in == "interface", shown(source))
  assert(e.msg:find("declare it `readonly id: integer` there", 1, true) ~= nil, e.msg)
  assert(teal.replacement(e, source) == "interface `I` declares `id` read-only, so `R` must too: write " ..
      "`readonly id: integer` in `R`, or drop `readonly` from the interface", tostring(teal.replacement(e, source)))
  local other = "local interface I\n  id: string\nend\nlocal record R is I\n  readonly id: string\nend\n"
  local back = type_errors(other)
  assert(#back == 1 and back[1].readonly_in == "record", shown(other))
  assert(teal.replacement(back[1], other) == "`R` declares `id` read-only but interface `I` does not: write " ..
      "`readonly id: string` in the interface, or drop `readonly` from `R`", tostring(teal.replacement(back[1], other)))
end

local function test_a_reassigned_alias_no_longer_names_the_record_type()
  local record = "local record R\n  readonly cb: function(R)\nend\n"
  local source = record .. "local Q = R\nlocal q: R = { cb = function(_x: R) end }\nQ = q\nfunction Q.cb(_x: R) end\n"
  assert(shown(source):find("readonly_field", 1, true) ~= nil, shown(source))
end

local plain_head <const> = "local record R\n  readonly id: integer\n  n: integer\nend\n"

--- Holds `source` to one error with `code` at `y`:`x` and returns it.
local function one_error(source: string, code: compiler.ErrorCode, y: integer, x: integer): compiler.Error
  local errors = type_errors(source)
  assert(#errors == 1, shown(source))
  local e = errors[1]
  assert(e.code == code, shown(source))
  assert(e.y == y and e.x == x, shown(source))
  return e
end

local function test_a_table_made_without_the_type_is_not_the_record()
  local source = plain_head .. "local t = { id = 1, n = 2 }\nlocal r: R = t\nprint(r)\n"
  local e = one_error(source, "readonly_literal", 6, 14)
  assert(e.key == "id" and e.subject == "R" and e.variable == "t", shown(source))
  assert(e.fields == nil, shown(source))
  assert(teal.replacement(e, source) == "`t` is a table made without the type `R`, so another reference could " ..
      "write `R`'s read-only field `id`: give the literal the type where it is made (`local t: R = {...}`)",
    tostring(teal.replacement(e, source)))
end

local function test_an_argument_and_a_return_made_without_the_type_are_refused()
  local call = plain_head .. "local function f(_x: R) end\nlocal t = { id = 1, n = 2 }\nf(t)\n"
  local e = one_error(call, "readonly_literal", 7, 3)
  assert(e.variable == "t" and e.subject == "R", shown(call))
  local ret = plain_head .. "local t = { id = 1, n = 2 }\nlocal function g(): R\n  return t\nend\nprint(g)\n"
  e = one_error(ret, "readonly_literal", 7, 10)
  assert(e.variable == "t" and e.key == "id", shown(ret))
end

local function test_a_table_made_without_the_type_written_to_a_record_field_is_refused()
  local source = "local record R\n  readonly id: integer\nend\nlocal record P\n  r: R\nend\n" ..
    "local t = { id = 1 }\nlocal p: P = { r = { id = 2 } }\np.r = t\n"
  local e = one_error(source, "readonly_literal", 9, 2)
  assert(e.subject == "R" and e.key == "id", shown(source))
  assert(tostring(teal.replacement(e, source)):find("give the literal the type `R` where it is made", 1, true) ~= nil)
  local inside = "local record R\n  readonly id: integer\nend\nlocal record P\n  r: R\nend\n" ..
    "local t = { id = 1 }\nlocal p: P = { r = t }\n"
  one_error(inside, "readonly_literal", 8, 16)
end

local function test_a_table_made_without_the_type_reaches_a_union_and_a_nested_table()
  local union = plain_head .. "local t = { id = 1, n = 2 }\nlocal r: R | nil = t\nprint(r)\n"
  one_error(union, "readonly_literal", 6, 20)
  local nested = "local record R\n  readonly id: integer\nend\nlocal record P\n  r: R\nend\n" ..
    "local o = { r = { id = 1 } }\nlocal p: P = o\nprint(p)\n"
  local e = one_error(nested, "readonly_literal", 8, 14)
  assert(e.subject == "R", shown(nested))
end

local function test_a_literal_checked_against_the_record_is_the_record()
  local source = plain_head .. "local r: R = { id = 1, n = 2 }\n" ..
    "local function f(x: R): R\n  print(x)\n  return { id = 3, n = 4 }\nend\n" ..
    "f({ id = 5, n = 6 })\n" ..
    "local record P\n  r: R\n  rs: {R}\nend\n" ..
    "local p: P = { r = { id = 7, n = 8 }, rs = { { id = 9, n = 1 } } }\n" ..
    "p.r = { id = 2, n = 3 }\nlocal q: R | nil = { id = 4, n = 5 }\nprint(r, q)\n"
  assert(shown(source) == "", shown(source))
end

local function test_a_table_made_without_a_type_of_a_record_with_no_read_only_field_is_unaffected()
  local source = "local record W\n  id: integer\n  n: integer\nend\n" ..
    "local t = { id = 1, n = 2 }\nlocal w: W = t\nw.id = 3\nlocal function f(_x: W) end\nf(t)\nprint(w)\n"
  assert(shown(source) == "", shown(source))
end

local function test_a_table_made_without_a_type_stays_writable_as_what_it_is()
  local source = "local t = { id = 1 }\nt.id = 2\nlocal u = t\nu.id = 3\nprint(t, u)\n"
  assert(shown(source) == "", shown(source))
end

local function test_several_read_only_fields_are_told_together()
  local source = "local record R\n  readonly a: integer\n  readonly b: integer\nend\n" ..
    "local t = { a = 1, b = 2 }\nlocal r: R = t\nprint(r)\n"
  local e = one_error(source, "readonly_literal", 6, 14)
  local listed = e.fields or {}
  assert(e.key == "a" and #listed == 2 and listed[2] == "b", shown(source))
  assert(teal.replacement(e, source) == "`t` is a table made without the type `R`, so another reference could " ..
      "write `R`'s read-only fields `a`, `b`: give the literal the type where it is made (`local t: R = {...}`)",
    tostring(teal.replacement(e, source)))
end

local function test_a_literal_must_give_every_read_only_field()
  local source = plain_head .. "local r: R = { n = 2 }\nprint(r)\n"
  local e = one_error(source, "readonly_missing", 5, 14)
  assert(e.key == "id" and e.subject == "R" and e.fields == nil, shown(source))
  assert(e.msg:find("omits read-only field 'id' of record R", 1, true) ~= nil, e.msg)
  assert(teal.replacement(e, source) == "field `id` of `R` is read-only, so only this literal can give it a " ..
      "value: add it to the literal, or declare it optional (`readonly id?: ...`) if it may be absent",
    tostring(teal.replacement(e, source)))
end

local function test_a_missing_read_only_field_is_refused_in_each_position()
  local record = "local record R\n  readonly id: integer\nend\n"
  one_error(record .. "local function f(_x: R) end\nf({})\n", "readonly_missing", 5, 3)
  one_error(record .. "local function g(): R\n  return {}\nend\nprint(g)\n", "readonly_missing", 5, 10)
  one_error(record .. "local record P\n  r: R\nend\nlocal p: P = { r = {} }\nprint(p)\n", "readonly_missing", 7, 20)
end

local function test_several_missing_read_only_fields_are_told_together()
  local source = "local record R\n  readonly a: integer\n  readonly b: string\n  n: integer\nend\n" ..
    "local r: R = { n = 1 }\nprint(r)\n"
  local e = one_error(source, "readonly_missing", 6, 14)
  local listed = e.fields or {}
  assert(e.key == "a" and #listed == 2 and listed[2] == "b", shown(source))
  assert(tostring(teal.replacement(e, source)):find("fields `a`, `b` of `R` are read-only", 1, true) ~= nil,
    tostring(teal.replacement(e, source)))
end

local function test_an_optional_read_only_field_may_be_left_out()
  local source = "local record R\n  readonly id?: integer\n  n: integer\nend\n" ..
    "local a: R = { n = 1 }\nlocal b: R = { id = 2, n = 1 }\nprint(a, b)\n"
  assert(shown(source) == "", shown(source))
  assert(shown(source .. "a.id = 3\n"):find("readonly_field", 1, true) ~= nil, shown(source .. "a.id = 3\n"))
end

local function test_a_read_only_function_field_must_be_given_too()
  local source = "local record R\n  readonly cb: function()\n  n: integer\nend\n" ..
    "local r: R = { n = 1 }\nprint(r)\n"
  local e = one_error(source, "readonly_missing", 5, 14)
  assert(e.key == "cb", shown(source))
  local given = "local record R\n  readonly cb: function()\nend\nlocal r: R = { cb = function() end }\nprint(r)\n"
  assert(shown(given) == "", shown(given))
end

local function test_a_missing_field_without_readonly_keeps_its_message()
  local source = "local record W\n  id: integer\nend\nlocal w: W = {}\nprint(w)\n"
  local errors = type_errors(source)
  assert(#errors == 1 and errors[1].code ~= "readonly_missing", shown(source))
  assert(errors[1].msg:find("table literal omits field(s) of record W", 1, true) ~= nil, errors[1].msg)
end

--- The first error's code, with the count of errors held to one.
local function only_code(source: string): string
  local errors = type_errors(source)
  assert(#errors == 1, shown(source))
  return tostring(errors[1].code)
end

local function test_an_assignment_names_the_held_table_never_its_target()
  local record = plain_head .. "local r: R = { id = 0, n = 0 }\nlocal t = { id = 1, n = 2 }\n"
  local source = record .. "r = t\nprint(r)\n"
  local e = one_error(source, "readonly_literal", 7, 1)
  assert(e.variable == nil, shown(source))
  local hint = tostring(teal.replacement(e, source))
  assert(hint:find("this table is made without the type `R`", 1, true) ~= nil, hint)
  assert(hint:find("`local r", 1, true) == nil and hint:find("`r`", 1, true) == nil, hint)
  local either = record .. "r = r or t\nprint(r)\n"
  e = one_error(either, "readonly_literal", 7, 1)
  assert(e.variable == nil, shown(either))
  local field = "local record R\n  readonly id: integer\nend\nlocal record P\n  r: R\nend\n" ..
    "local p: P = { r = { id = 1 } }\nlocal t = { id = 2 }\np.r = t\n"
  e = one_error(field, "readonly_literal", 9, 2)
  assert(e.variable == nil, shown(field))
end

local function test_the_hint_without_a_held_table_suggests_a_typed_local_or_an_expected_type()
  local source = plain_head .. "local r: R = { id = 0, n = 0 }\nlocal t = { id = 1, n = 2 }\nr = t\n"
  local e = one_error(source, "readonly_literal", 7, 1)
  assert(teal.replacement(e, source) == "this table is made without the type `R`, so another reference could " ..
      "write `R`'s read-only field `id`: give the literal the type `R` where it is made (e.g. `local x: R = " ..
      "{...}`, or pass it where a `R` is expected)", tostring(teal.replacement(e, source)))
end

--- A literal element of an array, map or tuple written where `{R}` is wanted
--- is held to `R`: a table made without the type carries the code, a plain
--- variable holding the whole array gets a plain mismatch.
local function test_arrays_and_maps_of_tables_made_without_the_type()
  local t = plain_head .. "local t = { id = 1, n = 2 }\n"
  assert(only_code(t .. "local xs: {R} = { t }\nprint(xs)\n") == "readonly_literal")
  assert(only_code(t .. "local xs: {string:R} = { a = t }\nprint(xs)\n") == "readonly_literal")
  local tuple = type_errors(t .. "local xs: {R, R} = { t, t }\nprint(xs)\n")
  assert(#tuple == 2 and tuple[1].code == "readonly_literal" and tuple[2].code == "readonly_literal", shown(t))
  assert(shown(plain_head .. "local xs: {R} = { { id = 1, n = 2 } }\n" ..
      "local ms: {string:R} = { a = { id = 1, n = 2 } }\nprint(xs, ms)\n") == "")
  local whole = t .. "local ys = { t }\nlocal zs: {R} = ys\nprint(zs)\n"
  assert(only_code(whole) == "mismatch", shown(whole))
end

--- A literal passed to an overloaded generic function has no expected type.
--- Pins that, with the TODO at the overload branch of the call's visitor.
local function test_a_literal_passed_to_table_insert_is_made_without_the_type()
  local source = plain_head .. "local rs: {R} = {}\ntable.insert(rs, { id = 1, n = 2 })\n"
  assert(only_code(source) == "readonly_literal", shown(source))
end

local function test_a_table_handed_to_setmetatable_is_refused()
  local source = "local record C\n  readonly id: integer\n  metamethod __index: function(C, string): any\nend\n" ..
    "local mt: metatable<C> = {}\nlocal function new(id: integer): C\n  local self = { id = id }\n" ..
    "  return setmetatable(self, mt)\nend\nprint(new)\n"
  assert(shown(source):find("readonly_literal", 1, true) ~= nil, shown(source))
  local typed = source:gsub("local self = ", "local self: C = ")
  assert(shown(typed) == "", shown(typed))
end
