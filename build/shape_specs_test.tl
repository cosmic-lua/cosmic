--- [`build.shape_specs`] over fixture projects: the spec a compile
--- splices into [`Shape.record_of`], and what it refuses, by field.
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local importer = require("build.importer")
local teal = require("build.teal")
local work = require("build.work")

-- A fixture project reads the `cosmic.*` modules it requires out of the
-- store, which holds a test to its import closure: these are the ones
-- the fixtures name.
local type _json = require("cosmic.json")
local type _shape = require("cosmic.shape")

Test.needs{ reads = { "core" } }

local built, load_trouble = teal.load()
if built == nil then
  error("could not load the compiler: " .. tostring(load_trouble))
end

--- Compiles a fixture project of `files` (name -> source) and answers
--- the Lua of its module `path`, or what the compile refused.
local function compiled(case: string, files: {string: string}, path: string): string | nil, string
  local root, trouble = Fs.mkdtemp("cosmic-shape-specs-" .. case .. "-")
  if root == nil then
    return nil, trouble
  end
  for name, source in pairs(files) do
    local wrote, wrote_trouble = Fs.write(root .. "/" .. name, source)
    if not wrote then
      return nil, wrote_trouble
    end
  end
  local handle, open_trouble = work.open(root)
  if handle == nil then
    return nil, open_trouble
  end
  local staged, stage_trouble = work.stage(handle, false)
  if staged == nil then
    work.close(handle)
    return nil, stage_trouble
  end
  local result, compile_trouble = importer.compile(handle, built, "shape-specs-test")
  work.close(handle)
  if result == nil then
    return nil, compile_trouble
  end
  for _, m in ipairs(result.modules) do
    if m.path == path then
      return m.lua, ""
    end
  end
  return nil, path .. ": not found among compiled modules"
end

--- A module that declares `declaration` as its record `R` and asks for
--- its spec, where a field is `name: ...` lines of `declaration`.
local function with_record(declaration: string, call?: string): string
  return table.concat({
    'local Shape = require("cosmic.shape")',
    declaration,
    "local S = " .. (call or 'Shape.record_of("R")'),
    "return S",
    "",
  }, "\n")
end

--- The compile of a module whose record `R` is `declaration`'s.
local function of_record(case: string, declaration: string, call?: string): string | nil, string
  return compiled(case, { ["main.tl"] = with_record(declaration, call) }, "main")
end

--- `lua` holds `want`, once whitespace is gone.
local function has(lua: string, want: string)
  local flat = lua:gsub("%s+", "")
  local wanted = want:gsub("%s+", "")
  assert(flat:find(wanted, 1, true) ~= nil,
    ("the compile does not hold %s:\n%s"):format(want, lua))
end

--- The compile of `declaration` refuses it with a message naming
--- `field` and holding `reason`.
local function refused(case: string, declaration: string, field: string, reason: string)
  local lua, trouble = of_record(case, declaration)
  assert(lua == nil, case .. ": the build accepted a record it has no spec for")
  assert(trouble:find("main.tl:", 1, true) ~= nil, "no file in: " .. trouble)
  assert(trouble:find('record_of("R")', 1, true) ~= nil, "no call in: " .. trouble)
  assert(trouble:find(field .. ": ", 1, true) ~= nil, ("%s: %q not named in: %s"):format(case, field, trouble))
  assert(trouble:find(reason, 1, true) ~= nil, ("%s: %q not said in: %s"):format(case, reason, trouble))
end

