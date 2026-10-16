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
  local out: {string} = {}
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
    built.path = ""
    built.search_module = function(name: string, _all: boolean): string | nil, any
      if name ~= "ro" then
        return nil
      end
      return "ro.tl", {
        read = function(_self: any, _what: string): string return text end,
        close = function(_self: any): boolean return true end,
      }
    end
    local env = assert(built.new_env({
      defaults = { feat_lax = "off", gen_compat = "off", gen_target = "5.4" },
    }))
    teal.strip(env)
    local result = built.check_string(program, env, "app.tl", "tl")
    local out: {string} = {}
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
