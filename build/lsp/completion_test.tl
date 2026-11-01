--- Completion in `cosmic lsp` ([`build.lsp.completion`]): the names in scope, the members after a `.` or `:`, the modules
--- inside `require("`, a line that does not parse, and the positions counted in the units the session negotiated.

local Fs = require("cosmic.fs")
local build_paths = require("build.paths")
local Shape = require("cosmic.shape")
local Sqlite = require("cosmic.sqlite")
local Test = require("cosmic.test")
local docs_fixture = require("build.docs_fixture")
local session_fixture = require("build.lsp.session_fixture")

Test.policy{}

local type Ran = session_fixture.Ran
local answer, at, change = session_fixture.answer, session_fixture.at, session_fixture.change
local initialize, initialized = session_fixture.initialize, session_fixture.initialized
local open, served = session_fixture.open, session_fixture.served

local record Markup
  value: string
end

local record Spot
  line: integer
  character: integer
end

local record Edit
  range: {string: Spot}
  newText: string
end

local record Item
  label: string
  kind: integer
  detail: string?
  documentation: Markup?
  sortText: string?
  textEdit: Edit
end

local record Listed
  isIncomplete: boolean
  items: {Item}
end

local record CompletionSent
  result: Listed?
end

local COMPLETION_SENT <const>: Shape.Typed<CompletionSent> = Shape.record_of("CompletionSent")

local METHOD <const>, FUNCTION <const>, FIELD <const>, VARIABLE <const>, MODULE <const> = 2, 3, 5, 6, 9

--- The completion `id` asks, at the line and character of the document `name` below `root`.
local function ask(id: integer, root: string, name: string, line: integer, character: integer): string
  return at(id, "textDocument/completion", root, name, line, character)
end

--- The items `ran` answered the completion request `id` with, by label; the test fails on a `null`.
local function items(ran: Ran, id: integer): {string: Item}
  local sent = assert(COMPLETION_SENT:decode_into(answer(ran, id)))
  local listed = assert(sent.result, "no list: " .. answer(ran, id) .. ran.err)
  local out: mut {string: Item} = {}
  for _, item in ipairs(listed.items) do out[item.label] = item end
  return out
end