local function test_each_field_kind_is_the_shape_a_hand_written_spec_names()
  local lua, trouble = of_record("kinds", table.concat({
    "local type Level = enum 'warn' 'debug' end",
    "local record Inner",
    "  n: integer",
    "end",
    "local record R",
    "  s: string",
    "  i: integer",
    "  n: number",
    "  b: boolean",
    "  a: any",
    "  o: string | nil",
    "  nil_first: nil | integer",
    "  list: {Inner}",
    "  map: {string: {number}}",
    "  level: Level",
    "  inner: Inner",
    "  maybe: Inner | nil",
    "end",
  }, "\n"))
  assert(lua ~= nil, trouble)
  has(lua, [[Shape.record_of("R", Shape.record({
    ["a"] = Shape.any, ["b"] = Shape.boolean, ["i"] = Shape.integer,
    ["inner"] = Shape.record({ ["n"] = Shape.integer }),
    ["level"] = Shape.one_of("debug", "warn"),
    ["list"] = Shape.list(Shape.record({ ["n"] = Shape.integer })),
    ["map"] = Shape.map(Shape.list(Shape.number)),
    ["maybe"] = Shape.optional(Shape.record({ ["n"] = Shape.integer })),
    ["n"] = Shape.number,
    ["nil_first"] = Shape.optional(Shape.integer),
    ["o"] = Shape.optional(Shape.string),
    ["s"] = Shape.string }),]])
end

local function test_the_calls_line_does_not_move()
  local source = with_record("local record R\n  s: string\nend")
  local lua, trouble = compiled("lines", { ["main.tl"] = source }, "main")
  assert(lua ~= nil, trouble)
  local line = 0
  for text in (lua .. "\n"):gmatch("([^\n]*)\n") do
    line = line + 1
    if text:find("record_of", 1, true) then
      assert(line == 5, "the call is on line " .. line .. " of the Lua, not 5")
    end
  end
  assert(line > 0)
end

local function test_a_module_the_calling_module_requires_names_its_record()
  local files: {string: string} = {
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
      'local line, err = LINE:into({ from = { x = 0, y = 0 }, to = { x = 1, y = 2 } })',
      "if line ~= nil then",
      "  local x: number = line.to.x",
      "  return { LINE, err, x }",
      "end",
      "",
    }, "\n"),
  }
  local lua, trouble = compiled("module", files, "main")
  assert(lua ~= nil, trouble)
  has(lua, [[Shape.record_of("shapes.Line", Shape.record({
    ["from"] = Shape.record({ ["x"] = Shape.number, ["y"] = Shape.number }),
    ["to"] = Shape.record({ ["x"] = Shape.number, ["y"] = Shape.number }) }),]])
end

local function test_a_record_of_the_standard_library_is_read_too()
  local files: {string: string} = {
    ["main.tl"] = table.concat({
      'local Shape = require("cosmic.shape")',
      'local Json = require("cosmic.json")',
      'local OPTIONS = Shape.record_of("cosmic.json.DecodeOptions")',
      "local options = OPTIONS:into({})",
      "if options ~= nil then",
      "  local depth: integer = options.max_depth",
      "  return depth",
      "end",
      "",
    }, "\n"),
  }
  local lua, trouble = compiled("stdlib", files, "main")
  assert(lua ~= nil, trouble)
  has(lua, [[Shape.record_of("cosmic.json.DecodeOptions", Shape.record({]])
  has(lua, [["max_depth"] = Shape.integer]])
end

local function test_a_nested_own_record_is_named_by_its_path()
  local lua, trouble = of_record("nested", table.concat({
    "local record Outer",
    "  record R",
    "    n: integer",
    "  end",
    "end",
  }, "\n"), 'Shape.record_of("Outer.R")')
  assert(lua ~= nil, trouble)
  has(lua, [[Shape.record_of("Outer.R", Shape.record({ ["n"] = Shape.integer })]])
end

local function test_a_function_field_is_refused_by_name()
  refused("function", "local record R\n  ok: string\n  run: function(): integer\nend",
    "R.run", "a function has no shape")
end

local function test_a_union_of_two_types_is_refused_by_name()
  refused("union", "local record R\n  v: string | integer\nend",
    "R.v", "a union of more than one type has no shape")
  refused("union-nil", "local record R\n  v: string | integer | nil\nend",
    "R.v", "a union of more than one type has no shape")
end

local function test_an_interface_field_is_refused_by_name()
  refused("interface", "local interface Named\n  name: string\nend\nlocal record R\n  who: Named\nend",
    "R.who", "an interface has no shape")
end

local function test_a_record_implementing_an_interface_is_refused()
  refused("implements", "local interface Named\n  name: string\nend\nlocal record R is Named\n  n: integer\nend",
    "R", "implements an interface")
end

local function test_a_generic_field_is_refused_by_name()
  refused("generic",
    "local record Box<T>\n  v: T\nend\nlocal record R\n  b: Box<string>\nend",
    "R.b", "a generic type has no shape")
end

local function test_a_field_nested_in_a_list_or_map_is_named_with_its_place()
  refused("in-list", "local record R\n  l: {function(): integer}\nend",
    "R.l[]", "a function has no shape")
  refused("in-map", "local record R\n  m: {string: string | integer}\nend",
    "R.m{}", "a union of more than one type has no shape")
  refused("key", "local record R\n  m: {integer: string}\nend",
    "R.m", "a map keyed by anything but a string has no shape")
end

local function test_a_record_that_holds_itself_is_refused()
  refused("recursive", "local record R\n  next: R | nil\nend",
    "R.next", "holds itself")
end

local function test_a_name_that_is_no_record_is_refused()
  local lua, trouble = of_record("unknown", "local record R\n  n: integer\nend",
    'Shape.record_of("Missing")')
  assert(lua == nil)
  assert(trouble:find('record_of("Missing")', 1, true) ~= nil, trouble)
  assert(trouble:find("names no record declared above it", 1, true) ~= nil, trouble)
  local nested, nested_trouble = of_record("no-field", "local record R\n  n: integer\nend",
    'Shape.record_of("R.Inner")')
  assert(nested == nil)
  assert(nested_trouble:find('has no field "Inner"', 1, true) ~= nil, nested_trouble)
end

local function test_a_module_the_caller_does_not_require_is_refused()
  local files: {string: string} = {
    ["shapes.tl"] = "local record Shapes\n  record Point\n    x: number\n  end\nend\nreturn Shapes\n",
    ["main.tl"] = 'local Shape = require("cosmic.shape")\nreturn Shape.record_of("shapes.Point")\n',
  }
  local lua, trouble = compiled("unrequired", files, "main")
  assert(lua == nil)
  assert(trouble:find("no module it requires at its top level", 1, true) ~= nil, trouble)
end

local function test_a_name_that_is_no_literal_is_refused()
  local lua, trouble = of_record("computed", "local record R\n  n: integer\nend",
    'Shape.record_of("R" .. "")')
  assert(lua == nil, "the build accepted a name it cannot read")
  assert(trouble:find("string literal", 1, true) ~= nil, trouble)
end

local function test_an_enum_is_no_record()
  local lua, trouble = of_record("enum", "local type R = enum 'a' 'b' end")
  assert(lua == nil)
  assert(trouble:find("an enum", 1, true) ~= nil, trouble)
end

local function test_a_module_that_does_not_use_it_is_compiled_as_written()
  local source = 'local Shape = require("cosmic.shape")\nreturn Shape.string -- record_of\n'
  local lua, trouble = compiled("plain", { ["main.tl"] = source }, "main")
  assert(lua ~= nil, trouble)
  assert(not lua:find(", Shape.record(", 1, true), lua)
end

local function test_into_answers_the_records_type_and_no_annotation_can_say_another()
  local function with_annotation(annotation: string): string
    return table.concat({
      'local Shape = require("cosmic.shape")',
      "local record R",
      "  n: integer",
      "end",
      "local record Other",
      "  s: string",
      "end",
      'local S = Shape.record_of("R")',
      "local got, err: " .. annotation .. " | nil, string = S:into({})",
      "return { got, err, ({} as Other) }",
      "",
    }, "\n")
  end
  local lua, trouble = compiled("typed", { ["main.tl"] = with_annotation("R") }, "main")
  assert(lua ~= nil, trouble)
  local other, refusal = compiled("other", { ["main.tl"] = with_annotation("Other") }, "main")
  assert(other == nil, "a spec built from R answered an Other")
  assert(refusal:find("Other", 1, true) ~= nil and refusal:find("R", 1, true) ~= nil, refusal)
end

local function test_a_record_in_a_function_is_the_one_its_block_declares()
  local source = table.concat({
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
  }, "\n")
  local lua, trouble = compiled("scopes", { ["main.tl"] = source }, "main")
  assert(lua ~= nil, trouble)
  has(lua, [[Shape.record_of("R", Shape.record({ ["a"] = Shape.string }),]])
  has(lua, [[Shape.record_of("R", Shape.record({ ["b"] = Shape.integer }),]])
end

local function test_a_record_declared_below_the_call_is_not_read()
  local source = table.concat({
    'local Shape = require("cosmic.shape")',
    "local function first(): any",
    '  return Shape.record_of("R")',
    "end",
    "local record R",
    "  a: string",
    "end",
    "return { first, ({} as R) }",
    "",
  }, "\n")
  local lua, trouble = compiled("below", { ["main.tl"] = source }, "main")
  assert(lua == nil, "a record declared after the call was read")
  assert(trouble:find("names no record declared above it", 1, true) ~= nil, trouble)
end

local function test_an_enum_value_with_an_escape_is_refused_by_name()
  refused("escape", 'local type Level = enum "a\\nb" "c" end\nlocal record R\n  level: Level\nend',
    "R.level", "an enum value with an escape")
  refused("quote", "local type Level = enum 'c\\'d' end\nlocal record R\n  level: Level\nend",
    "R.level", "an enum value with an escape")
end

local function test_a_call_over_several_lines_is_resolved()
  local lua, trouble = of_record("multiline", "local record R\n  n: integer\nend",
    'Shape.record_of(\n  "R"\n)')
  assert(lua ~= nil, trouble)
  has(lua, [[Shape.record_of("R", Shape.record({ ["n"] = Shape.integer }),]])
end

local function test_two_calls_on_one_line_are_each_resolved()
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
  local lua, trouble = compiled("two", { ["main.tl"] = source }, "main")
  assert(lua ~= nil, trouble)
  has(lua, [[Shape.record_of("A", Shape.record({ ["a"] = Shape.string }),]])
  has(lua, [[Shape.record_of("B", Shape.record({ ["b"] = Shape.integer }),]])
end

local function test_a_comment_after_the_call_does_not_hide_it()
  local lua, trouble = of_record("comment", "local record R\n  n: integer\nend",
    'Shape.record_of("R") -- the spec of R')
  assert(lua ~= nil, trouble)
  has(lua, [[Shape.record_of("R", Shape.record({ ["n"] = Shape.integer }),]])
end
