--- Tests of [`build.syntax_places`]: where a source declares its types and their members.
local Ast = require("lang.ast")
local Node = require("build.syntax_node")
local Places = require("build.syntax_places")
local Test = require("cosmic.test")

Test.policy{}

--- The places `source` declares, as `symbol kind line:column+length`, in the order they are looked up in.
local function found(source: string, name?: string): {string}
  local file = name or "m.tl"
  local chunk, why = Node.parse(source, file)
  local out: mut {string} = {}
  for _, place in ipairs(Places.found((assert(chunk, why)))) do
    out[#out + 1] = place.symbol .. " " .. place.kind .. " " .. tostring(place.line) .. ":" .. tostring(place.column) ..
      "+" .. tostring(place.length)
  end
  return out
end

--- Asserts that the places of `source` are exactly `want`.
local function assert_found(source: string, want: {string}, name?: string)
  local got = table.concat(found(source, name), "\n")
  assert(got == table.concat(want, "\n"), got)
end

local function test_a_record_its_fields_and_its_nested_types_are_found_by_their_dotted_path()
  assert_found(table.concat({
    "local record R",
    "  n: integer",
    "  record Inner",
    "    deep: string",
    "  end",
    "  enum Kind",
    '    "a"',
    "  end",
    "end",
    "return R",
    "",
  }, "\n"), {
    "R type 1:14+1",
    "R.n field 2:3+1",
    "R.Inner type 3:10+5",
    "R.Inner.deep field 4:5+4",
    "R.Kind type 6:8+4",
    "R.Kind.a value 7:5+3",
  })
end

local function test_a_class_gives_its_methods_and_an_interface_its_fields()
  assert_found(table.concat({
    "local class Counter",
    "  n: integer",
    "  function bump(self): integer",
    "    return self.n + 1",
    "  end",
    "end",
    "local interface Named",
    "  name: string",
    "end",
    "local type Alias = Counter",
    "return Counter",
    "",
  }, "\n"), {
    "Counter type 1:13+7",
    "Counter.n field 2:3+1",
    "Counter.bump method 3:12+4",
    "Named type 7:17+5",
    "Named.name field 8:3+4",
    "Alias type 10:12+5",
  })
end

local function test_a_function_statement_is_found_after_the_members_it_adds_to()
  assert_found(table.concat({
    "function R.late(): integer return 1 end",
    "local record R",
    "  early: integer",
    "end",
    "function R.make(): R return { early = 1 } end",
    "local function helper() end",
    "return R",
    "",
  }, "\n"), {
    "R type 2:14+1",
    "R.early field 3:3+5",
    "R.late function 1:12+4",
    "R.make function 5:12+4",
  })
end

local function test_a_member_and_a_function_of_one_name_are_found_member_first()
  local got = found("local record R\n  f: integer\nend\nfunction R.f(): integer return 1 end\nreturn R\n")
  assert(got[2] == "R.f field 2:3+1" and got[3] == "R.f function 4:12+1", table.concat(got, "\n"))
end

local function test_types_and_functions_in_a_do_block_have_their_path_from_the_block()
  assert_found(table.concat({
    "do",
    "  local record Hidden",
    "    x: integer",
    "  end",
    "  function Hidden.make(): Hidden return { x = 1 } end",
    "end",
    "local record Open",
    "end",
    "",
  }, "\n"), {
    "Hidden type 2:16+6",
    "Hidden.x field 3:5+1",
    "Open type 7:14+4",
    "Hidden.make function 5:19+4",
  })
end

local function test_a_declaration_file_and_an_import_are_read_the_same_way()
  assert_found(table.concat({
    "local type Stream = require(\"cosmic.stream\")",
    "local record Reader",
    "  fd: integer",
    "end",
    "return Reader",
    "",
  }, "\n"), {
    "Stream type 1:12+6",
    "Reader type 2:14+6",
    "Reader.fd field 3:3+2",
  })
  assert_found("global record Box\n  n: integer\nend\nglobal print: any\n", {
    "Box type 1:15+3",
    "Box.n field 2:3+1",
  }, "std.d.tl")
end

local function test_a_column_counts_bytes_after_multibyte_text_on_the_line()
  -- "é" is two bytes, so the name after it is at byte 29 of its line and not at character 28.
  assert_found('local s = "é" local record R\n  n: integer\nend\nreturn R, s\n', { "R type 1:29+1", "R.n field 2:3+1" })
end

local function test_a_source_with_no_declaration_has_no_places()
  assert_found("local x = 1\nlocal function f() return x end\nreturn f\n", {})
  assert_found("global print: any\n", {}, "std.d.tl")
end

--- The places `source` declares within the type whose node has the id of the `nth` record, as `found` writes them.
local function within(source: string, nth: integer): {string}
  local parsed, why = Node.parse(source, "m.tl")
  local chunk = assert(parsed, why)
  local ids: mut {integer} = {}
  local pending: mut {Ast.Node} = { chunk }
  while #pending > 0 do
    local node = assert(pending[#pending])
    pending[#pending] = nil
    if node.kind == "Record" then ids[#ids + 1] = node.id end
    Ast.children(node, function(child: Ast.Node) pending[#pending + 1] = child end)
  end
  table.sort(ids)
  local out: mut {string} = {}
  local id = ids[nth]
  assert(id ~= nil, "no such record")
  for _, place in ipairs(Places.within(chunk, id)) do
    out[#out + 1] = place.symbol .. " " .. place.kind .. " " .. tostring(place.line)
  end
  return out
end

local function test_a_type_in_a_function_body_is_found_by_its_node_apart_from_one_of_its_name()
  local source = table.concat({
    "local function a() local record P x: integer end function P.f() end return 1 end",
    "local function b() local record P y: integer enum K \"v\" end end return 2 end",
    "return a, b",
    "",
  }, "\n")
  assert(table.concat(within(source, 1), ",") == "P type 1,P.x field 1,P.f function 1", table.concat(within(source, 1), ","))
  assert(table.concat(within(source, 2), ",") == "P type 2,P.y field 2,P.K type 2,P.K.v value 2",
    table.concat(within(source, 2), ","))
end

--- The `plain` flags of the places of `source`, as `symbol flag`, in order; with `blind` the text is not given.
local function flags(source: string, blind?: boolean): string
  local chunk, why = Node.parse(source, "m.tl")
  local out: mut {string} = {}
  local given: string? = source
  if blind == true then given = nil end
  for _, place in ipairs(Places.found((assert(chunk, why)), given)) do
    out[#out + 1] = place.symbol .. " " .. tostring(place.plain)
  end
  return table.concat(out, ";")
end

local function test_a_place_is_plain_where_its_line_holds_only_ascii_and_the_protocol_numbers_it_as_the_lexer_does()
  assert(flags('local s = "é" local record R\n  n: integer\nend\nreturn R, s\n') == "R false;R.n true")
  assert(flags("local record R\n  n: integer\nend\nreturn R\n") == "R true;R.n true")
  -- The lexer counts "\n\r" as one break and the protocol as two: the lines after it are numbered another way.
  assert(flags("-- a\n\rlocal record R\n  n: integer\nend\nreturn R\n") == "R false;R.n false")
  assert(flags("local record R\n  n: integer\nend\n-- a\n\rlocal x = 1\nreturn R\n") == "R true;R.n true")
  assert(flags("local record R\r\n  n: integer\r\nend\r\nreturn R\r\n") == "R true;R.n true")
  assert(flags("local record R\n  n: integer\nend\nreturn R\n", true) == "R false;R.n false", "no text, no flag")
  -- An enum's values are places too.
  assert(flags('local enum K\n  "v"\nend\nlocal s = "é" local enum L "w" end\nreturn K, L, s\n') == "K true;K.v true;L false;L.w false")
end