--- The labels of `found` that `labels` lists, in one string, to compare.
local function has(found: {string: Item}, labels: {string}): string
  local out: mut {string} = {}
  for _, label in ipairs(labels) do
    if found[label] ~= nil then out[#out + 1] = label end
  end
  return table.concat(out, ",")
end

--- The text `found`'s item `label` is ordered by.
local function sort_of(found: {string: Item}, label: string): string
  return (assert(assert(found[label], label).sortText, label))
end

--- The number of items in `found`.
local function count(found: {string: Item}): integer
  local n = 0
  for _ in pairs(found) do n = n + 1 end
  return n
end

--- A docs database that documents [`cosmic.fs`] and its `read`.
local function fs_docs(root: string): Sqlite.Handle
  return docs_fixture.database(root, {
    ["cosmic/fs.tl"] = "--- Files.\nlocal Fs = {}\n--- Reads the whole of a file.\n" ..
      "function Fs.read(path: string): string return path end\nreturn Fs\n",
  })
end

local function test_completion_is_advertised_with_its_trigger_characters()
  local root = session_fixture.project()
  local ran = served(root, { initialize(root) })
  local options = initialized(answer(ran, 1)).capabilities.completionProvider
  assert(table.concat(options.triggerCharacters, " ") == ". :", table.concat(options.triggerCharacters, " "))
end

local SCOPE <const> = 'local outer = 1\nlocal function area(width: integer): integer\n  local inner = width\n' ..
  '  return \nend\nlocal later = 2\nreturn { area, later }\n'

local function test_the_names_in_scope_at_the_cursor_are_offered_and_the_others_are_not()
  local root = session_fixture.project()
  local ran = served(root, { initialize(root), open(root, "main.tl", SCOPE),
    -- After `return ` in the body, a prefix, a prefix of a global, and a line before the function.
    ask(2, root, "main.tl", 3, 9),
    ask(3, root, "main.tl", 3, 9),
    ask(4, root, "main.tl", 0, 0),
  })
  local inside = items(ran, 2)
  assert(has(inside, { "outer", "area", "width", "inner" }) == "outer,area,width,inner", ran.err)
  assert(inside["later"] == nil, "a local declared after the cursor")
  assert(assert(inside["width"]).kind == VARIABLE and assert(inside["area"]).kind == FUNCTION)
  assert(assert(inside["width"]).detail == "integer", tostring(assert(inside["width"]).detail))
  -- A global of the standard library comes after the names of the document, and a nearer scope before a farther.
  assert(sort_of(inside, "inner") < sort_of(inside, "tostring"))
  assert(sort_of(inside, "width") < sort_of(inside, "outer"))
  local outside = items(ran, 4)
  assert(outside["width"] == nil and outside["inner"] == nil, "a name of a function offered outside it")
  assert(ran.ran["main.tl"] == 1, tostring(ran.ran["main.tl"]))
end

local function test_a_typed_prefix_narrows_the_names_and_the_edit_replaces_it()
  local root = session_fixture.project()
  local text = 'local counter = 1\nlocal cursor = 2\nlocal other = 3\nlocal _ = cou\nreturn { counter, cursor, other }\n'
  local ran = served(root, { initialize(root), open(root, "main.tl", text), ask(2, root, "main.tl", 3, 13) })
  local found = items(ran, 2)
  assert(found["counter"] ~= nil and found["cursor"] == nil and found["other"] == nil, tostring(count(found)))
  local edit = assert(found["counter"]).textEdit
  assert(edit.newText == "counter")
  local from, to = assert(edit.range["start"]), assert(edit.range["end"])
  assert(from.line == 3 and from.character == 10 and to.line == 3 and to.character == 13)
end

local POINT <const> = 'local record Point\n  x: integer\n  y: integer\nend\n\nfunction Point.origin(): Point\n' ..
  '  return { x = 0, y = 0 }\nend\n\nlocal p: Point = Point.origin()\n'

local function test_the_members_of_a_record_are_offered_while_the_line_does_not_parse()
  local root = session_fixture.project()
  local ran = served(root, { initialize(root), open(root, "main.tl", POINT .. 'local _ = p\n'),
    -- `p.` is no statement: the text does not parse.
    change(root, "main.tl", POINT .. 'local _ = p.\n'),
    ask(2, root, "main.tl", 10, 12),
    change(root, "main.tl", POINT .. 'local _ = Point.\n'),
    ask(3, root, "main.tl", 10, 16),
    change(root, "main.tl", POINT .. 'local _ = p.y\n'),
    ask(4, root, "main.tl", 10, 13),
  })
  local instance = items(ran, 2)
  assert(has(instance, { "x", "y", "origin" }) == "x,y", has(instance, { "x", "y", "origin" }))
  assert(assert(instance["x"]).kind == FIELD and assert(instance["x"]).detail == "integer")
  local edit = assert(instance["x"]).textEdit
  assert(assert(edit.range["start"]).character == 12 and assert(edit.range["end"]).character == 12)
  -- The table of a record's functions has the function a statement gave it.
  local value = items(ran, 3)
  assert(value["origin"] ~= nil and assert(value["origin"]).kind == FUNCTION, tostring(count(value)))
  -- A word typed after the `.` narrows what is offered, and its edit starts after the `.`.
  local narrowed = items(ran, 4)
  assert(has(narrowed, { "x", "y" }) == "y" and count(narrowed) == 1, tostring(count(narrowed)))
  -- Typing never checked again for completion: one check a text.
  assert(ran.ran["main.tl"] == 4, tostring(ran.ran["main.tl"]))
  assert(ran.tally.derived == 0, tostring(ran.tally.derived))
end

local function test_a_document_opened_as_it_does_not_parse_offers_nothing_to_complete_from()
  local root = session_fixture.project()
  local ran = served(root, { initialize(root), open(root, "main.tl", 'local _ = p.\n'),
    ask(2, root, "main.tl", 0, 12),
  })
  assert(count(items(ran, 2)) == 0, ran.err)
end

local COUNTER <const> = 'local class Counter\n  n: integer\n  function bump(self): integer\n    return self.n + 1\n  end\nend\n' ..
  'local c: Counter = { n = 1 }\n'

local function test_a_colon_offers_the_methods_and_a_dot_the_fields_and_the_methods_of_a_class()
  local root = session_fixture.project()
  local ran = served(root, { initialize(root), open(root, "main.tl", COUNTER .. 'return c\n'),
    change(root, "main.tl", COUNTER .. 'local _ = c:\nreturn c\n'),
    ask(2, root, "main.tl", 7, 12),
    change(root, "main.tl", COUNTER .. 'local _ = c.\nreturn c\n'),
    ask(3, root, "main.tl", 7, 12),
  })
  local methods = items(ran, 2)
  assert(has(methods, { "bump", "n" }) == "bump" and assert(methods["bump"]).kind == METHOD, has(methods, { "bump", "n" }))
  local members = items(ran, 3)
  assert(has(members, { "bump", "n" }) == "bump,n", has(members, { "bump", "n" }))
end

local function test_the_members_of_an_interface_include_those_of_the_interfaces_it_lists()
  local root = session_fixture.project()
  local text = 'local interface Named\n  name: string\nend\nlocal interface Aged is Named\n  age: integer\nend\n' ..
    'local function f(a: Aged): string\n  return a.name\nend\nreturn f\n'
  local ran = served(root, { initialize(root), open(root, "main.tl", text),
    change(root, "main.tl", 'local interface Named\n  name: string\nend\nlocal interface Aged is Named\n  age: integer\nend\n' ..
        'local function f(a: Aged): string\n  return a.\nend\nreturn f\n'),
    ask(2, root, "main.tl", 7, 11),
  })
  assert(has(items(ran, 2), { "name", "age" }) == "name,age", answer(ran, 2) .. ran.err)
end

local function test_an_enum_offers_its_values()
  local root = session_fixture.project()
  local text = 'local enum Color\n  "red"\n  "green"\nend\nlocal _ = Color\n'
  local ran = served(root, { initialize(root), open(root, "main.tl", text),
    change(root, "main.tl", 'local enum Color\n  "red"\n  "green"\nend\nlocal _ = Color.\n'),
    ask(2, root, "main.tl", 4, 16),
  })
  assert(has(items(ran, 2), { "red", "green" }) == "red,green", answer(ran, 2) .. ran.err)
end

local function test_the_members_of_a_required_module_are_the_modules_exports()
  local root = session_fixture.project()
  assert(Fs.mkdirs(root .. "/lib"))
  assert(Fs.write(root .. "/lib/point.tl", 'local record point\n  x: integer\nend\n\n' ..
      'function point.origin(): point\n  return { x = 0 }\nend\n\nfunction point.shifted(by: integer): point\n  return { x = by }\nend\n\n' ..
      'return point\n'))
  local text = 'local point = require("lib.point")\nlocal _ = point\n'
  local ran = served(root, { initialize(root), open(root, "main.tl", text),
    change(root, "main.tl", 'local point = require("lib.point")\nlocal _ = point.\n'),
    ask(2, root, "main.tl", 1, 16),
  })
  local found = items(ran, 2)
  assert(has(found, { "origin", "shifted" }) == "origin,shifted", has(found, { "origin", "shifted" }) .. ran.err)
  assert(assert(found["shifted"]).detail ~= nil)
end

local function test_a_member_of_a_module_the_docs_know_carries_its_signature_and_text()
  local root = session_fixture.project()
  local text = 'local Fs = require("cosmic.fs")\nlocal _ = Fs\n'
  local ran = served(root, { initialize(root), open(root, "main.tl", text),
    change(root, "main.tl", 'local Fs = require("cosmic.fs")\nlocal _ = Fs.rea\n'),
    ask(2, root, "main.tl", 1, 16),
  }, { fs_docs(root) })
  local found = items(ran, 2)
  local read = assert(found["read"], ran.err)
  local documentation = assert(read.documentation, "no documentation")
  assert(documentation.value:find("Reads the whole of a file.", 1, true) ~= nil, documentation.value)
  assert(assert(read.detail):find("read", 1, true) ~= nil, tostring(read.detail))
end

local function test_the_members_of_a_member_are_read_through_the_chain()
  local root = session_fixture.project()
  local text = 'local record Inner\n  depth: integer\nend\nlocal record Outer\n  inner: Inner\nend\n' ..
    'local o: Outer = { inner = { depth = 1 } }\nlocal _ = o\n'
  local ran = served(root, { initialize(root), open(root, "main.tl", text),
    change(root, "main.tl", (text:gsub("local _ = o\n$", "local _ = o.inner.\n"))),
    ask(2, root, "main.tl", 7, 18),
  })
  assert(has(items(ran, 2), { "depth", "inner" }) == "depth", ran.err)
end

local function test_the_modules_a_require_can_name_come_from_the_working_database_and_the_docs()
  local root = session_fixture.project()
  assert(Fs.mkdirs(root .. "/lib"))
  assert(Fs.write(root .. "/lib/point.tl", "return {}\n"))
  assert(Fs.write(root .. "/lib/line.tl", "return {}\n"))
  local ran = served(root, { initialize(root), open(root, "main.tl", 'local a = require("li\n'),
    ask(2, root, "main.tl", 0, 21),
    ask(3, root, "main.tl", 0, 13),
  }, { fs_docs(root) })
  local project = items(ran, 2)
  assert(has(project, { "lib.line", "lib.point", "cosmic.fs" }) == "lib.line,lib.point", ran.err)
  assert(assert(project["lib.line"]).kind == MODULE)
  local edit = assert(project["lib.line"]).textEdit
  assert(edit.newText == "lib.line" and assert(edit.range["start"]).character == 19 and
      assert(edit.range["end"]).character == 21, tostring(assert(edit.range["start"]).character))
  -- Before the quote, `require` is no string to complete.
  assert(items(ran, 3)["lib.line"] == nil)
  assert(ran.tally.derived == 0, tostring(ran.tally.derived))
end

local function test_a_module_of_the_docs_is_offered_inside_a_require()
  local root = session_fixture.project()
  local ran = served(root, { initialize(root), open(root, "main.tl", 'local a = require("cosmic.f\n'),
    ask(2, root, "main.tl", 0, 27),
  }, { fs_docs(root) })
  assert(has(items(ran, 2), { "cosmic.fs" }) == "cosmic.fs", ran.err)
end

local function test_nothing_is_offered_in_a_comment_or_a_string()
  local root = session_fixture.project()
  local text = 'local p = { x = 1 }\n-- p.\nlocal s = "p.\nlocal t = p\nreturn { p, s, t }\n'
  local ran = served(root, { initialize(root), open(root, "main.tl", text),
    ask(2, root, "main.tl", 1, 5),
    ask(3, root, "main.tl", 2, 14),
    ask(4, root, "main.tl", 40, 0),
    ask(5, root, "other.tl", 0, 0),
  })
  assert(count(items(ran, 2)) == 0 and count(items(ran, 3)) == 0)
  assert(answer(ran, 4):find('"result":null', 1, true) ~= nil, answer(ran, 4))
  assert(answer(ran, 5):find('"result":null', 1, true) ~= nil, answer(ran, 5))
end

--- `text` without its last `|`, and the line and character (in UTF-16 units) the `|` was at.
local function marked(text: string): string, integer, integer
  local mark = assert(text:match(".*()|"), "no cursor in the text")
  local before = text:sub(1, mark - 1)
  local _, line = before:gsub("\n", "")
  local row = before:match("[^\n]*$") or ""
  local units = 0
  for _, code in utf8.codes(row) do units = units + (if code >= 0x10000 then 2 else 1 end) end
  return before .. text:sub(mark + 1), line, units
end

--- The labels of the items offered at the `|` of `text`, after `base` (a text that parses) was open and `text` was typed.
local function offered(base: string, text: string, labels: {string}): string
  local root = session_fixture.project()
  local typed, line, character = marked(text)
  local ran = served(root, { initialize(root), open(root, "main.tl", base),
    change(root, "main.tl", typed), ask(2, root, "main.tl", line, character) })
  return has(items(ran, 2), labels)
end

local function test_a_receiver_that_is_a_call_is_taken_for_the_type_the_call_answers()
  local base = POINT .. 'local function make(): Point\n  return Point.origin()\nend\nlocal _ = p\n'
  local head = POINT .. 'local function make(): Point\n  return Point.origin()\nend\n'
  -- A function of the document, a function of a table of functions, and a call of a call's result.
  assert(offered(base, head .. 'local _ = make().|\n', { "x", "y", "origin" }) == "x,y")
  assert(offered(base, head .. 'local _ = Point.origin().|\n', { "x", "y", "origin" }) == "x,y")
  -- Typed on a line of its own, where the statement does not parse either.
  assert(offered(base, head .. 'make().|\n', { "x", "y" }) == "x,y")
  -- A call with arguments that hold brackets of their own.
  assert(offered(base, head .. 'local _ = make({ 1, (2) }, "a)").|\n', { "x", "y" }) == "x,y")
  -- A function that answers nothing a table has.
  assert(offered(base, head .. 'local _ = tostring(1).|\n', { "x", "y" }) == "")
end

local function test_a_receiver_that_is_an_index_is_taken_for_the_element_or_the_value()
  local base = POINT .. 'local list: {Point} = { p }\nlocal named: {string: Point} = { a = p }\nlocal _ = p\n'
  local head = POINT .. 'local list: {Point} = { p }\nlocal named: {string: Point} = { a = p }\n'
  assert(offered(base, head .. 'local _ = list[1].|\n', { "x", "y" }) == "x,y")
  assert(offered(base, head .. 'local _ = named["a"].|\n', { "x", "y" }) == "x,y")
  assert(offered(base, head .. 'local _ = named.a.|\n', { "x", "y" }) == "x,y")
  -- The array itself has no field of a point.
  assert(offered(base, head .. 'local _ = list.|\n', { "x", "y" }) == "")
end

local function test_a_receiver_that_is_a_method_call_is_taken_for_the_type_the_method_answers()
  local base = COUNTER:gsub("end\nlocal c", "  function me(self): Counter\n    return self\n  end\nend\nlocal c", 1) ..
    'local _ = c\n'
  local head = base:sub(1, -13)
  local found = offered(base, head .. 'local _ = c:me():|\n', { "bump", "me", "n" })
  assert(found == "bump,me", found)
  local fields = offered(base, head .. 'local _ = c:me().|\n', { "bump", "me", "n" })
  assert(fields == "bump,me,n", fields)
  -- A chain of methods and fields.
  assert(offered(base, head .. 'local _ = c:me():me().|\n', { "n" }) == "n")
end

local function test_a_name_declared_again_since_the_last_parse_is_not_typed_by_the_old_binding()
  local base = POINT .. 'local _ = p\n'
  assert(offered(base, POINT .. 'local p = { z = 1 }\nlocal _ = p.|\n', { "x", "y" }) == "")
  -- A name the typed text leaves alone keeps its type.
  assert(offered(base, POINT .. 'local q = { z = 1 }\nlocal _ = p.|\n', { "x", "y" }) == "x,y")
end

local function test_a_receiver_that_is_a_call_with_a_string_or_a_table_is_found()
  local base = POINT .. 'local function make(a: any): Point\n  return Point.origin()\nend\nlocal _ = p\n'
  local head = POINT .. 'local function make(a: any): Point\n  return Point.origin()\nend\n'
  assert(offered(base, head .. 'local _ = make("a").|\n', { "x", "y" }) == "x,y")
  assert(offered(base, head .. 'local _ = make({}).|\n', { "x", "y" }) == "x,y")
  -- A call with no parentheses: its argument is a string or a table.
  assert(offered(base, head .. 'local _ = make"a".|\n', { "x", "y" }) == "x,y")
  assert(offered(base, head .. 'local _ = make{}.|\n', { "x", "y" }) == "x,y")
end

local function test_a_name_narrowed_at_the_cursor_is_taken_for_the_type_it_was_narrowed_to()
  local text = 'local record Cat\n  meow: integer\nend\nlocal record Dog\n  bark: integer\nend\n' ..
    'local function a(x: Cat | Dog)\n  if x is Cat then\n    local _ = x.meow\n  end\nend\n' ..
    'local function b(x: Cat | Dog)\n  if x is Dog then\n    local _ = x.bark\n  end\nend\nreturn { a, b }\n'
  local root = session_fixture.project()
  -- Each is typed in a function whose test narrows to one of the records, so whichever record the declared union was
  -- taken for, one of them is not the narrowed one.
  local ran = served(root, { initialize(root), open(root, "main.tl", text),
    change(root, "main.tl", (text:gsub("x%.meow", "x.", 1))),
    ask(2, root, "main.tl", 8, 16),
    change(root, "main.tl", (text:gsub("x%.bark", "x.", 1))),
    ask(3, root, "main.tl", 13, 16),
  })
  local cat = has(items(ran, 2), { "meow", "bark" })
  local dog = has(items(ran, 3), { "meow", "bark" })
  assert(cat == "meow" and dog == "bark", cat .. " " .. dog .. ran.err)
end

local TYPE_BASE <const> = POINT .. 'local record Box<T>\n  item: T\nend\nlocal _ = p\n'

local function test_the_types_are_offered_in_every_type_position()
  local positions: {string} = {
    'local x: |',
    'local x:|',
    'local x = p is |',
    'local x: Box<|',
    'local x: Box<integer, |',
    'local x: {|',
    'local x: {string: |',
    'local x: integer | |',
    'local type Alias = |',
    'local record R\n  field: |\nend',
    'local record R\n  field: {|\nend',
    'local record R is |\nend',
    'local interface I is |\nend',
    'local function g(): |\nend',
    'local function g(): integer, |\nend',
    'local function g(a: |\nend',
    'local function g(a: integer, b: |\nend',
    'local record R\n  fn: function(|)\nend',
  }
  for _, position in ipairs(positions) do
    local found = offered(TYPE_BASE, TYPE_BASE:sub(1, -13) .. position .. '\n', { "Point", "Box", "integer", "p" })
    -- The types and the primitive types, and no value.
    assert(found == "Point,Box,integer" or found == "Point,integer", position .. " offered " .. found)
  end
  -- A word typed narrows the types.
  assert(offered(TYPE_BASE, TYPE_BASE:sub(1, -13) .. 'local x = p is Po|\n', { "Point", "Box", "integer" }) == "Point")
  -- An expression is no type position, so a value and not only a type is offered.
  for _, position in ipairs({ 'local x = |', 'local x = p < |', 'local x = {|}', 'local x = f(|)' }) do
    local found = offered(TYPE_BASE, TYPE_BASE:sub(1, -13) .. position .. '\n', { "Point", "p" })
    assert(found == "Point,p", position .. " offered " .. found)
  end
end

local function test_nothing_is_offered_inside_a_comment_or_a_string_of_several_lines()
  local base = POINT .. 'local _ = p\n'
  for _, position in ipairs({
      '--[[\nnote p.|\n]]\n',
      '--[[ note\nmore p|',
      '--[==[ note\n]] more p|\n]==]\n',
      'local s = [[\nline p.|\n]]\n',
      'local s = [==[\n]]\n pla|n\n]==]\n',
      'local s = [[ unfinished p|',
      'local s = "unfinished p|',
      '-- line comment p.|',
  }) do
    assert(offered(base, POINT .. position, { "p", "x", "y", "Point" }) == "", position)
  end
end

local function test_a_cursor_right_after_a_comment_or_a_string_of_several_lines_is_in_code()
  local base = POINT .. 'local _ = p\n'
  assert(offered(base, POINT .. 'local s = [[a\nb]] .. p|\n', { "p", "Point" }) == "p,Point")
  local both = offered(base, POINT .. 'local s = [==[a\nb]==] .. P|\n', { "p", "Point" })
  assert(both == "p,Point", both)
  assert(offered(base, POINT .. '--[[\nnote\n]] local _ = p.|\n', { "x", "y" }) == "x,y")
  -- A line comment ends with its line.
  assert(offered(base, POINT .. '-- note p.\nlocal _ = p.|\n', { "x", "y" }) == "x,y")
  -- A quote inside a comment opens no string, and a comment mark inside a long string no comment.
  assert(offered(base, POINT .. '--[[ it\'s ]] local _ = p.|\n', { "x", "y" }) == "x,y")
  assert(offered(base, POINT .. 'local s = [[ -- ]] .. p.|\n', { "x", "y" }) == "x,y")
end

local function test_positions_count_utf16_units_or_bytes_as_negotiated()
  local root = session_fixture.project()
  -- "😀" is four bytes and two UTF-16 units.
  local text = 'local count = 1\nlocal _ = "😀" .. cou\nreturn count\n'
  local wide = served(root, { initialize(root), open(root, "main.tl", text), ask(2, root, "main.tl", 1, 21) })
  local edit = assert(items(wide, 2)["count"], wide.err).textEdit
  assert(assert(edit.range["start"]).character == 18 and assert(edit.range["end"]).character == 21,
    tostring(assert(edit.range["start"]).character))
  local narrow = served(root, { initialize(root, '{"general":{"positionEncodings":["utf-8"]}}'),
    open(root, "main.tl", text), ask(2, root, "main.tl", 1, 23) })
  local bytes = assert(items(narrow, 2)["count"], narrow.err).textEdit
  assert(assert(bytes.range["start"]).character == 20 and assert(bytes.range["end"]).character == 23,
    tostring(assert(bytes.range["start"]).character))
end

local function test_a_call_or_an_index_is_found_after_a_wide_character_in_utf16_units_or_bytes()
  local root = session_fixture.project()
  local base = POINT .. 'local list: {Point} = { p }\nlocal _ = p\n'
  local head = POINT .. 'local list: {Point} = { p }\n'
  -- "😀" is four bytes and two UTF-16 units: `local s = "😀" .. list[1].` is 26 units and 29 bytes.
  local text = head .. 'local s = "😀" .. list[1].\n'
  local wide = served(root, { initialize(root), open(root, "main.tl", base), change(root, "main.tl", text),
    ask(2, root, "main.tl", 11, 26) })
  assert(has(items(wide, 2), { "x", "y" }) == "x,y", wide.err)
  local edit = assert(items(wide, 2)["x"]).textEdit
  assert(assert(edit.range["start"]).character == 26 and assert(edit.range["end"]).character == 26)
  local narrow = served(root, { initialize(root, '{"general":{"positionEncodings":["utf-8"]}}'),
    open(root, "main.tl", base), change(root, "main.tl", text), ask(2, root, "main.tl", 11, 29) })
  assert(has(items(narrow, 2), { "x", "y" }) == "x,y", narrow.err)
  -- A type position and a word typed after a wide character.
  local typed = head .. 'local s = "😀" local t: Po\n'
  local position = served(root, { initialize(root), open(root, "main.tl", base), change(root, "main.tl", typed),
    ask(2, root, "main.tl", 11, 26) })
  local point = assert(items(position, 2)["Point"], position.err).textEdit
  assert(assert(point.range["start"]).character == 24 and assert(point.range["end"]).character == 26,
    tostring(assert(point.range["start"]).character))
end

local function test_a_name_is_found_after_a_wide_character_on_a_line_that_does_not_parse()
  local root = session_fixture.project()
  local text = POINT .. 'local _ = p\n'
  local ran = served(root, { initialize(root), open(root, "main.tl", text),
    change(root, "main.tl", POINT .. 'local s = "😀" .. p.\n'),
    ask(2, root, "main.tl", 10, 21),
  })
  assert(has(items(ran, 2), { "x", "y" }) == "x,y", ran.err)
end

local function test_completion_reads_the_kept_check_and_checks_a_text_once()
  local root = session_fixture.project()
  local ran = served(root, { initialize(root), open(root, "main.tl", SCOPE),
    ask(2, root, "main.tl", 3, 9), ask(3, root, "main.tl", 3, 9), ask(4, root, "main.tl", 0, 0),
  })
  assert(count(items(ran, 2)) == count(items(ran, 3)))
  assert(ran.ran["main.tl"] == 1, tostring(ran.ran["main.tl"]))
  assert(ran.tally.derived == 0 and ran.tally.stages == 1,
    tostring(ran.tally.derived) .. "," .. tostring(ran.tally.stages))
end

local function test_the_members_of_a_module_open_and_unsaved_are_the_text_the_person_has()
  local root = session_fixture.project()
  assert(Fs.mkdirs(root .. "/lib"))
  local saved = 'local record point\n  x: integer\nend\nfunction point.origin(): integer\n  return 0\nend\nreturn point\n'
  assert(Fs.write(root .. "/lib/point.tl", saved))
  local edited = 'local record point\n  x: integer\nend\nfunction point.origin(): integer\n  return 0\nend\n' ..
    'function point.fresh(): integer\n  return 1\nend\nreturn point\n'
  local text = 'local point = require("lib.point")\nlocal _ = point\n'
  local ran = served(root, { initialize(root), open(root, "lib/point.tl", edited), open(root, "main.tl", text),
    change(root, "main.tl", 'local point = require("lib.point")\nlocal _ = point.\n'),
    ask(2, root, "main.tl", 1, 16),
  })
  assert(has(items(ran, 2), { "origin", "fresh" }) == "origin,fresh", answer(ran, 2) .. ran.err)
end

--- A module of the working database is completed from its `members` rows: its fields and functions with their types as written
--- and the docs of the same symbol, a nested type's, an enum's values, the interfaces a declaration lists, and none of it
--- from the checker's declarations of its stub.
local function test_the_members_of_a_module_of_the_project_are_read_from_its_rows_with_their_docs()
  local root = session_fixture.project()
  assert(Fs.mkdirs(root .. "/lib"))
  assert(Fs.write(root .. "/lib/shape.tl", table.concat({
    "local record shape",
    "  --- The width.",
    "  width: integer",
    "  record Inner",
    "    --- How deep.",
    "    depth: integer",
    "  end",
    "  inner: Inner",
    "end",
    "",
    "--- Makes a shape.",
    "function shape.make(size: integer): shape",
    "  return { width = size, inner = { depth = 1 } }",
    "end",
    "",
    "return shape",
    "",
  }, "\n")))
  local text = 'local shape = require("lib.shape")\nlocal s = shape.make(1)\nlocal _ = s\n'
  local ran = served(root, { initialize(root), open(root, "main.tl", text),
    change(root, "main.tl", 'local shape = require("lib.shape")\nlocal s = shape.make(1)\nlocal _ = s.\n'),
    ask(2, root, "main.tl", 2, 12),
    change(root, "main.tl", 'local shape = require("lib.shape")\nlocal _ = shape.\n'),
    ask(3, root, "main.tl", 1, 16),
    change(root, "main.tl", 'local shape = require("lib.shape")\nlocal s = shape.make(1)\nlocal _ = s.inner.\n'),
    ask(4, root, "main.tl", 2, 18),
  })
  local instance = items(ran, 2)
  assert(has(instance, { "width", "inner", "make" }) == "width,inner", ran.err)
  assert(assert(instance["width"]).detail == "integer" and assert(assert(instance["width"]).documentation).value == "The width.")
  local value = items(ran, 3)
  assert(has(value, { "make", "width" }) == "make,width", ran.err)
  assert(assert(value["make"]).kind == FUNCTION and assert(value["make"]).detail == "function(size: integer): shape")
  assert(assert(assert(value["make"]).documentation).value == "Makes a shape.")
  local nested = items(ran, 4)
  assert(has(nested, { "depth" }) == "depth" and assert(assert(nested["depth"]).documentation).value == "How deep.", ran.err)
  -- The receiver is typed by the checker; the members it is offered come from the rows.
  assert(ran.tally.member_rows == 3 and ran.tally.member_declarations == 0,
    tostring(ran.tally.member_rows) .. "," .. tostring(ran.tally.member_declarations))
end

--- A class's methods and an interface's listed interfaces and an enum's values are rows too.
local function test_the_members_of_classes_interfaces_and_enums_of_a_module_are_read_from_its_rows()
  local root = session_fixture.project()
  assert(Fs.mkdirs(root .. "/lib"))
  assert(Fs.write(root .. "/lib/kinds.tl", table.concat({
    "local interface Named",
    "  name: string",
    "end",
    "local interface Aged is Named",
    "  age: integer",
    "end",
    "local class Counter",
    "  n: integer",
    "  --- Adds one.",
    "  function bump(self): integer return self.n + 1 end",
    "end",
    "function Counter.new(): Counter return { n = 0 } end",
    "local enum Color",
    "  \"red\"",
    "  \"green\"",
    "end",
    "local record kinds",
    "  aged: Aged",
    "  counter: Counter",
    "  color: Color",
    "end",
    "return kinds",
    "",
  }, "\n")))
  local ran = served(root, { initialize(root),
    open(root, "main.tl", 'local kinds = require("lib.kinds")\nlocal k: kinds = nil\nlocal _ = k\n'),
    change(root, "main.tl", 'local kinds = require("lib.kinds")\nlocal k: kinds = nil\nlocal _ = k.aged.\n'),
    ask(2, root, "main.tl", 2, 18),
    change(root, "main.tl", 'local kinds = require("lib.kinds")\nlocal k: kinds = nil\nlocal _ = k.counter:\n'),
    ask(3, root, "main.tl", 2, 20),
    change(root, "main.tl", 'local kinds = require("lib.kinds")\nlocal k: kinds = nil\nlocal _ = k.counter.\n'),
    ask(4, root, "main.tl", 2, 20),
    change(root, "main.tl", 'local kinds = require("lib.kinds")\nlocal k: kinds = nil\nlocal _ = k.color.\n'),
    ask(5, root, "main.tl", 2, 18),
  })
  assert(has(items(ran, 2), { "name", "age" }) == "name,age", answer(ran, 2) .. ran.err)
  local methods = items(ran, 3)
  assert(has(methods, { "bump", "new", "n" }) == "bump,new", ran.err)
  assert(assert(methods["bump"]).kind == METHOD and assert(assert(methods["bump"]).documentation).value == "Adds one.")
  assert(has(items(ran, 4), { "n", "bump", "new" }) == "n,bump,new", ran.err)
  assert(ran.tally.member_declarations == 0, tostring(ran.tally.member_declarations) .. ran.err)
end

--- The docs of the document's own module are the rows of the text the last check was of, so a member still has its docs
--- while the line being typed does not parse.
local function test_the_members_of_the_own_module_have_their_docs_while_the_line_does_not_parse()
  local root = session_fixture.project()
  local function base(doc: string): string
    return 'local record Box\n  --- ' .. doc .. '\n  side: integer\nend\n\nlocal b: Box = { side = 1 }\n'
  end
  assert(Fs.write(root .. "/main.tl", base("The side.") .. 'local _ = b\n'))
  local ran = served(root, { initialize(root), open(root, "main.tl", base("The side.") .. 'local _ = b\n'),
    change(root, "main.tl", base("The side.") .. 'local _ = b.\n'),
    ask(2, root, "main.tl", 6, 12),
    -- Edited and not saved: the docs are those of the text the check read.
    change(root, "main.tl", base("The edited side.") .. 'local _ = b\n'),
    ask(4, root, "main.tl", 0, 0),
    change(root, "main.tl", base("The edited side.") .. 'local _ = b.\n'),
    ask(3, root, "main.tl", 6, 12),
  })
  local side = assert(items(ran, 2)["side"], ran.err)
  assert(assert(side.documentation).value == "The side." and side.detail == "integer", answer(ran, 2))
  assert(assert(assert(items(ran, 3)["side"]).documentation).value == "The edited side.", answer(ran, 3))
  assert(ran.tally.member_declarations == 0, tostring(ran.tally.member_declarations))
end

--- A module open and edited is derived into the scratch database: its docs are the unsaved text's.
local function test_the_members_of_a_module_open_and_unsaved_have_the_docs_of_the_text_the_person_has()
  local root = session_fixture.project()
  assert(Fs.mkdirs(root .. "/lib"))
  assert(Fs.write(root .. "/lib/point.tl", 'local record point\n  --- Old.\n  x: integer\nend\nreturn point\n'))
  local edited = 'local record point\n  --- New.\n  x: integer\n  --- Fresh.\n  y: integer\nend\nreturn point\n'
  local text = 'local point = require("lib.point")\nlocal p: point = nil\nlocal _ = p\n'
  local ran = served(root, { initialize(root), open(root, "lib/point.tl", edited), open(root, "main.tl", text),
    change(root, "main.tl", 'local point = require("lib.point")\nlocal p: point = nil\nlocal _ = p.\n'),
    ask(2, root, "main.tl", 2, 12),
  })
  local found = items(ran, 2)
  assert(assert(assert(found["x"], ran.err).documentation).value == "New.", answer(ran, 2))
  assert(assert(assert(found["y"]).documentation).value == "Fresh.")
  assert(ran.tally.member_declarations == 0 and ran.tally.derived >= 1)
end

--- Two types of a module that one name stands for are not told apart in the rows, so the checker answers for them: the
--- members of the first are not the second's, and a type in a block is no top-level type of its name.
local function test_a_name_declared_twice_or_in_a_block_is_completed_by_the_checker_and_not_merged()
  local root = session_fixture.project()
  local base = 'local record R\n  n: integer\nend\nlocal a: R = { n = 1 }\n' ..
    'local record R\n  other: integer\nend\nlocal b: R = { other = 1 }\n' ..
    'do\n  local record Q\n    inner: integer\n  end\n  local c: Q = { inner = 1 }\nend\n'
  assert(Fs.write(root .. "/main.tl", base .. 'local _ = a\n'))
  local ran = served(root, { initialize(root), open(root, "main.tl", base .. 'local _ = a\n'),
    change(root, "main.tl", base .. 'local _ = a.\n'),
    ask(2, root, "main.tl", 14, 12),
    change(root, "main.tl", base .. 'local _ = b.\n'),
    ask(3, root, "main.tl", 14, 12),
  })
  assert(has(items(ran, 2), { "n", "other" }) == "n", answer(ran, 2) .. ran.err)
  assert(has(items(ran, 3), { "n", "other" }) == "other", answer(ran, 3) .. ran.err)
  local inblock = 'local record Q\n  top: integer\nend\ndo\n  local record Q\n    inner: integer\n  end\n' ..
    '  local c: Q = { inner = 1 }\n  local _ = c\nend\n'
  assert(Fs.write(root .. "/other.tl", inblock))
  local again = served(root, { initialize(root), open(root, "other.tl", inblock),
    change(root, "other.tl", (inblock:gsub("local _ = c\n", "local _ = c.\n"))),
    ask(2, root, "other.tl", 8, 14),
  })
  assert(has(items(again, 2), { "top", "inner" }) == "inner", answer(again, 2) .. again.err)
end

--- `local R = setmetatable(R, {})` binds the name again, so the checker gives the new binding the `function R.f` statement and
--- none to the type: `R.` offers no `f`.
local function test_a_function_statement_about_a_rebound_name_is_not_a_function_of_the_type()
  local root = session_fixture.project()
  -- `R` at the cursor is the type; the `function R.f` below is about the local that binds the name again.
  local tail = 'local R = setmetatable(R, {})\nfunction R.f(): integer return 1 end\n'
  local head = 'local record R\n  n: integer\nend\n'
  assert(Fs.write(root .. "/main.tl", head .. 'local _ = R\n' .. tail))
  local ran = served(root, { initialize(root), open(root, "main.tl", head .. 'local _ = R\n' .. tail),
    change(root, "main.tl", head .. 'local _ = R.\n' .. tail),
    ask(2, root, "main.tl", 3, 12),
  })
  assert(has(items(ran, 2), { "f" }) == "", answer(ran, 2) .. ran.err)
end

--- The checker refuses `function C.x` where the class has a field `x`, and a class's `function C.__index`: neither is a
--- function of the class, and `C.` offers none.
local function test_a_function_the_checker_refuses_to_give_a_class_is_not_offered()
  local root = session_fixture.project()
  local base = 'local class C\n  x: integer\nend\nfunction C.x(): integer return 1 end\n' ..
    'function C.__index(): integer return 1 end\nfunction C.ok(): integer return 1 end\n'
  assert(Fs.write(root .. "/main.tl", base .. 'local _ = C\n'))
  local ran = served(root, { initialize(root), open(root, "main.tl", base .. 'local _ = C\n'),
    change(root, "main.tl", base .. 'local _ = C.\n'),
    ask(2, root, "main.tl", 6, 12),
  })
  assert(has(items(ran, 2), { "x", "__index", "ok" }) == "ok", answer(ran, 2) .. ran.err)
end

--- A module whose doc comment was removed in the open text has no documentation, though the docs database of the last build
--- still has the old text.
local function test_the_docs_of_the_rows_are_the_only_docs_of_a_member_they_hold()
  local root = session_fixture.project()
  assert(Fs.mkdirs(root .. "/lib"))
  local tail = 'function point.f(): integer\n  return 1\nend\n\nreturn point\n'
  local old = 'local record point\n  x: integer\nend\n\n--- The old f.\n' .. tail
  assert(Fs.write(root .. "/lib/point.tl", old))
  -- The projection of the last build documents `f`.
  local scratch = assert(Fs.mkdtemp("cosmic-lsp-docs-"))
  local db = docs_fixture.database(scratch, { ["lib/point.tl"] = old })
  assert(db:exec("VACUUM INTO '" .. scratch .. "/whole.db'"))
  assert(db:close())
  assert(Fs.rename(scratch .. "/whole.db", build_paths.under((assert(build_paths.directory(root)))).projection))
  local edited = 'local record point\n  x: integer\nend\n\n' .. tail
  local text = 'local point = require("lib.point")\nlocal _ = point\n'
  local ran = served(root, { initialize(root), open(root, "lib/point.tl", edited), open(root, "main.tl", text),
    change(root, "main.tl", 'local point = require("lib.point")\nlocal _ = point.\n'),
    ask(2, root, "main.tl", 1, 16),
  }, {})
  local f = assert(items(ran, 2)["f"], ran.err)
  assert(f.documentation == nil, answer(ran, 2) .. ran.err)
end

--- A class's `function R.f` is offered on an instance as a method, with the doc of the function.
local function test_a_class_function_offered_as_a_method_has_its_docs()
  local root = session_fixture.project()
  assert(Fs.mkdirs(root .. "/lib"))
  assert(Fs.write(root .. "/lib/c.tl", 'local class C\n  n: integer\nend\n--- Makes one.\n' ..
      'function C.make(): C return { n = 0 } end\nreturn C\n'))
  local text = 'local C = require("lib.c")\nlocal c: C = nil\nlocal _ = c\n'
  local ran = served(root, { initialize(root), open(root, "main.tl", text),
    change(root, "main.tl", 'local C = require("lib.c")\nlocal c: C = nil\nlocal _ = c:\n'),
    ask(2, root, "main.tl", 2, 12),
  })
  local make = assert(items(ran, 2)["make"], ran.err)
  assert(make.kind == METHOD and assert(make.documentation).value == "Makes one.", answer(ran, 2))
end

--- A function field that takes a value of the record first is a field every value holds: offered of an instance and not of
--- the table of the record's functions.
local function test_a_record_function_field_taking_self_is_offered_of_a_value_and_not_of_the_table()
  local root = session_fixture.project()
  assert(Fs.mkdirs(root .. "/lib"))
  assert(Fs.write(root .. "/lib/r.tl", 'local record R\n  area: function(self: R): integer\n  w: integer\nend\n' ..
      'function R.make(): R return { w = 1, area = nil } end\nreturn R\n'))
  local text = 'local R = require("lib.r")\nlocal r: R = nil\nlocal _ = r\n'
  local ran = served(root, { initialize(root), open(root, "main.tl", text),
    change(root, "main.tl", 'local R = require("lib.r")\nlocal r: R = nil\nlocal _ = r.\n'),
    ask(2, root, "main.tl", 2, 12),
    change(root, "main.tl", 'local R = require("lib.r")\nlocal r: R = nil\nlocal _ = R.\n'),
    ask(3, root, "main.tl", 2, 12),
  })
  local instance, value = items(ran, 2), items(ran, 3)
  assert(has(instance, { "area", "w", "make" }) == "area,w", answer(ran, 2) .. ran.err)
  assert(assert(instance["area"]).kind == FUNCTION and assert(instance["area"]).detail == "function(self: R): integer")
  assert(has(value, { "area", "w", "make" }) == "w,make" or has(value, { "area", "w", "make" }) == "make", answer(ran, 3) .. ran.err)
end

--- Checking another document begins another program ([`Driver.Build.replace`]); the types of a document's kept check name
--- declarations of the program it was made in, whose statics only that program holds.
local function test_the_functions_of_a_declaration_are_read_from_the_program_the_check_was_made_in()
  local root = session_fixture.project()
  local ran = served(root, { initialize(root), open(root, "main.tl", POINT .. 'local _ = Point\n'),
    change(root, "main.tl", POINT .. 'local _ = Point.\n'),
    open(root, "other.tl", 'local record Other\n  v: integer\nend\nreturn Other\n'),
    ask(2, root, "main.tl", 10, 16),
  })
  assert(has(items(ran, 2), { "origin", "x" }) == "origin,x", answer(ran, 2) .. ran.err)
end

local function test_the_colon_of_an_annotation_offers_types_and_not_the_methods_of_the_name()
  local root = session_fixture.project()
  local ran = served(root, { initialize(root), open(root, "main.tl", COUNTER .. 'return c\n'),
    -- `local c:` and a parameter `c:` annotate; `c:` as a statement calls a method.
    change(root, "main.tl", COUNTER .. 'local c:\nreturn c\n'),
    ask(2, root, "main.tl", 7, 8),
    change(root, "main.tl", COUNTER .. 'local function f(c:\nend\nreturn f\n'),
    ask(3, root, "main.tl", 7, 18),
    change(root, "main.tl", COUNTER .. 'c:\nreturn c\n'),
    ask(4, root, "main.tl", 7, 2),
  })
  local annotated = items(ran, 2)
  assert(annotated["bump"] == nil and annotated["Counter"] ~= nil, has(annotated, { "bump", "Counter" }))
  local parameter = items(ran, 3)
  assert(parameter["bump"] == nil and parameter["Counter"] ~= nil, has(parameter, { "bump", "Counter" }))
  assert(items(ran, 4)["bump"] ~= nil, "a method call at the start of a line")
end

local function test_a_type_position_after_a_module_offers_the_types_nested_in_it_and_not_its_members()
  local root = session_fixture.project()
  assert(Fs.mkdirs(root .. "/lib"))
  assert(Fs.write(root .. "/lib/shapes.tl", 'local record shapes\n  record Pt\n    x: integer\n  end\n  enum Kind\n    "a"\n  end\n' ..
      '  size: integer\nend\n\nfunction shapes.make(): shapes.Pt\n  return { x = 0 }\nend\n\nreturn shapes\n'))
  local head = 'local shapes = require("lib.shapes")\n'
  local ran = served(root, { initialize(root), open(root, "main.tl", head .. 'local _ = shapes\n'),
    change(root, "main.tl", head .. 'local v: shapes.\n'),
    ask(2, root, "main.tl", 1, 16),
    change(root, "main.tl", head .. 'local v: shapes.P\n'),
    ask(3, root, "main.tl", 1, 17),
    -- A value position after the same name offers its functions and fields, not only its types.
    change(root, "main.tl", head .. 'local _ = shapes.\n'),
    ask(4, root, "main.tl", 1, 17),
  })
  local types = items(ran, 2)
  assert(has(types, { "Pt", "Kind", "size", "make" }) == "Pt,Kind")
  assert(has(items(ran, 3), { "Pt", "Kind" }) == "Pt")
  assert(has(items(ran, 4), { "Pt", "size", "make" }) == "size,make", has(items(ran, 4), { "Pt", "size", "make" }))
end
