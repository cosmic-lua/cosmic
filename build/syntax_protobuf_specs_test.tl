--- [`build.syntax_protobuf_specs`] over small projects: the functions a compile splices into [`Schema.message_of`] and
--- [`Schema.enum_of`], and what it refuses, by field. [`cosmic.protobuf.schema`]'s tests run what is written.
local ProtobufSpecs = require("build.syntax_protobuf_specs")
local RecordCalls = require("build.syntax_record_calls")
local Fixture = require("build.syntax_resolver_fixture")
local Test = require("cosmic.test")

Test.policy{}

--- The schema module, as far as a call's name and a field of `Unknown` need it.
local STANDARD <const>: {string: string} = {
  ["cosmic.protobuf.schema"] = "local record Schema\n  record Unknown\n  end\nend\nreturn Schema\n",
}

--- The module `main` with its calls resolved, or nil and the refusal.
local function resolved(main: string): string?, string
  local found = ProtobufSpecs.splices(Fixture.build_of({ ["main.tl"] = main }, STANDARD), "main", "main.tl", main)
  if found.refusal ~= "" then return nil, found.refusal end
  return RecordCalls.spliced(main, found.splices), ""
end

--- A module that declares `declarations` and ends in `call`.
local function module_of(declarations: string, call: string): string
  return table.concat({
    'local Schema = require("cosmic.protobuf.schema")',
    declarations,
    "local C = " .. call,
    "return C",
    "",
  }, "\n")
end

local function has(source: string?, why: string, want: string)
  assert(source ~= nil, why)
  assert(source:find(want, 1, true) ~= nil, ("the source does not hold %s:\n%s"):format(want, source))
end

--- The refusal of `call` over `declarations` holds `reason`, at the call's line.
local function refused(declarations: string, call: string, reason: string)
  local source, trouble = resolved(module_of(declarations, call))
  assert(source == nil, "the build accepted a call it cannot write:\n" .. tostring(source))
  assert(trouble:find("main.tl:", 1, true) == 1, trouble)
  assert(trouble:find(reason, 1, true) ~= nil, ("%q not said in: %s"):format(reason, trouble))
end

local RECORD <const> = table.concat({
  'local enum Kind "a" "b" end',
  "local record Inner",
  "  n: integer",
  "end",
  "local record R",
  "  id: integer",
  "  name?: string",
  "  ratio?: number",
  "  on?: boolean",
  "  kind?: Kind",
  "  inner?: Inner",
  "  sizes: {integer}",
  "  kids: {R}",
  "end",
  'local KIND = Schema.enum_of("Kind", { a = 0, b = -1 }, function(n: integer?): Kind? return nil end, ' ..
    "function(v: Kind): integer return 0 end)",
  'local INNER = Schema.message_of("Inner", { n = 1 }, function(v: Inner): string?, string return "", "" end, ' ..
    "function(m: Schema.Message): Inner?, string return nil, m end)",
}, "\n")

local FIELDS <const> = "{ id = 1, name = Schema.string(2), ratio = Schema.float(3), on = 4, " ..
  "kind = Schema.enum(5, KIND), inner = Schema.message(6, INNER), sizes = Schema.field(7, { packed = true }), " ..
  "kids = Schema.self(8) }"

local function test_each_field_is_written_and_read_by_its_kind()
  local source, why = resolved(module_of(RECORD, 'Schema.message_of("R", ' .. FIELDS .. ")"))
  has(source, why, "function pb_write(pb_v: R): string?, string")
  has(source, why, "function pb_read(pb_m: Schema.Message): R?, string")
  has(source, why, 'Schema.build.put_int(pb_o, 1, pb_v.id)')
  has(source, why, 'Schema.build.put_string(pb_o, 2, pb_v.name)')
  has(source, why, 'Schema.build.put_float(pb_o, 3, pb_v.ratio)')
  has(source, why, 'Schema.build.put_enum(pb_o, 5, pb_v.kind, KIND.number)')
  has(source, why, 'Schema.build.put_message(pb_o, 6, "inner", pb_v.inner, INNER.write)')
  has(source, why, 'Schema.build.put_numbers(pb_o, 7, "int", pb_v.sizes, true)')
  has(source, why, 'Schema.build.put_messages(pb_o, 8, "kids", pb_v.kids, pb_write)')
  has(source, why, 'id = Schema.build.need(pb_r, 1, "id", pb_m:int(1), 0)')
  has(source, why, "kind = KIND.name(pb_m:int(5))")
  has(source, why, 'kids = Schema.build.messages(pb_r, 8, "kids", pb_read)')
  -- A packed field's number takes a length-delimited field too.
  has(source, why, "[7] = 8")
  has(source, why, '[7] = "sizes"')
