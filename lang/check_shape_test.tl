--- A record type written in braces (`{a: A, b: B}`, [`lang.types`]'s `shape`): two or more fields make a record, one
--- pair stays a map, and two written with the same fields are one type, in any order and in any module. A table literal
--- is held to it as to a declared record, and its fields are fixed.
local Programs = require("lang.check_programs")
local Test = require("cosmic.test")

Test.policy{}

--- The codes of what `source` is refused for, space separated: "" for none.
local function codes(source: string, modules?: {string: string}): string
  return Programs.codes(Programs.run(source, modules))
end

--- The message and fix of the first error of `source`.
local function first(source: string): string
  local r = Programs.run(source)
  local e = assert(r.errors[1], "no error in\n" .. source)
  return e.msg .. "\n" .. e.fix
end

local function test_a_literal_fits_the_record_its_braces_write()
  assert(codes("local p: {n: integer, name: string} = { n = 1, name = \"a\" }\nlocal _ = p.name .. tostring(p.n)\n") == "")
  assert(codes("local p: {n: integer, name?: string} = { n = 1 }\nlocal _: string? = p.name\n") == "")
  assert(codes("local ps: {{x: number, y: number}} = { { x = 1, y = 2 } }\nlocal _ = ps[1]\n") == "")
end

local function test_a_literal_is_held_to_each_field()
  assert(codes("local p: {n: integer, name: string} = { n = 1 }\nlocal _ = p\n") == "literal_missing")
  assert(codes("local p: {n: integer, name: string} = { n = 1, name = \"a\", more = 2 }\nlocal _ = p\n") ==
      "literal_unknown")
  assert(codes("local p: {n: integer, name: string} = { n = \"1\", name = \"a\" }\nlocal _ = p\n") == "not_assignable")
  local said = first("local p: {n: integer, name: string} = { n = 1 }\nlocal _ = p\n")
  assert(said:find("`{ n: integer, name: string }`", 1, true) ~= nil, said)
end

local function test_two_written_alike_are_one_type()
  local source = "local function f(p: {x: number, y: number}): number\n  return p.x + p.y\nend\n" ..
    "local q: {y: number, x: number} = { x = 1, y = 2 }\nlocal _ = f(q)\n"
  assert(codes(source) == "", codes(source))
  local spelled = "local ps: mut {{a?: integer, b: string}} = {}\nlocal qs: mut {{b: string, a?: integer?}} = ps\n" ..
    "local _ = qs\n"
  assert(codes(spelled) == "", codes(spelled))
end

--- One in braces is below another as a literal of its fields is: each field below the other's, and none more.
local function test_one_in_braces_is_below_another_by_its_fields()
  local narrower = "local function f(p: {x: number, y: number}): number\n  return p.x\nend\n" ..
    "local q: {x: number, y: integer} = { x = 1, y = 2 }\nlocal _ = f(q)\n"
  assert(codes(narrower) == "", codes(narrower))
  local optional = "local q: {x: number, y: integer} = { x = 1, y = 2 }\nlocal p: {x: number, y?: number} = q\nlocal _ = p\n"
  assert(codes(optional) == "", codes(optional))
  local more = "local q: {x: number, y: number, z: number} = { x = 1, y = 2, z = 3 }\n" ..
    "local p: {x: number, y: number} = q\nlocal _ = p\n"
  assert(codes(more) == "not_assignable", codes(more))
  local missing = "local q: {x: number, y?: number} = { x = 1 }\nlocal p: {x: number, y: number} = q\nlocal _ = p\n"
  assert(codes(missing) == "not_assignable", codes(missing))
  local map = "local q: {x: integer, y: integer} = { x = 1, y = 2 }\nlocal m: {string: integer} = q\nlocal _ = m\n"
  assert(codes(map) == "", codes(map))
  local read = "local q: {x: integer, y: integer} = { x = 1, y = 2 }\nlocal k = \"x\" .. \"\"\nlocal _: integer? = q[k]\n"
  assert(codes(read) == "", codes(read))
end

--- Braces that name a module's record go with that module when it is checked again.
local function test_braces_over_a_record_of_the_module_are_checked_again()
  local function of(x: string, value: string): string
    return "local record Pt\n  x: " .. x .. "\nend\nlocal p: {at: Pt, n: integer} = { at = { x = " .. value .. " }, n = 2 }\n" ..
      "local q: {p: {at: Pt, n: integer}, m: integer} = { p = p, m = 1 }\nlocal _ = q\n"
  end
  assert(codes(of("number", "1")) == "", codes(of("number", "1")))
  assert(codes(of("string", "\"a\"")) == "", codes(of("string", "\"a\"")))
  assert(codes(of("number", "\"a\"")) == "not_assignable", codes(of("number", "\"a\"")))
end

--- A literal not written against a type is held to the record by its fields, as it is to a declared one.
local function test_an_untyped_literal_fits_by_its_fields()
  assert(codes("local function f(p: {x: number, y: number}): number\n  return p.x\nend\n" ..
      "local t = { x = 1.0, y = 2.0 }\nlocal _ = f(t)\n") == "")
end

--- A declared record is a type of its own, which the braces with its fields are not.
local function test_a_declared_record_is_not_its_shape()
  local source = "local record R\n  x: number\n  y: number\nend\nlocal r: R = { x = 1, y = 2 }\n" ..
    "local p: {x: number, y: number} = r\nlocal _ = p\n"
  assert(codes(source) == "not_assignable", codes(source))
end

local function test_its_fields_are_fixed()
  local source = "local p: {n: integer, name: string} = { n = 1, name = \"a\" }\np.n = 2\n"
  assert(codes(source) == "field_fixed", codes(source))
  assert(first(source):find("in place of the braces", 1, true) ~= nil)
  local indexed = "local p: {n: integer, name: string} = { n = 1, name = \"a\" }\np[\"n\"] = 2\n"
  assert(codes(indexed) == "field_fixed", codes(indexed))
  assert(first(indexed):find("in place of the braces", 1, true) ~= nil, first(indexed))
  local unknown = "local p: {n: integer, name: string} = { n = 1, name = \"a\" }\nlocal _ = p.size\n"
  assert(codes(unknown) == "field_unknown", codes(unknown))
  assert(first(unknown):find("to the braces of `{ n: integer, name: string }`", 1, true) ~= nil, first(unknown))
end

local function test_one_pair_is_a_map()
  assert(codes("local m: mut {string: integer} = {}\nm[\"a\"] = 1\nlocal _: integer? = m[\"b\"]\n") == "")
  assert(codes("local m: {string: integer} = { a = 1 }\nlocal _: integer? = m[\"a\"]\n") == "")
  local wrong = "local m: {string: integer} = { a = \"1\" }\nlocal _ = m\n"
  assert(codes(wrong) ~= "" and not codes(wrong):find("literal_", 1, true), codes(wrong))
  assert(codes("local m: {string: integer,} = { a = 1 }\nlocal _ = m\n") == "")
  local named = "local r: {string: integer, number: integer} = { string = 1, number = 2 }\nlocal _: integer = r.string\n"
  assert(codes(named) == "", codes(named))
end

local function test_a_type_parameter_is_refused_in_the_braces()
  local r = Programs.run("local function f<T>(x: {a: T, b: integer}): T\n  return x.a\nend\nlocal _ = f\n")
  assert(table.concat(r.before, " ") == "shape_generic", table.concat(r.before, " "))
end

--- One module's braces are another's: a function of a module that takes and returns them meets the braces of its caller.
local function test_the_braces_of_two_modules_are_one_type()
  local geo = "local record Geo\n  dist: function(a: {x: number, y: number}): number\n" ..
    "  origin: function(): {y: number, x: number}\nend\n" ..
    "function Geo.dist(a: {x: number, y: number}): number\n  return a.x + a.y\nend\n" ..
    "function Geo.origin(): {y: number, x: number}\n  return { x = 0, y = 0 }\nend\nreturn Geo\n"
  local source = "local Geo = require(\"geo\")\nlocal p: {x: number, y: number} = Geo.origin()\nlocal _ = Geo.dist(p)\n"
  assert(codes(source, { geo = geo }) == "", codes(source, { geo = geo }))
end
