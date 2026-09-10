#!/usr/bin/env cosmic
local check = require("cosmic.check")
local scanner = require("_tool.surface_scan")
local url = require("cosmic.url")

local function members(source: string): {scanner.Member}
  return check.must(scanner.scan(source, "surface.tl"))
end

local function refused(source: string)
  local result, err = scanner.scan(source, "broken.tl")
  check.equal(result, nil, "failure must never return partial members")
  check.truthy(err:find("broken.tl:", 1, true), err)
end

local function test_top_level_and_locations()
  local found = members("local record R\n  value: string -- comment\nend\n" ..
    "global enum Choice\n  'yes'\nend")
  check.equal(#found, 2)
  check.equal(found[1].kind, "record")
  check.equal(found[1].declaration, "R")
  check.equal(found[1].name, "value")
  check.equal(found[1].canonical_type, "string")
  check.equal(found[1].line, 2)
  check.equal(found[1].column, 3)
  check.equal(found[2].kind, "enum")
  check.equal(found[2].declaration, "Choice")
  check.equal(found[2].canonical_type, "enum")
  check.equal(found[2].line, 5)
  check.equal(found[2].column, 3)
end

local function test_nested_declarations_keep_owners()
  local found = members([[local record Outer
  before: integer
  record Inner
    value: string
    enum Color
      "red"
    end
  end
  after: boolean
end]])
  check.equal(#found, 4)
  check.equal(found[1].declaration, "Outer")
  check.equal(found[2].declaration, "Outer.Inner")
  check.equal(found[3].declaration, "Outer.Inner.Color")
  check.equal(found[4].name, "after")
  check.equal(found[4].declaration, "Outer")
end

local function test_multiline_function_fields()
  local found = members([[local record R
  bare: function
  visit: function<T>(value: T,
    callback: function(): string):
    T | nil,
    string -- trailing return comment
  next: boolean
end]])
  check.equal(#found, 3)
  check.equal(found[1].canonical_type, "function")
  check.equal(found[2].canonical_type,
    "function < T > ( value : T , callback : function ( ) : string ) : T | nil , string")
  check.equal(found[3].name, "next")
end

local function test_balanced_generic_table_and_tuple_types()
  local found = members([[local record R<T>
  generic: Box<Box<T>>
  table: {string:
    {integer, string}}
  tuple: function(): (string, integer)
  union: string
    | nil
end]])
  check.equal(#found, 4)
  check.equal(found[1].canonical_type, "Box < Box < T >>")
  check.equal(found[2].canonical_type, "{ string : { integer , string } }")
  check.equal(found[3].canonical_type, "function ( ) : ( string , integer )")
  check.equal(found[4].canonical_type, "string | nil")
end

local function test_enum_spellings_and_reversible_bytes()
  local found = members([==[local enum E
  'a/b'
  "a\x2fb"
  [=[a/b]=]
  "\000%+ \u{e9}"
  ""
end]==])
  check.equal(#found, 5)
  check.equal(found[1].name, "a%2Fb")
  check.equal(found[2].name, found[1].name)
  check.equal(found[3].name, found[1].name)
  check.equal(check.must(url.unescape(found[4].name)), "\000%+ é")
  check.equal(found[5].name, "")
end

local function test_long_literal_normalizes_newlines()
  local found = members("local enum E\n[=[\r\na\r\nb]=]\nend")
  check.equal(check.must(url.unescape(found[1].name)), "a\nb")
end

local function test_non_declaration_tokens_and_function_bodies()
  local found = members([==[local record R
  record: string
  enum: function(): string
end
local function f(callback: function(): string): string
  local value = "local record Fake x: string end"
  -- local enum Fake "no" end
  return callback() .. value
end
local enum E "real" end]==])
  check.equal(#found, 3)
  check.equal(found[2].name, "enum")
  check.equal(found[3].name, "real")
end

local function test_identifier_values_are_not_declarations()
  local found = members([[local record = 1
local enum: string = "value"
local t = {record = record, enum = enum}
local result = t.record
print(result)]])
  check.equal(#found, 0)
end

local function test_literal_fields_and_record_headers()
  local found = members([==[local record R<T> is {T}, Base<T>
  userdata
  ["some\x2fname"]: string
  userdata: boolean
end]==])
  check.equal(#found, 2)
  check.equal(found[1].name, "some/name")
  check.equal(found[1].line, 3)
  check.equal(found[1].column, 3)
  check.equal(found[2].name, "userdata")
end

local function test_record_metamethods()
  local found = members([[local record Handle
  metamethod __close: function(self: Handle)
  metamethod ["__tostring"]: function(self: Handle): string
  metamethod: string
  pid: integer
end]])
  check.equal(#found, 4)
  check.equal(found[1].kind, "record")
  check.equal(found[1].declaration, "Handle")
  check.equal(found[1].name, "__close")
  check.equal(found[1].canonical_type, "function ( self : Handle )")
  check.equal(found[1].line, 2)
  check.equal(found[1].column, 14)
  check.equal(found[2].name, "__tostring")
  check.equal(found[2].canonical_type, "function ( self : Handle ) : string")
  check.equal(found[3].name, "metamethod")
  check.equal(found[4].name, "pid")
end

local function test_atomic_failures()
  for _, bad in ipairs({
      "local record R x: string end\n@",
      "local enum E 'unterminated",
      "local record R x: string",
      "local record R record Inner x: string end",
      "local record R x: {string) end",
      "local record R x: Box<string end",
      "local record R x: string | end",
      "local record R x: function(): string, end",
      "local record R x: string y = 1 end",
      "local record R type Alias = string end",
    }) do
    refused(bad)
  end
end

local function test_empty_source_and_empty_declarations()
  check.equal(#members("-- record R\n"), 0)
  check.equal(#members("local record R end\nlocal enum E end"), 0)
end