end

local function test_what_is_written_stays_on_the_calls_line()
  local main = module_of(RECORD, 'Schema.message_of("R", ' .. FIELDS .. ")")
  local source = assert(resolved(main))
  local _, before = main:gsub("\n", "\n")
  local _, after = source:gsub("\n", "\n")
  assert(before == after, "a splice adds no line, so the lines a message names do not move")
end

local function test_a_call_that_has_its_functions_is_left_as_it_is()
  local main = module_of(RECORD, "INNER")
  assert(resolved(main) == main)
end

local function test_an_enum_is_written_by_number_and_by_name()
  local source, why = resolved(module_of('local enum Kind "a" "b" end', 'Schema.enum_of("Kind", { a = 0, b = -1 })'))
  has(source, why, 'function(pb_n: integer?): Kind? if pb_n == 0 then return "a" end if pb_n == -1 then return "b" end')
  has(source, why, 'function(pb_v: Kind): integer if pb_v == "a" then return 0 end return -1 end')
end

local function test_an_enum_is_refused_by_what_its_numbers_lack()
  local declared = 'local enum Kind "a" "b" end'
  refused(declared, 'Schema.enum_of("Kind", { a = 1 })', "b: the value has no number")
  refused(declared, 'Schema.enum_of("Kind", { a = 1, b = 2, c = 3 })', "c: the enum has no such value")
  refused(declared, 'Schema.enum_of("Kind", { a = 1, b = 1 })', "number 1 is a's too")
  refused(declared, 'Schema.enum_of("Kind", { a = 1, b = "x" })', "each value is written `Name = number`")
  refused("local record Kind\nend", 'Schema.enum_of("Kind", {})', "it is no enum")
end

local function test_a_message_is_refused_by_field()
  local one = "local record R\n  id: integer\n  name?: string\nend"
  refused(one, 'Schema.message_of("R", { id = 1 })', "name: the field has no number")
  refused(one, 'Schema.message_of("R", { id = 1, name = 2, extra = 3 })', "extra: the record has no such field")
  refused(one, 'Schema.message_of("R", { id = 1, name = 1 })', "number 1 is id's too")
  refused(one, 'Schema.message_of("R", { id = 0, name = 2 })', "id: 0 is no field number")
  refused(one, 'Schema.message_of("R", { id = 536870912, name = 2 })', "id: 536870912 is no field number")
  refused(one, 'Schema.message_of("R", { id = Schema.float(1), name = 2 })', "id: Schema.float does not encode an integer")
  refused(one, 'Schema.message_of("R", { id = 1, name = Schema.sint(2) })', "name: Schema.sint does not encode a string")
  refused(one, 'Schema.message_of("R", { id = id_number, name = 2 })', "id: its entry must be a number")
  refused(one, 'Schema.message_of("R", { id = Schema.field(1, { packed = true }), name = 2 })',
    "id: `packed` is for a repeated field")
  refused(one, 'Schema.message_of("R", { id = 1, name = Schema.field(2, { implicit = true }) })',
    "name: `implicit` is for a field declared `f: T`")
  refused(one, 'Schema.message_of("R", { id = Schema.field(1, { loud = true }), name = 2 })', '"loud" is no option')
  refused(one, 'Schema.message_of("R", fields)', "its second argument must be a table written in the call")
  refused('local enum R "a" end', 'Schema.message_of("R", {})', "it is no record")
end

local function test_a_field_of_a_type_with_no_encoding_is_refused()
  refused("local record R\n  f: function()\nend", 'Schema.message_of("R", { f = 1 })', "f: a function has no encoding")
  refused("local record R\n  f: string | integer\nend", 'Schema.message_of("R", { f = 1 })',
    "f: a union of more than one type has no encoding")
  refused("local record R\n  f: {string: integer}\nend", 'Schema.message_of("R", { f = 1 })',
    "f: a map has no encoding yet")
  refused("local record R\n  f: {{integer}}\nend", 'Schema.message_of("R", { f = 1 })',
    "f: a list of lists has no encoding")
end

local function test_an_enum_or_a_record_field_names_its_codec()
  local declared = 'local enum Kind "a" end\nlocal record Inner\nend\nlocal record R\n  kind?: Kind\n  inner?: Inner\nend'
  refused(declared, 'Schema.message_of("R", { kind = 1, inner = 2 })', "kind: an enum's entry names its codec")
  refused(declared, 'Schema.message_of("R", { kind = Schema.enum(1, K), inner = 2 })',
    "inner: a record's entry names its codec")
  refused(declared, 'Schema.message_of("R", { kind = Schema.enum(1, K), inner = Schema.self(2) })',
    "inner: Schema.self is for a field of the record's own type")
  refused(declared, 'Schema.message_of("R", { kind = Schema.enum(1), inner = Schema.message(2, I) })',
    "kind: Schema.enum takes the codec of the field's type after its number")
