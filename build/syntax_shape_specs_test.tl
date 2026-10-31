--- [`build.syntax_shape_specs`] over small projects in the new grammar: the spec a compile splices into
--- [`Shape.record_of`], and what it refuses, by field.
local Driver = require("build.driver")
local Node = require("build.syntax_node")
local Programs = require("lang.check_programs")
local ShapeSpecs = require("build.syntax_shape_specs")
local Test = require("cosmic.test")

Test.policy{}

--- The modules of the standard library the cases name, which are lowered for their types and never checked.
local STANDARD <const>: {string: string} = {
  ["cosmic.shape"] = "local record Shape\nend\nreturn Shape\n",
  ["cosmic.json"] = table.concat({
    "local record Json",
    "  record DecodeOptions",
    "    max_depth?: integer",
    "    null_value?: string",
    "  end",
    "end",
    "return Json",
    "",
  }, "\n"),
}

--- A build of the project `files` (name to text).
local function build_of(files: {string: string}): Driver.Build
  local entries: mut {{string}} = {}
  for name, text in pairs(files) do
    entries[#entries + 1] = { name, text }
  end
  table.sort(entries, function(a: {string}, b: {string}): boolean
    return a[1] < b[1]
  end)
  local index = Driver.index(entries, function(_file: string): boolean
    return false
  end)
  local build = Driver.new({
    globals = { Driver.declarations("std", "std.d.tl", Programs.library, {}) },
    adjust = nil, external = {}, types = false,
  })
  build:provide(Driver.files(index))
  build:provide(Driver.stubs(STANDARD))
  return build
end

--- The source of the module `main` after the build resolved its `record_of` calls, or what it refused, in a project of
--- `files` (name to text).
local function resolved(files: {string: string}): string?, string
  return ShapeSpecs.resolve(build_of(files), "main", "main.tl", files["main.tl"])
end

--- A module that declares `declaration` and asks for the spec of its record `R` (or the `call`).
local function with_record(declaration: string, call?: string): string
  return table.concat({
    'local Shape = require("cosmic.shape")',
    declaration,
    "local S = " .. (call or 'Shape.record_of("R")'),
    "return S",
    "",
  }, "\n")
end

local function of_record(declaration: string, call?: string): string?, string
  return resolved({ ["main.tl"] = with_record(declaration, call) })
end

local function has(source: string?, why: string, want: string)
  assert(source ~= nil, why)
  local flat = source:gsub("%s+", "")
  assert(flat:find((want:gsub("%s+", "")), 1, true) ~= nil, ("the source does not hold %s:\n%s"):format(want, source))
end

--- The refusal of `declaration`'s record `R` names `field` and holds `reason`.
local function refused(declaration: string, field: string, reason: string)
  local source, trouble = of_record(declaration)
  assert(source == nil, "the build accepted a record it has no spec for:\n" .. tostring(source))
  assert(trouble:find("main.tl:", 1, true) ~= nil and trouble:find('record_of("R")', 1, true) ~= nil, trouble)
  assert(trouble:find(field .. ": ", 1, true) ~= nil, ("%q not named in: %s"):format(field, trouble))
  assert(trouble:find(reason, 1, true) ~= nil, ("%q not said in: %s"):format(reason, trouble))
end

local function test_each_field_kind_is_read_through_its_own_check()
  local source, why = of_record(table.concat({
    'local enum Level "warn" "debug" end',
    "local record Inner",
    "  n: integer",
    "end",
    "local record R",
    "  s: string",
    "  i: integer",
    "  n: number",
    "  b: boolean",
    "  a: any",
    "  o: string?",
    "  list: {Inner}",
    "  map: {string: {number}}",
    "  level: Level",
    "  inner: Inner",
    "  maybe: Inner?",
    "  omitted?: integer",
    "end",
  }, "\n"))
  assert(source ~= nil, why)
  has(source, why, 'Shape.record_of("R", (function(sh_s1: boolean): Shape.Spec<R>')
  has(source, why, "Shape.string")
  has(source, why, "Shape.integer")
  has(source, why, "Shape.number")
  has(source, why, "Shape.boolean")
  -- a field of `any` and a field that may be omitted may be missing
  has(source, why, "Shape.optional(Shape.any)")
  has(source, why, "Shape.optional(Shape.string)")
  has(source, why, "Shape.optional(Shape.integer)")
  -- arrays, maps, records and enums are read through their own checks
  has(source, why, "Shape.list((function(sh_s")
  has(source, why, "Shape.map(Shape.list(Shape.number))")
  has(source, why, "Shape.Spec<Inner>")
  has(source, why, "Shape.Spec<Level>")
  has(source, why, 'if sh_v == "debug" then return "debug", "" end if sh_v == "warn" then return "warn", "" end')
  has(source, why, 'Shape.build.not_one_of(sh_p, sh_v, "debug", "warn")')
  -- the record is built field by field, and the node describes its fields in byte order
  has(source, why, 'return { ["a"] = sh_v')
  has(source, why, '{ kind = "record", optional = false, fields = {')
  has(source, why, 'Shape.build.object(sh_value, sh_path, { "a", "b", "i", "inner", "level", "list", "map", "maybe", "n", "o", "omitted", "s" }, sh_s1)')
  has(source, why, '{ kind = "one_of", optional = false, values = { "debug", "warn" } }')
end

--- `any` holds nil, so the store folds `any?` into `any`, and `f?: any` keeps nothing of the `?` in the field's type: each is
--- read as an optional field, as `f?: string` and `f: string?` are, and not as one a value has to carry.
local function test_an_optional_field_of_any_is_an_optional_field()
  local source, why = of_record(table.concat({
    "local record R",
    "  w?: any",
    "  x: any?",
    "  y?: string",
    "  z: string?",
    "end",
  }, "\n"))
  assert(source ~= nil, why)
  has(source, why, "local sh_c2 = Shape.optional(Shape.any)")
  has(source, why, "local sh_c3 = Shape.optional(Shape.any)")
  has(source, why, "local sh_c4 = Shape.optional(Shape.string)")
  has(source, why, "local sh_c5 = Shape.optional(Shape.string)")
end

local function test_what_is_spliced_is_a_call_the_parser_reads()
  local source, why = of_record("local record R\n  s: string\nend")
  assert(source ~= nil, why)
  local chunk, trouble = Node.parse(source, "main.tl")
  assert(chunk ~= nil, trouble)
end

local function test_the_calls_line_does_not_move()
  local source = assert(of_record("local record R\n  s: string\nend"))
  local line = 0
  for text in (source .. "\n"):gmatch("([^\n]*)\n") do
    line = line + 1
    if text:find("record_of", 1, true) then
      assert(line == 5, "the call is on line " .. tostring(line) .. ", not 5")
    end
  end
end

local function test_a_module_the_calling_module_requires_names_its_record()
  local source, why = resolved({
    ["shapes.tl"] = table.concat({
      "local record Shapes",
      "  record Point",
      "    x: number",
      "    y: number",
      "  end",
      "  record Line",
      "    from: Shapes.Point",
      "    to: Shapes.Point",
      "  end",
      "end",
      "return Shapes",
      "",
    }, "\n"),
    ["main.tl"] = table.concat({
      'local Shape = require("cosmic.shape")',
      'local type Shapes = require("shapes")',
      'local LINE = Shape.record_of("shapes.Line")',
      "return LINE",
      "",
    }, "\n"),
  })
  has(source, why, 'Shape.record_of("shapes.Line", (function(sh_s1: boolean): Shape.Spec<Shapes.Line>')
  has(source, why, "Shape.Spec<Shapes.Point>")
end

local function test_a_record_of_the_standard_library_is_read_too()
  local source, why = resolved({ ["main.tl"] = table.concat({
    'local Shape = require("cosmic.shape")',
    'local Json = require("cosmic.json")',
    'local OPTIONS = Shape.record_of("cosmic.json.DecodeOptions")',
    "return OPTIONS, Json",
    "",
  }, "\n") })
  has(source, why, 'Shape.record_of("cosmic.json.DecodeOptions", (function(sh_s1: boolean): Shape.Spec<Json.DecodeOptions>')
  has(source, why, "local sh_c2 = Shape.optional(Shape.integer)")
end

local function test_a_nested_own_record_is_named_by_its_path()
  local source, why = of_record(table.concat({
    "local record Outer",
    "  record R",
    "    n: integer",
    "  end",
    "end",
  }, "\n"), 'Shape.record_of("Outer.R")')
  has(source, why, 'Shape.record_of("Outer.R", (function(sh_s1: boolean): Shape.Spec<Outer.R>')
end

local function test_a_function_field_is_refused_by_name()
  refused("local record R\n  ok: string\n  run: function(): integer\nend", "R.run", "a function has no shape")
end

local function test_a_union_of_two_types_is_refused_by_name()
  refused("local record R\n  v: string | integer\nend", "R.v", "a union of more than one type has no shape")
  refused("local record R\n  v: (string | integer)?\nend", "R.v", "a union of more than one type has no shape")
end

local function test_an_interface_and_a_class_field_are_refused_by_name()
  refused("local interface Named\n  name: string\nend\nlocal record R\n  who: Named\nend", "R.who",
    "an interface has no shape")
  refused("local class Box\n  n: integer\nend\nlocal record R\n  box: Box\nend", "R.box", "a class has no shape")
end

local function test_a_record_implementing_an_interface_is_refused()
  refused("local interface Named\n  name: string\nend\nlocal record R is Named\n  name: string\n  n: integer\nend", "R",
    "implements an interface")
end

local function test_a_generic_field_is_refused_by_name()
  refused("local record Box<T>\n  v: T\nend\nlocal record R\n  b: Box<string>\nend", "R.b",
    "a generic type has no shape")
end

local function test_a_field_nested_in_a_list_or_map_is_named_with_its_place()
  refused("local record R\n  l: {function(): integer}\nend", "R.l[]", "a function has no shape")
  refused("local type V = string | {V}\nlocal record R\n  v: V\nend", "R.v", "a recursive alias has no shape")
  refused("local record R\n  m: {string: string | integer}\nend", "R.m{}", "a union of more than one type has no shape")
  refused("local record R\n  m: {integer: string}\nend", "R.m", "a map keyed by anything but a string has no shape")
end

-- The function that checks a record names two locals for each field, and Lua allows 200 in one function.
local function test_a_record_with_too_many_fields_is_refused_naming_the_limit()
  local lines: mut {string} = { "local record R" }
  for i = 1, 91 do lines[#lines + 1] = ("  f%d: string"):format(i) end
  lines[#lines + 1] = "end"
  refused(table.concat(lines, "\n"), "R", "more fields than the 90 allowed")
  local fits: mut {string} = { "local record R" }
  for i = 1, 90 do fits[#fits + 1] = ("  f%d: string"):format(i) end
  fits[#fits + 1] = "end"
  assert(of_record(table.concat(fits, "\n")) ~= nil)
end

local function test_a_record_that_holds_itself_is_refused()
  refused("local record R\n  next: R?\nend", "R.next", "holds itself")
end

local function test_a_name_that_is_no_record_is_refused()
  local missing, trouble = of_record("local record R\n  n: integer\nend", 'Shape.record_of("Missing")')
  assert(missing == nil and trouble:find('record_of("Missing")', 1, true) ~= nil and
      trouble:find("names no record declared above it", 1, true) ~= nil, trouble)
  local nested, nested_trouble = of_record("local record R\n  n: integer\nend", 'Shape.record_of("R.Inner")')
  assert(nested == nil and nested_trouble:find('has no field "Inner"', 1, true) ~= nil, nested_trouble)
  local value, value_trouble = of_record("local R = 1", 'Shape.record_of("R")')
  assert(value == nil and value_trouble:find("names no record declared above it", 1, true) ~= nil, value_trouble)
end

local function test_a_module_the_caller_does_not_require_is_refused()
  local source, trouble = resolved({
    ["shapes.tl"] = "local record Shapes\n  record Point\n    x: number\n  end\nend\nreturn Shapes\n",
    ["main.tl"] = 'local Shape = require("cosmic.shape")\nreturn Shape.record_of("shapes.Point")\n',
  })
  assert(source == nil and trouble:find("no module it requires at its top level", 1, true) ~= nil, trouble)
  local absent, absent_trouble = resolved({
    ["main.tl"] = 'local Shape = require("cosmic.shape")\nlocal Gone = require("gone")\nreturn Shape.record_of("gone.Point")\n',
  })
  assert(absent == nil and absent_trouble:find('module "gone" declares no record "Point"', 1, true) ~= nil,
    absent_trouble)
end

local function test_a_name_that_is_no_literal_is_refused()
  local source, trouble = of_record("local record R\n  n: integer\nend", 'Shape.record_of("R" .. "")')
  assert(source == nil and trouble:find("string literal", 1, true) ~= nil, trouble)
  local long, long_trouble = of_record("local record R\n  n: integer\nend", "Shape.record_of([[R]])")
  assert(long == nil and long_trouble:find("plain quoted string", 1, true) ~= nil, long_trouble)
end

local function test_an_enum_is_no_record()
  local source, trouble = of_record('local enum R "a" "b" end')
  assert(source == nil and trouble:find("an enum", 1, true) ~= nil, trouble)
end

local function test_a_module_that_does_not_use_it_is_returned_as_written()
  local text = 'local Shape = require("cosmic.shape")\nreturn Shape -- record_of\n'
  local source = assert(resolved({ ["main.tl"] = text }))
  assert(source == text)
  local no_shape = 'local x = 1 -- record_of\nreturn x\n'
  assert(assert(resolved({ ["main.tl"] = no_shape })) == no_shape)
end

local function test_a_record_in_a_function_is_the_one_its_block_declares()
  local source, why = resolved({ ["main.tl"] = table.concat({
    'local Shape = require("cosmic.shape")',
    "local function first(): any",
    "  local record R",
    "    a: string",
    "  end",
    '  return Shape.record_of("R")',
    "end",
    "local function second(): any",
    "  local record R",
    "    b: integer",
    "  end",
    '  return Shape.record_of("R")',
    "end",
    "return { first, second }",
    "",
  }, "\n") })
  has(source, why, 'Shape.record_of("R", (function(sh_s1: boolean): Shape.Spec<R> local sh_c2 = Shape.string')
  has(source, why, 'Shape.record_of("R", (function(sh_s1: boolean): Shape.Spec<R> local sh_c2 = Shape.integer')
end

local function test_a_record_declared_below_the_call_is_not_read()
  local source, trouble = resolved({ ["main.tl"] = table.concat({
    'local Shape = require("cosmic.shape")',
    "local function first(): any",
    '  return Shape.record_of("R")',
    "end",
    "local record R",
    "  a: string",
    "end",
    "return { first, R }",
    "",
  }, "\n") })
  assert(source == nil and trouble:find("names no record declared above it", 1, true) ~= nil, trouble)
end

local function test_an_enum_value_with_an_escape_is_read_as_the_value_it_spells()
  local source, why = of_record('local enum Level "a\\nb" "c" end\nlocal record R\n  level: Level\nend')
  has(source, why, [[if sh_v == "a\
b" then return "a\
b", "" end if sh_v == "c" then return "c", "" end]])
end

local function test_a_call_over_several_lines_is_resolved()
  local source, why = of_record("local record R\n  n: integer\nend", 'Shape.record_of(\n  "R"\n)')
  has(source, why, 'Shape.record_of("R", (function(sh_s1: boolean): Shape.Spec<R>')
  has(source, why, "Shape.integer")
end

local function test_two_calls_on_one_line_are_each_resolved()
  local source, why = resolved({ ["main.tl"] = table.concat({
    'local Shape = require("cosmic.shape")',
    "local record A",
    "  a: string",
    "end",
    "local record B",
    "  b: integer",
    "end",
    'local both = { Shape.record_of("A"), Shape.record_of("B") }',
    "return both",
    "",
  }, "\n") })
  has(source, why, 'Shape.record_of("A", (function(sh_s1: boolean): Shape.Spec<A> local sh_c2 = Shape.string')
  has(source, why, 'Shape.record_of("B", (function(sh_s1: boolean): Shape.Spec<B> local sh_c2 = Shape.integer')
end

local function test_a_comment_after_the_call_does_not_hide_it()
  local source, why = of_record("local record R\n  n: integer\nend", 'Shape.record_of("R") -- the spec of R')
  has(source, why, 'Shape.record_of("R", (function(sh_s1: boolean): Shape.Spec<R>')
  has(source, why, "Shape.integer")
end

local function test_a_call_through_another_name_is_not_a_call()
  local text = table.concat({
    'local Shape = require("cosmic.shape")',
    "local record R",
    "  n: integer",
    "end",
    "local other = { record_of = print }",
    'return other.record_of("R"), Shape',
    "",
  }, "\n")
  assert(assert(resolved({ ["main.tl"] = text })) == text)
end

local function test_a_record_a_module_re_exports_under_an_alias_is_read_through_it()
  local source, why = resolved({
    ["rules.tl"] = "local record Rules\n  record Policy\n    n: integer\n  end\nend\nreturn Rules\n",
    ["sb.tl"] = table.concat({
      'local type Rules = require("rules")',
      "local record Sb",
      "  type Policy = Rules.Policy",
      "end",
      "return Sb",
      "",
    }, "\n"),
    ["main.tl"] = 'local Shape = require("cosmic.shape")\nlocal type Sb = require("sb")\nreturn Shape.record_of("sb.Policy")\n',
  })
  has(source, why, 'Shape.record_of("sb.Policy", (function(sh_s1: boolean): Shape.Spec<Sb.Policy>')
end

local function test_the_splices_are_the_last_first_and_a_refusal_names_its_line()
  local source = table.concat({
    'local Shape = require("cosmic.shape")',
    "local record A",
    "  a: string",
    "end",
    "local record B",
    "  b: integer",
    "end",
    'local both = { Shape.record_of("A"), Shape.record_of("B") }',
    "return both",
    "",
  }, "\n")
  local found = ShapeSpecs.splices(build_of({ ["main.tl"] = source }), "main", "main.tl", source)
  assert(found.refusal == "" and found.line == 0, found.refusal)
  assert(#found.splices == 2, tostring(#found.splices))
  local last, first = assert(found.splices[1]), assert(found.splices[2])
  assert(last.at > first.at, "the last in the source comes first")
  -- Each goes right after its call's name.
  assert(source:sub(first.at - 2, first.at) == '"A"', source:sub(first.at - 2, first.at))
  assert(source:sub(last.at - 2, last.at) == '"B"', source:sub(last.at - 2, last.at))
  assert(first.text:find("Shape.Spec<A>", 1, true) ~= nil, first.text)
  local want = source:sub(1, first.at) .. first.text .. source:sub(first.at + 1, last.at) .. last.text ..
    source:sub(last.at + 1)
  assert(ShapeSpecs.spliced(source, found.splices) == want, ShapeSpecs.spliced(source, found.splices))
  local computed = (source:gsub('record_of%("B"%)', 'record_of("B" .. "")'))
  local unread = ShapeSpecs.splices(build_of({ ["main.tl"] = computed }), "main", "main.tl", computed)
  assert(#unread.splices == 0, "a refused call splices none")
  assert(unread.line == 8, tostring(unread.line))
  assert(unread.refusal:find("main.tl:8: Shape.record_of: the name must be a string literal", 1, true) ~= nil,
    unread.refusal)
end

--- A call that already passes a check and a node is left as it is: what a program passes there is a function and data the
--- checker types, so it can only answer the type it names.
local function test_a_call_with_more_than_the_name_is_left_as_written()
  local source = table.concat({
    'local Shape = require("cosmic.shape")',
    "local record A",
    "  a: string",
    "end",
    'local S = Shape.record_of("A", nil)',
    "return S",
    "",
  }, "\n")
  local found = ShapeSpecs.splices(build_of({ ["main.tl"] = source }), "main", "main.tl", source)
  assert(#found.splices == 0 and found.refusal == "", found.refusal)
end

--- `record_of` read any way but as a call written `Shape.record_of("Name")` has no check from the build, and raises when it
--- runs: the build refuses it where it stands, however the module is reached, unless its line says it is on purpose.
local function test_record_of_read_any_other_way_is_refused_unless_it_says_it_is_on_purpose()
  local head = 'local Shape = require("cosmic.shape")\nlocal record A\n  a: string\nend\n'
  local function refusal(text: string): string
    local found = ShapeSpecs.splices(build_of({ ["main.tl"] = text }), "main", "main.tl", text)
    if found.refusal ~= "" then assert(#found.splices == 0, "a refused module splices none") end
    return found.refusal
  end
  local routes: {string} = {
    head .. "local f = Shape.record_of\nreturn f\n",
    head .. "local Alias = Shape\nreturn Alias.record_of(\"A\")\n",
    head .. 'return Shape["record_of"]("A")\n',
    head .. 'return require("cosmic.shape").record_of("A")\n',
    'local record A\n  a: string\nend\nreturn require("cosmic.shape").record_of("A")\n',
  }
  for _, text in ipairs(routes) do
    local said = refusal(text)
    assert(said:find("main.tl:", 1, true) ~= nil and said:find("record_of: read other than as a call", 1, true) ~= nil,
      said .. " for " .. text)
  end
  -- on purpose, marked on its line
  local marked = head .. 'return Shape["record_of"]("A") -- record_of: unresolved on purpose\n'
  assert(refusal(marked) == "")
  -- a field of another table with the name is no use of it, and a direct call is the build's to complete
  assert(refusal(head .. "local other = { record_of = print }\nreturn other.record_of(\"A\")\n") == "")
  assert(refusal(head .. 'return Shape.record_of("A")\n') == "")
end