end

local function test_a_record_that_keeps_takes_no_number_for_it_and_no_repeated_enum()
  local keeps = 'local enum Kind "a" end\nlocal record R\n  kinds: {Kind}\n  rest?: Schema.Unknown\nend'
  refused(keeps, 'Schema.message_of("R", { kinds = Schema.enum(1, K) })', "kinds: a repeated enum cannot keep the place")
  local numbered = "local record R\n  rest?: Schema.Unknown\nend"
  refused(numbered, 'Schema.message_of("R", { rest = 1 })', "rest: a field of Unknown takes no number")
  refused("local record R\n  rest: Schema.Unknown\nend", 'Schema.message_of("R", {})',
    "rest: a field of Unknown is optional")
  local source, why = resolved(module_of("local record R\n  id?: integer\n  rest?: Schema.Unknown\nend",
    'Schema.message_of("R", { id = 1 })'))
  has(source, why, "Schema.build.open(pb_m, pb_p, pb_e, true)")
  has(source, why, "rest = Schema.build.unknown(pb_r)")
  has(source, why, "Schema.build.close(pb_o, pb_v.rest, { [1] = pb_v.id ~= nil })")
  -- A record that keeps reads a field with no check of its wire type: `open` set the others aside.
  has(source, why, "id = pb_m:int(1)")
end

local function test_a_message_of_many_fields_is_written_with_no_local_for_each()
  local fields: mut {string} = {}
  local numbers: mut {string} = {}
  for i = 1, 300 do
    fields[i] = ("  f%d?: integer"):format(i)
    numbers[i] = ("f%d = %d"):format(i, i)
  end
  local source = assert(resolved(module_of("local record R\n" .. table.concat(fields, "\n") .. "\nend",
    'Schema.message_of("R", { ' .. table.concat(numbers, ", ") .. " })")))
  local _, locals = source:gsub("local pb_", "")
  assert(locals < 20, "the reader and the writer name a handful of locals, whatever the fields: " .. tostring(locals))
end

local function test_a_field_the_written_code_cannot_name_is_refused()
  refused('local record R\n  ["end"]: integer\nend', 'Schema.message_of("R", { ["end"] = 1 })',
    "end: a field of this name cannot be named in the code the build writes")
end

local function test_a_codec_is_named_and_not_made_in_the_entry()
  local declared = "local record Inner\nend\nlocal record R\n  inner?: Inner\nend"
  refused(declared, 'Schema.message_of("R", { inner = Schema.message(1, make()) })',
    "inner: Schema.message takes its codec by name")
  local source, why = resolved(module_of(declared, 'Schema.message_of("R", { inner = Schema.message(1, M.codecs.INNER) })'))
  has(source, why, 'Schema.build.message(pb_r, 1, "inner", M . codecs . INNER.read)')
end

local function test_two_records_that_hold_each_other_are_refused_by_name()
  local declared = "local record B\n  a?: A\nend\nlocal record A\n  b?: B\nend"
  refused(declared, 'Schema.message_of("A", { b = Schema.message(1, B_CODEC) })', "b: A and B hold each other")
end

local function test_a_reserved_number_and_an_enum_number_past_32_bits_are_refused()
  refused("local record R\n  id: integer\nend", 'Schema.message_of("R", { id = 19000 })',
    "id: 19000 is a number the format reserves")
  refused('local enum Kind "a" end', 'Schema.enum_of("Kind", { a = 2147483648 })', "a: 2147483648 is outside an enum's numbers")
end

local function test_a_record_of_many_required_messages_is_refused_and_a_record_of_none_is_written()
  local fields: mut {string} = {}
  local numbers: mut {string} = {}
  for i = 1, 151 do
    fields[i] = ("  f%d: Inner"):format(i)
    numbers[i] = ("f%d = Schema.message(%d, INNER)"):format(i, i)
  end
  refused("local record Inner\nend\nlocal record R\n" .. table.concat(fields, "\n") .. "\nend",
    'Schema.message_of("R", { ' .. table.concat(numbers, ", ") .. " })", "151 required embedded messages")
  local source, why = resolved(module_of("local record R\nend", 'Schema.message_of("R", {})'))
  has(source, why, "function pb_write(_pb_v: R): string?, string")
end

local function test_a_module_that_does_not_bind_the_schema_module_has_nothing_to_resolve()
  local main = 'local record R\nend\nlocal C = Other.message_of("R", {})\nreturn C\n'
  assert(resolved(main) == main)
end
