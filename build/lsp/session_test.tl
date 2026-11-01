--- `cosmic lsp`'s sessions ([`build.lsp.session`], [`build.lsp.check`]):
--- the protocol's lifecycle, a document's diagnostics, where they are and
--- how they are worded, hover, definition, formatting, and one session over a
--- loopback connection. What a `require` reads is in source_test.tl.

local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Net = require("cosmic.net")
local Poll = require("cosmic.poll")
local Shape = require("cosmic.shape")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local Stream = require("cosmic.stream")
local Test = require("cosmic.test")
local build_paths = require("build.paths")
local tree = require("build.tree")
local docs_fixture = require("build.docs_fixture")
local session = require("build.lsp.session")
local session_fixture = require("build.lsp.session_fixture")

Test.policy{ loopback = { "127.0.0.1" } }

local type Ran = session_fixture.Ran
local answer, at, bodies = session_fixture.answer, session_fixture.at, session_fixture.bodies
local change, changes, close = session_fixture.change, session_fixture.changes, session_fixture.close
local counts, edge, failed = session_fixture.counts, session_fixture.edge, session_fixture.failed
local format, framed = session_fixture.format, session_fixture.framed
local initialize, initialized = session_fixture.initialize, session_fixture.initialized
local messages_of, nth, only = session_fixture.messages_of, session_fixture.nth, session_fixture.only
local open, published, served = session_fixture.open, session_fixture.published, session_fixture.served
local sent_of = session_fixture.sent
local EXIT, SHUTDOWN = session_fixture.EXIT, session_fixture.SHUTDOWN

local record Markup
  value: string
end

local record Hovered
  contents: Markup
end

local record HoverSent
  result: Hovered?
end

local HOVER_SENT <const>: Shape.Typed<HoverSent> = Shape.record_of("HoverSent")

local record Spot
  line: integer
  character: integer
end

local record Edit
  range: {string: Spot}
  newText: string
end

local record FormatSent
  result: {Edit}
end

local FORMAT_SENT <const>: Shape.Typed<FormatSent> = Shape.record_of("FormatSent")

--- A docs database that documents [`cosmic.fs`] and its `read`.
local function fs_docs(root: string): Sqlite.Handle
  return docs_fixture.database(root, {
    ["cosmic/fs.tl"] = "--- Files.\nlocal Fs = {}\n--- Reads the whole of a file.\n" ..
      "function Fs.read(path: string): string return path end\nreturn Fs\n",
  })
end

local record Located
  uri: string
  range: {string: Spot}
end

local record DefinitionSent
  result: Located?
end

local DEFINITION_SENT <const>: Shape.Typed<DefinitionSent> = Shape.record_of("DefinitionSent")

--- The markdown of the hover `ran` answered request `id` with, or nil.
local function hovered(ran: Ran, id: integer): string?
  local shown = assert(HOVER_SENT:decode_into(answer(ran, id)))
  local result = shown.result
  if result == nil then return nil end
  return result.contents.value
end

--- What the loopback test's two tasks leave each other.
local record Exchange
  mut code: integer
  mut sent: string
end

local function test_a_type_error_is_published_where_it_is()
  local root = session_fixture.project()
  local text = 'local s = "é"\nlocal n: integer = s\nreturn n\n'
  local ran = served(root, { initialize(root), open(root, "main.tl", text), SHUTDOWN, EXIT })
  assert(ran.code == 0, ran.err)
  local init = initialized(answer(ran, 1))
  assert(init.capabilities.positionEncoding == "utf-16")
  assert(init.capabilities.textDocumentSync.change == 1)
  local diagnostics = nth(ran, 1)
  assert(#diagnostics == 1, table.concat(ran.sent, "\n"))
  local diagnostic = only(diagnostics)
  assert(diagnostic.message == "`s` is `string`, where `integer` is wanted as the value of `n` (not_assignable): " ..
      "pass a value of type `integer`, or change the declaration to `string`", diagnostic.message)
  local start, finish = edge(diagnostic, "start"), edge(diagnostic, "end")
  assert(start.line == 1 and start.character == 19)
  -- The range covers the word, `s`, not the place alone.
  assert(finish.line == 1 and finish.character == 20)
  assert(answer(ran, 99):find('"result":null', 1, true))
end

local function test_a_column_counts_utf16_units_or_bytes_as_negotiated()
  local root = session_fixture.project()
  -- "é" is two bytes and one UTF-16 unit; the error is at `nope`.
  local text = 'local _ = { "é", nope }\n'
  local wide = served(root, { initialize(root), open(root, "main.tl", text) })
  local found = only(nth(wide, 1))
  assert(edge(found, "start").character == 17)
  assert(edge(found, "end").character == 21, "the end is past the start, by the word `nope`")
  local narrow = served(root, { initialize(root, '{"general":{"positionEncodings":["utf-8","utf-16"]}}'),
    open(root, "main.tl", text) })
  local init = initialized(answer(narrow, 1))
  assert(init.capabilities.positionEncoding == "utf-8")
  assert(edge(only(nth(narrow, 1)), "start").character == 18)
end

local function test_a_change_that_fixes_the_error_clears_it()
  local root = session_fixture.project()
  local ran = served(root, {
    initialize(root),
    open(root, "main.tl", "local n: integer = 'x'\nreturn n\n"),
    change(root, "main.tl", "local n: integer = 1\nreturn n\n"),
    close(root, "main.tl"),
  })
  assert(counts(ran) == "1,0,0", counts(ran))
end

local function test_hover_shows_the_docs_of_a_required_symbol()
  local root = assert(Fs.mkdtemp("cosmic-lsp-"))
  -- `F` is no name the docs know: only the `require` it is bound to says
  -- it is cosmic.fs.
  local text = 'local F = require("cosmic.fs")\nlocal unknown = 1\nlocal _ = F.read, unknown\n'
  local ran = served(root, { initialize(root), open(root, "main.tl", text),
    at(2, "textDocument/hover", root, "main.tl", 2, 13),
    at(3, "textDocument/hover", root, "main.tl", 2, 19),
  }, { fs_docs(root) })
  local value = assert(hovered(ran, 2), ran.err)
  assert(value:find("cosmic.fs.read", 1, true) ~= nil and value:find("Reads the whole of a file.", 1, true) ~= nil,
    value)
  assert(hovered(ran, 3) == nil, "a name nothing documents")
end

--- The location `ran` answered the definition request `id` with, or nil for `null`.
local function defined(ran: Ran, id: integer): Located?
  return assert(DEFINITION_SENT:decode_into(answer(ran, id))).result
end

--- Asserts that `found` is in the file at `path`, on `line` from character `from` up to `to`.
local function assert_located_at(found: Located?, path: string, line: integer, from: integer, to: integer)
  local where = assert(found, "no definition")
  assert(where.uri == "file://" .. path, where.uri)
  local start, finish = assert(where.range["start"]), assert(where.range["end"])
  local got = tostring(start.line) .. ":" .. tostring(start.character) .. "-" .. tostring(finish.line) .. ":" ..
    tostring(finish.character)
  assert(got == tostring(line) .. ":" .. tostring(from) .. "-" .. tostring(line) .. ":" .. tostring(to), got)
end

--- Asserts that `found` is in the file `name` below `root`, on `line` from character `from` up to `to`.
local function assert_located(found: Located?, root: string, name: string, line: integer, from: integer, to: integer)
  assert_located_at(found, root .. "/" .. name, line, from, to)
end

local function test_definition_is_advertised()
  local root = session_fixture.project()
  local ran = served(root, { initialize(root) })
  assert(initialized(answer(ran, 1)).capabilities.definitionProvider)
end

local function test_definition_of_a_local_and_a_parameter_is_where_it_is_declared()
  local root = session_fixture.project()
  local text = 'local count = 1\nlocal function twice(n: integer): integer\n  return n * count\nend\n' ..
    'local _ = twice(count)\n'
  local ran = served(root, { initialize(root), open(root, "main.tl", text),
    at(2, "textDocument/definition", root, "main.tl", 4, 18),
    at(3, "textDocument/definition", root, "main.tl", 2, 9),
    at(4, "textDocument/definition", root, "main.tl", 2, 13),
  })
  assert_located(defined(ran, 2), root, "main.tl", 0, 6, 11)
  assert_located(defined(ran, 3), root, "main.tl", 1, 21, 22)
  assert_located(defined(ran, 4), root, "main.tl", 0, 6, 11)
end

local function test_definition_of_a_function_is_its_declaration()
  local root = session_fixture.project()
  local text = 'local function twice(n: integer): integer\n  return n * 2\nend\nlocal _ = twice(2)\n'
  local ran = served(root, { initialize(root), open(root, "main.tl", text),
    at(2, "textDocument/definition", root, "main.tl", 3, 12),
  })
  assert_located(defined(ran, 2), root, "main.tl", 0, 15, 20)
end

local function test_definition_of_a_field_and_a_type_is_their_declaration()
  local root = session_fixture.project()
  local text = 'local record Shape\n  sides: integer\nend\n\nfunction Shape.make(): Shape\n' ..
    '  return { sides = 3 }\nend\n\nlocal s: Shape = Shape.make()\nlocal _ = s.sides\n' ..
    'local t: Shape = { sides = 4 }\nreturn t\n'
  local ran = served(root, { initialize(root), open(root, "main.tl", text),
    -- `sides` of `s.sides`, `Shape` of `s: Shape`, `make` of `Shape.make()`, `sides` of the table.
    at(2, "textDocument/definition", root, "main.tl", 9, 13),
    at(3, "textDocument/definition", root, "main.tl", 8, 9),
    at(4, "textDocument/definition", root, "main.tl", 8, 24),
    at(5, "textDocument/definition", root, "main.tl", 10, 20),
    at(6, "textDocument/definition", root, "main.tl", 9, 11),
  })
  assert_located(defined(ran, 2), root, "main.tl", 1, 2, 7)
  assert_located(defined(ran, 3), root, "main.tl", 0, 13, 18)
  assert_located(defined(ran, 4), root, "main.tl", 4, 15, 19)
  assert_located(defined(ran, 5), root, "main.tl", 1, 2, 7)
  assert_located(defined(ran, 6), root, "main.tl", 8, 6, 7)
end

--- The text the kept-result tests ask definitions of: `count` of the last line is declared on the first.
local KEPT_TEXT <const> = 'local count = 1\nlocal _ = count\n'

local function test_definition_reads_the_check_the_diagnostics_made()
  local root = session_fixture.project()
  local ran = served(root, { initialize(root), open(root, "main.tl", KEPT_TEXT),
    at(2, "textDocument/definition", root, "main.tl", 1, 10),
    at(3, "textDocument/definition", root, "main.tl", 1, 10),
  })
  assert_located(defined(ran, 2), root, "main.tl", 0, 6, 11)
  assert_located(defined(ran, 3), root, "main.tl", 0, 6, 11)
  assert(ran.ran["main.tl"] == 1, tostring(ran.ran["main.tl"]))
end

local function test_an_edit_is_checked_again_and_answered_from_the_new_check()
  local root = session_fixture.project()
  local ran = served(root, { initialize(root), open(root, "main.tl", KEPT_TEXT),
    at(2, "textDocument/definition", root, "main.tl", 1, 10),
    change(root, "main.tl", "-- moved\n" .. KEPT_TEXT),
    at(3, "textDocument/definition", root, "main.tl", 2, 10),
    at(4, "textDocument/definition", root, "main.tl", 2, 10),
  })
  assert_located(defined(ran, 2), root, "main.tl", 0, 6, 11)
  assert_located(defined(ran, 3), root, "main.tl", 1, 6, 11)
  assert_located(defined(ran, 4), root, "main.tl", 1, 6, 11)
  assert(ran.ran["main.tl"] == 2, tostring(ran.ran["main.tl"]))
end

local function test_definition_is_answered_from_the_kept_check_after_another_document_was_checked()
  local root = session_fixture.project()
  -- Both are files the stage lists: the program is made again when it leaves a document the stage does not list.
  assert(Fs.write(root .. "/main.tl", KEPT_TEXT))
  assert(Fs.write(root .. "/other.tl", "local other = 2\nreturn other\n"))
  local ran = served(root, { initialize(root), open(root, "main.tl", KEPT_TEXT),
    open(root, "other.tl", "local other = 2\nreturn other\n"),
    at(2, "textDocument/definition", root, "main.tl", 1, 10),
    at(3, "textDocument/definition", root, "other.tl", 1, 7),
  })
  assert_located(defined(ran, 2), root, "main.tl", 0, 6, 11)
  assert_located(defined(ran, 3), root, "other.tl", 0, 6, 11)
  assert(ran.ran["main.tl"] == 1, tostring(ran.ran["main.tl"]))
  assert(ran.ran["other.tl"] == 1, tostring(ran.ran["other.tl"]))
end

local function test_a_document_closed_and_opened_again_is_checked_again()
  local root = session_fixture.project()
  local ran = served(root, { initialize(root), open(root, "main.tl", KEPT_TEXT),
    at(2, "textDocument/definition", root, "main.tl", 1, 10),
    close(root, "main.tl"), open(root, "main.tl", KEPT_TEXT),
    at(3, "textDocument/definition", root, "main.tl", 1, 10),
  })
  assert_located(defined(ran, 3), root, "main.tl", 0, 6, 11)
  assert(ran.ran["main.tl"] == 2, tostring(ran.ran["main.tl"]))
end

local function test_a_text_that_does_not_parse_is_kept_as_nothing_found()
  local root = session_fixture.project()
  local ran = served(root, { initialize(root), open(root, "main.tl", "local count = = 1\nlocal _ = count\n"),
    at(2, "textDocument/definition", root, "main.tl", 1, 10),
    at(3, "textDocument/definition", root, "main.tl", 1, 10),
  })
  assert(defined(ran, 2) == nil and defined(ran, 3) == nil)
  assert(ran.ran["main.tl"] == 1, tostring(ran.ran["main.tl"]))
end

local function test_a_module_changed_on_disk_makes_the_kept_check_stale()
  local root = session_fixture.project()
  assert(Fs.mkdirs(root .. "/lib"))
  local point = "local record point\n  x: integer\nend\n\nfunction point.origin(): point\n  return { x = 0 }\nend\n\nreturn point\n"
  assert(Fs.write(root .. "/lib/point.tl", point))
  local text = 'local point = require("lib.point")\nlocal _ = point.origin()\n'
  local ran = session_fixture.served_between(root, {
    { initialize(root), open(root, "main.tl", text), at(2, "textDocument/definition", root, "main.tl", 1, 18) },
    { session_fixture.changed_on_disk(root, "lib/point.tl"),
      at(3, "textDocument/definition", root, "main.tl", 1, 18) },
  }, function(_after: integer)
    assert(Fs.write(root .. "/lib/point.tl", "-- moved\n" .. point))
  end)
  assert_located(defined(ran, 2), root, "lib/point.tl", 4, 15, 21)
  assert_located(defined(ran, 3), root, "lib/point.tl", 5, 15, 21)
  assert(ran.ran["main.tl"] == 2, tostring(ran.ran["main.tl"]))
end

local function test_definition_follows_a_require_to_the_module_that_declares_it()
  local root = session_fixture.project()
  assert(Fs.mkdirs(root .. "/lib"))
  assert(Fs.write(root .. "/lib/point.tl", "local record point\n  x: integer\n  record Corner\n    y: integer\n  end\nend\n\n" ..
      "function point.origin(): point\n  return { x = 0 }\nend\n\nreturn point\n"))
  local text = 'local point = require("lib.point")\nlocal p: point = point.origin()\n' ..
    'local c: point.Corner = { y = 1 }\nlocal _ = p.x, c\n'
  local ran = served(root, { initialize(root), open(root, "main.tl", text),
    -- `origin`, `x`, the nested type `Corner`, its field `y`, and `point` itself, which the document declares.
    at(2, "textDocument/definition", root, "main.tl", 1, 24),
    at(3, "textDocument/definition", root, "main.tl", 3, 12),
    at(4, "textDocument/definition", root, "main.tl", 2, 18),
    at(5, "textDocument/definition", root, "main.tl", 2, 27),
    at(6, "textDocument/definition", root, "main.tl", 1, 10),
  })
  assert_located(defined(ran, 2), root, "lib/point.tl", 7, 15, 21)
  assert_located(defined(ran, 3), root, "lib/point.tl", 1, 2, 3)
  assert_located(defined(ran, 4), root, "lib/point.tl", 2, 9, 15)
  assert_located(defined(ran, 5), root, "lib/point.tl", 3, 4, 5)
  assert_located(defined(ran, 6), root, "main.tl", 0, 6, 11)
end

local function test_definition_of_a_member_is_found_through_a_class_an_interface_and_an_optional()
  local root = session_fixture.project()
  local text = 'local class Counter\n  n: integer\n  function bump(self): integer\n    return self.n + 1\n  end\nend\n' ..
    'local c: Counter = { n = 1 }\nlocal _ = c.n\nlocal _ = c:bump()\n' ..
    'local interface Named\n  name: string\nend\nlocal interface Aged is Named\n  age: integer\nend\n' ..
    'local function f(a: Aged): string\n  return a.name\nend\n' ..
    'local record A\n  v: integer\nend\nlocal function g(a: A?): integer\n  return a.v\nend\nreturn { f, g }\n'
  local ran = served(root, { initialize(root), open(root, "main.tl", text),
    -- A class's field and method, a field only the interface listed declares, and a field of an optional receiver.
    at(2, "textDocument/definition", root, "main.tl", 7, 12),
    at(3, "textDocument/definition", root, "main.tl", 8, 13),
    at(4, "textDocument/definition", root, "main.tl", 16, 12),
    at(5, "textDocument/definition", root, "main.tl", 22, 12),
  })
  assert_located(defined(ran, 2), root, "main.tl", 1, 2, 3)
  assert_located(defined(ran, 3), root, "main.tl", 2, 11, 15)
  assert_located(defined(ran, 4), root, "main.tl", 10, 2, 6)
  assert_located(defined(ran, 5), root, "main.tl", 19, 2, 3)
end

--- Two records of one name, declared in two function bodies: a field of each is its own.
local function test_definition_of_a_field_of_a_type_declared_in_a_function_body_is_its_own()
  local root = session_fixture.project()
  local text = 'local function a(): integer\n  local record P\n    x: integer\n  end\n  local p: P = { x = 1 }\n' ..
    '  return p.x\nend\nlocal function b(): string\n  local record P\n    y: string\n  end\n' ..
    '  local p: P = { y = "s" }\n  return p.y\nend\nreturn { a, b }\n'
  local ran = served(root, { initialize(root), open(root, "main.tl", text),
    -- `x` of `p.x`, `x` of the table, `P` of `p: P`, then the same of the second function.
    at(2, "textDocument/definition", root, "main.tl", 5, 11),
    at(3, "textDocument/definition", root, "main.tl", 4, 17),
    at(4, "textDocument/definition", root, "main.tl", 4, 11),
    at(5, "textDocument/definition", root, "main.tl", 12, 11),
    at(6, "textDocument/definition", root, "main.tl", 11, 17),
    at(7, "textDocument/definition", root, "main.tl", 11, 11),
  })
  assert_located(defined(ran, 2), root, "main.tl", 2, 4, 5)
  assert_located(defined(ran, 3), root, "main.tl", 2, 4, 5)
  assert_located(defined(ran, 4), root, "main.tl", 1, 15, 16)
  assert_located(defined(ran, 5), root, "main.tl", 9, 4, 5)
  assert_located(defined(ran, 6), root, "main.tl", 9, 4, 5)
  assert_located(defined(ran, 7), root, "main.tl", 8, 15, 16)
end

--- A method a `function P.f` statement adds to a type of a function body, and a value of such a type a function returns.
local function test_definition_of_a_method_added_to_a_type_declared_in_a_function_body()
  local root = session_fixture.project()
  local text = 'local function make(): integer\n  local record P\n    x: integer\n  end\n' ..
    '  function P.f(self: P): integer\n    return self.x\n  end\n  local p: P = { x = 1 }\n' ..
    '  return p:f()\nend\nreturn make\n'
  local ran = served(root, { initialize(root), open(root, "main.tl", text),
    at(2, "textDocument/definition", root, "main.tl", 8, 12),
  })
  assert_located(defined(ran, 2), root, "main.tl", 4, 13, 14)
end

--- The checker cannot name a type of a function body in a signature, so a function cannot return one: the uses of such a
--- type are in the body, in a function nested in it among them.
local function test_definition_of_a_field_of_a_body_local_type_in_a_nested_function()
  local root = session_fixture.project()
  local text = 'local function make(): integer\n  local record P\n    x: integer\n  end\n' ..
    '  local function get(p: P): integer\n    return p.x\n  end\n  return get({ x = 1 })\nend\nreturn make\n'
  local ran = served(root, { initialize(root), open(root, "main.tl", text),
    at(2, "textDocument/definition", root, "main.tl", 5, 13),
  })
  assert_located(defined(ran, 2), root, "main.tl", 2, 4, 5)
end

--- A string where an enum is expected stands for one of its values, which a person can go to.
local function test_definition_of_a_string_literal_is_the_enum_value_it_stands_for()
  local root = session_fixture.project()
  local text = 'local enum Color\n  "red"\n  "green"\nend\nlocal function paint(c: Color): Color\n  return c\nend\n' ..
    'local _ = paint("green")\nlocal _ = paint("red")\nlocal function inner(): string\n  local enum E\n    "a"\n  end\n' ..
    '  local e: E = "a"\n  return e\nend\nreturn { paint, inner }\n'
  local ran = served(root, { initialize(root), open(root, "main.tl", text),
    at(2, "textDocument/definition", root, "main.tl", 7, 18),
    at(3, "textDocument/definition", root, "main.tl", 8, 18),
    at(4, "textDocument/definition", root, "main.tl", 13, 16),
  })
  assert_located(defined(ran, 2), root, "main.tl", 2, 2, 9)
  assert_located(defined(ran, 3), root, "main.tl", 1, 2, 7)
  assert_located(defined(ran, 4), root, "main.tl", 11, 4, 7)
end

--- A build rewrites a document's text where it calls [`Shape.record_of`], which moves every byte after the call: a place
--- after one is still the place in the text as written.
local function test_definition_after_a_record_shape_call_counts_the_text_as_written()
  local root = session_fixture.project()
  local text = 'local Shape = require("cosmic.shape")\nlocal record R\n  n: integer\nend\n' ..
    'local R_SHAPE <const> = Shape.record_of("R") local keep: integer = 1\n' ..
    "local r: R = assert(R_SHAPE:into({ n = 1 }))\nlocal _ = r.n, keep\n"
  local ran = served(root, { initialize(root), open(root, "main.tl", text),
    -- `keep` after the call, on its line and below it, and `n` of `r.n`.
    at(2, "textDocument/definition", root, "main.tl", 6, 15),
    at(3, "textDocument/definition", root, "main.tl", 4, 53),
    at(4, "textDocument/definition", root, "main.tl", 6, 12),
  })
  assert_located(defined(ran, 2), root, "main.tl", 4, 51, 55)
  assert_located(defined(ran, 3), root, "main.tl", 4, 51, 55)
  assert_located(defined(ran, 4), root, "main.tl", 2, 2, 3)
end

local function test_definition_reads_the_text_of_an_open_module()
  local root = session_fixture.project()
  assert(Fs.mkdirs(root .. "/lib"))
  assert(Fs.write(root .. "/lib/point.tl", "local record point\n  x: integer\nend\nreturn point\n"))
  local text = 'local point = require("lib.point")\nlocal p: point = { x = 1 }\nlocal _ = p.x\n'
  local ran = served(root, { initialize(root), open(root, "main.tl", text),
    open(root, "lib/point.tl", "-- moved down\n\nlocal record point\n  y: integer\n  x: integer\nend\nreturn point\n"),
    at(2, "textDocument/definition", root, "main.tl", 2, 12),
  })
  assert_located(defined(ran, 2), root, "lib/point.tl", 4, 2, 3)
end

--- A module `lib.point` and a main that asks for the places of its field and its function.
local POINT <const> = "local record point\n  x: integer\nend\n\nfunction point.origin(): point\n  return { x = 0 }\nend\n\n" ..
  "return point\n"
local USES_POINT <const> = 'local point = require("lib.point")\nlocal p: point = point.origin()\nlocal _ = p.x\n'

--- A place in another module is read from the `places` the stage derived, and the module is not parsed: a row changed in
--- the database moves the answer, which a parse of the file would not.
local function test_definition_in_another_module_is_read_from_the_places_the_stage_derived()
  local root = session_fixture.project()
  assert(Fs.mkdirs(root .. "/lib"))
  assert(Fs.write(root .. "/lib/point.tl", POINT))
  local working = build_paths.under((assert(build_paths.directory(root)))).working
  local ran = session_fixture.served_between(root, {
    { initialize(root), open(root, "main.tl", USES_POINT) },
    { at(3, "textDocument/definition", root, "main.tl", 2, 12) },
  }, function(_after: integer)
    local held = assert(Sqlite.open(working, { writable = true }))
    assert(held:exec("UPDATE places SET line = 1, column = 14, length = 5 WHERE symbol = 'point.x'"))
    assert(held:close())
  end)
  assert_located(defined(ran, 3), root, "lib/point.tl", 0, 13, 18)
  assert(ran.tally.derived == 0, tostring(ran.tally.derived))
end

--- A place on an ASCII line of a module is answered without reading the module's text; one after non-ASCII on its line is
--- counted in the encoding's units, which needs it.
local function test_definition_reads_the_text_of_a_module_only_for_a_line_with_non_ascii()
  local root = session_fixture.project()
  assert(Fs.mkdirs(root .. "/lib"))
  assert(Fs.write(root .. "/lib/point.tl", "local record point\n  x: integer\nend\nreturn point\n"))
  -- `x` stands after "é" (one UTF-16 unit, two bytes) and "😀" (two units, four bytes) of a string on its line.
  assert(Fs.write(root .. "/lib/wide.tl", 'local s = "é😀" local record wide x: integer end\nreturn wide\n'))
  local uses = 'local point = require("lib.point")\nlocal p: point = { x = 1 }\nlocal _ = p.x\n'
  local ascii = served(root, { initialize(root), open(root, "main.tl", uses),
    at(2, "textDocument/definition", root, "main.tl", 2, 12),
  })
  assert_located(defined(ascii, 2), root, "lib/point.tl", 1, 2, 3)
  assert(ascii.tally.texts_read == 0, tostring(ascii.tally.texts_read))
  local reads = 'local wide = require("lib.wide")\nlocal w: wide = { x = 1 }\nlocal _ = w.x\n'
  local wide = served(root, { initialize(root), open(root, "main.tl", reads),
    at(2, "textDocument/definition", root, "main.tl", 2, 12),
  })
  -- UTF-16: 11 + 1 + 2 + 2 + 18 characters before `x`; in bytes, 11 + 2 + 4 + 2 + 18.
  assert_located(defined(wide, 2), root, "lib/wide.tl", 0, 34, 35)
  assert(wide.tally.texts_read == 1, tostring(wide.tally.texts_read))
  local bytes = served(root, { initialize(root, '{"general":{"positionEncodings":["utf-8"]}}'),
    open(root, "main.tl", reads), at(2, "textDocument/definition", root, "main.tl", 2, 12),
  })
  assert_located(defined(bytes, 2), root, "lib/wide.tl", 0, 37, 38)
end

--- A symbol of a module generated from a header is defined in the header, at the name on the line the map gives.
local function test_definition_of_a_symbol_of_a_generated_module_is_in_the_header()
  local root = assert(Fs.mkdtemp("cosmic-lsp-"))
  assert(Fs.mkdirs(root .. "/core"))
  assert(Fs.mkdirs(root .. "/build"))
  assert(Fs.write(root .. "/build/importer.tl", "return {}\n"))
  assert(Fs.write(root .. "/core/syscalls.h", table.concat({
    "/*", " * --- Reads bytes.", " * ---@param fd integer descriptor", " * ---@return string|nil data bytes",
    " * ---@return string error failure", " * ---@return integer errno number", " */",
    "COSMIC_SYSCALL(read, 1);", "",
  }, "\n") .. "\n"))
  local built = assert(tree.built_from(root))
  local text = 'local sys = require("cosmic.sys")\nlocal _ = sys.read\n'
  local ran = served(root, { initialize(root), open(root, "main.tl", text),
    at(2, "textDocument/definition", root, "main.tl", 1, 14),
  }, nil, built)
  assert_located(defined(ran, 2), root, "core/syscalls.h", 7, 15, 19)
end

--- An open module is parsed only where the person has edited it, and once for a text.
local function test_definition_parses_an_open_module_only_where_it_differs_from_the_staged_file()
  local root = session_fixture.project()
  assert(Fs.mkdirs(root .. "/lib"))
  assert(Fs.write(root .. "/lib/point.tl", POINT))
  local same = served(root, { initialize(root), open(root, "main.tl", USES_POINT),
    open(root, "lib/point.tl", POINT),
    at(2, "textDocument/definition", root, "main.tl", 2, 12),
  })
  assert_located(defined(same, 2), root, "lib/point.tl", 1, 2, 3)
  assert(same.tally.derived == 0, tostring(same.tally.derived))
  local edited = served(root, { initialize(root), open(root, "main.tl", USES_POINT),
    open(root, "lib/point.tl", "-- moved down\n\n" .. POINT),
    at(2, "textDocument/definition", root, "main.tl", 2, 12),
    at(3, "textDocument/definition", root, "main.tl", 1, 24),
    at(4, "textDocument/definition", root, "main.tl", 2, 12),
  })
  assert_located(defined(edited, 2), root, "lib/point.tl", 3, 2, 3)
  assert_located(defined(edited, 3), root, "lib/point.tl", 6, 15, 21)
  assert_located(defined(edited, 4), root, "lib/point.tl", 3, 2, 3)
  assert(edited.tally.derived == 1, tostring(edited.tally.derived))
end

--- Closing an edited module drops its rows from the scratch database, so opening it again with the same text derives
--- it again, as a first open does.
local function test_closing_an_edited_module_lets_go_of_its_derived_rows()
  local root = session_fixture.project()
  assert(Fs.mkdirs(root .. "/lib"))
  assert(Fs.write(root .. "/lib/point.tl", POINT))
  local edited = "-- moved down\n\n" .. POINT
  local ran = served(root, { initialize(root), open(root, "main.tl", USES_POINT),
    open(root, "lib/point.tl", edited),
    at(2, "textDocument/definition", root, "main.tl", 2, 12),
    close(root, "lib/point.tl"),
    open(root, "lib/point.tl", edited),
    at(3, "textDocument/definition", root, "main.tl", 2, 12),
  })
  assert_located(defined(ran, 2), root, "lib/point.tl", 3, 2, 3)
  assert_located(defined(ran, 3), root, "lib/point.tl", 3, 2, 3)
  assert(ran.tally.derived == 2, tostring(ran.tally.derived))
end

--- The editor's word that a file changed on disk stages the tree again, so a definition asked after it finds the place
--- where the file now has it.
local function test_definition_follows_a_module_saved_with_its_declarations_moved()
  local root = session_fixture.project()
  assert(Fs.mkdirs(root .. "/lib"))
  assert(Fs.write(root .. "/lib/point.tl", POINT))
  local send = session_fixture.serving(root)
  local first = send({ initialize(root), open(root, "main.tl", USES_POINT),
    at(2, "textDocument/definition", root, "main.tl", 2, 12),
  })
  assert_located(defined(first, 2), root, "lib/point.tl", 1, 2, 3)
  assert(Fs.write(root .. "/lib/point.tl", "\n\n" .. POINT))
  local second = send({ session_fixture.changed_on_disk(root, "lib/point.tl"),
    at(3, "textDocument/definition", root, "main.tl", 2, 12),
  })
  assert_located(defined(second, 3), root, "lib/point.tl", 3, 2, 3)
  assert(second.tally.stages == 2 and second.tally.derived == 0,
    tostring(second.tally.stages) .. "," .. tostring(second.tally.derived))
end

local function test_definition_counts_utf16_units_or_bytes_as_negotiated()
  local root = session_fixture.project()
  -- "😀" is four bytes and two UTF-16 units.
  local text = 'local count = 1\nlocal _ = { "😀", count }\n'
  local wide = served(root, { initialize(root), open(root, "main.tl", text),
    at(2, "textDocument/definition", root, "main.tl", 1, 20),
  })
  assert_located(defined(wide, 2), root, "main.tl", 0, 6, 11)
  local narrow = served(root, { initialize(root, '{"general":{"positionEncodings":["utf-8"]}}'),
    open(root, "main.tl", text), at(2, "textDocument/definition", root, "main.tl", 1, 22),
  })
  assert_located(defined(narrow, 2), root, "main.tl", 0, 6, 11)
end

--- A symbol of the binary's own `cosmic.*` modules, which the project's database does not list, is where the places of
--- the database the session reads by default ([`Store.databases`]: a worker's sealed one, which carries the closure's
--- places, or the tool's own) say, in a read-only file below the build directory that holds the module's text.
local function test_definition_of_a_binary_module_s_field_is_the_file_extracted_from_the_tool()
  local root = session_fixture.project()
  local text = 'local Fs = require("cosmic.fs")\nlocal _ = Fs.read\nlocal t: Fs.Staged? = nil\n'
  local databases = Store.databases()
  local carried = assert(assert(Sqlite.text_rows(assert(databases[#databases]),
    "SELECT CAST(inflate(source) AS TEXT) FROM modules WHERE path = 'cosmic.fs'"))[1]):text(1)
  local function line_of(needle: string): integer
    local from = 0
    for number = 0, 100000 do
      local stop = carried:find("\n", from + 1, true)
      local row = carried:sub(from + 1, (stop or #carried + 1) - 1)
      if row:find(needle, 1, true) then return number end
      if stop == nil then break end
      from = stop
    end
    error("cosmic/fs.tl has no line with " .. needle)
  end
  local read_line = line_of("function Fs.read(")
  local staged_line = line_of("interface Staged")
  local ran = served(root, { initialize(root), open(root, "main.tl", text),
    at(2, "textDocument/definition", root, "main.tl", 1, 15),
    at(3, "textDocument/definition", root, "main.tl", 2, 12),
    -- `Fs` of [`Fs.read`], a binding of the project.
    at(4, "textDocument/definition", root, "main.tl", 1, 11),
  })
  local directory = build_paths.under((assert(build_paths.directory(root)))).cosmic_source
  local file = directory .. "/" .. Hash.hex_sha256(carried) .. "/cosmic/fs.tl"
  assert_located_at(defined(ran, 2), file, read_line, 12, 16)
  assert_located_at(defined(ran, 3), file, staged_line, 12, 18)
  assert_located(defined(ran, 4), root, "main.tl", 0, 6, 8)
  assert(Fs.read(file) == carried and assert(Fs.stat(file)).mode & 0x1ff == 0x124, "the file holds the text, read-only")
end

--- A symbol of a binary module generated from a header ([`cosmic.sys`]) is in the header the tool carries, written
--- read-only below the build directory, at the line the module's `-- line` map gave and the column its name stands at.
local function test_definition_of_a_generated_binary_module_s_function_is_the_header_extracted_from_the_tool()
  local root = session_fixture.project()
  local text = 'local sys = require("cosmic.sys")\nlocal _ = sys.getpid\n'
  local header = "/* The table. */\n\n/*\n * --- The pid.\n */\nCOSMIC_SYSCALL(getpid, 0);\n"
  local db = session_fixture.carrying_origin("cosmic.sys", "core/syscalls.h", header, { { "sys.getpid", "field", "6", "1", "0", "0" } })
  local ran = served(root, { initialize(root), open(root, "main.tl", text),
    at(2, "textDocument/definition", root, "main.tl", 1, 16),
  }, { db })
  local directory = build_paths.under((assert(build_paths.directory(root)))).cosmic_source
  local file = directory .. "/" .. Hash.hex_sha256(header) .. "/core/syscalls.h"
  assert_located_at(defined(ran, 2), file, 5, 15, 21)
  assert(Fs.read(file) == header and assert(Fs.stat(file)).mode & 0x1ff == 0x124, "the file holds the header, read-only")
  assert(db:close())
end

--- A tool whose database lists no places (one from before the table) answers none.
local function test_definition_of_a_binary_module_s_field_is_null_where_the_tool_carries_no_places()
  local root = session_fixture.project()
  local text = 'local Fs = require("cosmic.fs")\nlocal _ = Fs.read\n'
  local bare = assert(Sqlite.memory())
  local ran = served(root, { initialize(root), open(root, "main.tl", text),
    at(2, "textDocument/definition", root, "main.tl", 1, 15),
  }, { bare })
  assert(defined(ran, 2) == nil)
end

local function test_definition_of_nothing_the_report_knows_is_null()
  local root = session_fixture.project()
  local text = 'local n = 1\nlocal _ = tostring(n)\nlocal s = "x" .. 1 -- n\n'
  local ran = served(root, { initialize(root), open(root, "main.tl", text),
    -- A global of the standard library, a number, white space, a comment, a line past the end, and no document.
    at(2, "textDocument/definition", root, "main.tl", 1, 12),
    at(3, "textDocument/definition", root, "main.tl", 0, 10),
    at(4, "textDocument/definition", root, "main.tl", 1, 5),
    at(5, "textDocument/definition", root, "main.tl", 2, 20),
    at(6, "textDocument/definition", root, "main.tl", 40, 0),
    at(7, "textDocument/definition", root, "other.tl", 0, 0),
  })
  for id = 2, 7 do
    assert(defined(ran, id) == nil, "request " .. tostring(id))
    assert(answer(ran, id):find('"result":null', 1, true) ~= nil, answer(ran, id))
  end
end

--- A build writes the projection anew and renames it into place: a
--- hover reads the docs of the one there now, not the one it read first.
local function test_hover_reads_the_projection_a_build_wrote_again()
  local root = session_fixture.project()
  local projection = build_paths.under((assert(build_paths.directory(root)))).projection
  --- Writes, as the build does, a projection whose `lib.shapes.area` says `word`.
  local function built(word: string)
    local scratch = assert(Fs.mkdtemp("cosmic-lsp-docs-"))
    local db = docs_fixture.database(scratch, { ["lib/shapes.tl"] = "--- Shapes.\nlocal record shapes\nend\n\n" ..
        "--- " .. word .. " words.\nfunction shapes.area(): integer\n  return 1\nend\n\nreturn shapes\n" })
    -- One file, whole, as a build's projection is.
    assert(db:exec("VACUUM INTO '" .. scratch .. "/whole.db'"))
    assert(db:close())
    assert(Fs.rename(scratch .. "/whole.db", projection))
  end
  built("First")
  local text = 'local shapes = require("lib.shapes")\nlocal _ = shapes.area\nreturn shapes\n'
  local ran = session_fixture.served_between(root, {
    { initialize(root), open(root, "main.tl", text), at(2, "textDocument/hover", root, "main.tl", 1, 18) },
    { at(3, "textDocument/hover", root, "main.tl", 1, 18) },
  }, function(_after: integer) built("Second") end, {})
  local first = assert(hovered(ran, 2), ran.err)
  assert(first:find("First words.", 1, true) ~= nil, first)
  local second = assert(hovered(ran, 3), ran.err)
  assert(second:find("Second words.", 1, true) ~= nil, second)
end

local function test_hover_counts_utf16_units_before_the_cursor()
  local root = assert(Fs.mkdtemp("cosmic-lsp-"))
  -- "😀" is four bytes and two UTF-16 units, "é" two bytes and one unit.
  local text = 'local F = require("cosmic.fs")\nlocal _ = { "😀", F.read }\nlocal _ = { "é", F.read }\n'
  local ran = served(root, { initialize(root), open(root, "main.tl", text),
    -- The `r` of `read`, and the space before `F`, after the surrogate pair.
    at(2, "textDocument/hover", root, "main.tl", 1, 20),
    at(3, "textDocument/hover", root, "main.tl", 1, 17),
    -- The `r` of `read` after the two-byte character.
    at(4, "textDocument/hover", root, "main.tl", 2, 19),
  }, { fs_docs(root) })
  local after_pair = assert(hovered(ran, 2), ran.err)
  assert(after_pair:find("cosmic.fs.read", 1, true) ~= nil, after_pair)
  assert(hovered(ran, 3) == nil, "the space before F, not F")
  local after_two = assert(hovered(ran, 4), ran.err)
  assert(after_two:find("cosmic.fs.read", 1, true) ~= nil, after_two)
end

--- The edits the answer `body` to a formatting request holds.
local function edits_of(body: string): {Edit}
  return assert(FORMAT_SENT:decode_into(body)).result
end

--- The `side` ("start" or "end") of the range of `edit`.
local function spot(edit: Edit, side: string): Spot
  return assert(edit.range[side])
end

--- How many `window/showMessage` notifications `ran` sent that say `part`.
local function shown_with(ran: Ran, part: string): integer
  local n = 0
  for _, body in ipairs(ran.sent) do
    if sent_of(body).method == "window/showMessage" and body:find(part, 1, true) ~= nil then
      n = n + 1
    end
  end
  return n
end

local function test_formatting_replaces_the_buffer_with_its_layout()
  local root = session_fixture.project()
  -- The file on disk is laid out; the buffer is not, and is what is formatted.
  assert(Fs.write(root .. "/main.tl", "local n = 1\nreturn n\n"))
  local ran = served(root, { initialize(root), open(root, "main.tl", "local   n =  1\nreturn n\n"),
    format(2, root, "main.tl"), format(3, root, "absent.tl") })
  assert(initialized(answer(ran, 1)).capabilities.documentFormattingProvider == true)
  local edits = edits_of(answer(ran, 2))
  assert(#edits == 1)
  local edit = assert(edits[1])
  assert(edit.newText == "local n = 1\nreturn n\n", edit.newText)
  assert(spot(edit, "start").line == 0 and spot(edit, "start").character == 0)
  -- The text ends with a newline, so its end is the start of the line after the last.
  assert(spot(edit, "end").line == 2 and spot(edit, "end").character == 0)
  assert(failed(answer(ran, 3)) == -32803)
  assert(shown_with(ran, "not formatted") == 0)
end

local function test_formatting_a_laid_out_buffer_gives_no_edit()
  local root = session_fixture.project()
  local ran = served(root, { initialize(root), open(root, "main.tl", "local n = 1\nreturn n\n"),
    format(2, root, "main.tl") })
  local body = answer(ran, 2)
  assert(#edits_of(body) == 0 and body:find('"result":[]', 1, true) ~= nil, body)
  assert(shown_with(ran, "not formatted") == 0)
end

local function test_a_refused_buffer_gives_no_edit_and_a_message()
  local root = session_fixture.project()
  local ran = served(root, { initialize(root), open(root, "bad.tl", "local   x: = 2\nreturn x\n"),
    format(2, root, "bad.tl") })
  local body = answer(ran, 2)
  assert(body:find('"result":[]', 1, true) ~= nil and body:find('"error"', 1, true) == nil, body)
  assert(shown_with(ran, "not formatted: bad.tl:1:") == 1, table.concat(ran.sent, "\n"))
end

local function test_a_declaration_file_is_laid_out_as_one()
  local root = session_fixture.project()
  local ran = served(root, { initialize(root), open(root, "box.d.tl", "local  record Box\n  n:integer\nend\n"),
    format(2, root, "box.d.tl"), open(root, "prog.d.tl", "local record R\nend\nx = 1\n"), format(3, root, "prog.d.tl"),
    open(root, "prog.tl", "local record R\nend\nx = 1\n"), format(4, root, "prog.tl") })
  local edits = edits_of(answer(ran, 2))
  assert(#edits == 1, answer(ran, 2))
  assert(assert(edits[1]).newText == "local record Box\n  n:integer\nend\n", assert(edits[1]).newText)
  -- A statement is a syntax error of a declaration file and none of a program.
  assert(#edits_of(answer(ran, 3)) == 0)
  assert(shown_with(ran, "not formatted: prog.d.tl:") == 1, table.concat(ran.sent, "\n"))
  assert(#edits_of(answer(ran, 4)) == 0)
  assert(shown_with(ran, "not formatted") == 1)
end

local function test_formatting_ends_the_range_after_a_carriage_return_and_leaves_other_files_alone()
  local root = session_fixture.project()
  local ran = served(root, { initialize(root), open(root, "crlf.tl", "local   n = 1\r\nreturn n\r\n"),
    format(2, root, "crlf.tl"), open(root, "page.tmpl", "<p>  {{ x }}"), format(3, root, "page.tmpl") })
  local edit = assert(edits_of(answer(ran, 2))[1])
  assert(edit.newText == "local n = 1\nreturn n\n", edit.newText)
  assert(spot(edit, "end").line == 2 and spot(edit, "end").character == 0)
  assert(#edits_of(answer(ran, 3)) == 0 and shown_with(ran, "not formatted") == 0)
end

--- The last line has no newline and holds a character of one UTF-16 unit (e acute, two bytes) and one of two (a
--- surrogate pair, four bytes), so its end is 13 units in and 16 bytes in.
local TEXT_WITHOUT_NEWLINE <const> = 'local   a = 1\nlocal b =  "caf\u{e9}"\nreturn  "\u{1F600}\u{e9}"'

local function test_the_range_covers_a_last_line_with_no_newline_in_the_encoding_negotiated()
  local root = session_fixture.project()
  local wide = served(root, { initialize(root), open(root, "u.tl", TEXT_WITHOUT_NEWLINE), format(2, root, "u.tl") })
  local edits = edits_of(answer(wide, 2))
  local edit = assert(edits[1])
  assert(edit.newText == 'local a = 1\nlocal b = "caf\u{e9}"\nreturn "\u{1F600}\u{e9}"\n', edit.newText)
  assert(spot(edit, "end").line == 2 and spot(edit, "end").character == 13, tostring(spot(edit, "end").character))
  local narrow = served(root, { initialize(root, '{"general":{"positionEncodings":["utf-8"]}}'),
    open(root, "u.tl", TEXT_WITHOUT_NEWLINE), format(2, root, "u.tl") })
  local bytes = assert(edits_of(answer(narrow, 2))[1])
  assert(spot(bytes, "end").line == 2 and spot(bytes, "end").character == 16, tostring(spot(bytes, "end").character))
end

local function test_the_lifecycle_is_held_to()
  local root = session_fixture.project()
  local early = served(root, { at(5, "textDocument/hover", root, "main.tl", 0, 0), EXIT })
  assert(failed(answer(early, 5)) == -32002)
  assert(early.code == 1, "exit without shutdown")
  local unknown = served(root, { initialize(root), '{"jsonrpc":"2.0","id":6,"method":"nosuch"}',
    '{"jsonrpc":"2.0","method":"$/nosuch"}', "{not json", SHUTDOWN,
    at(7, "textDocument/hover", root, "main.tl", 0, 0) })
  assert(failed(answer(unknown, 6)) == -32601)
  assert(failed(answer(unknown, 7)) == -32600)
  assert(table.concat(unknown.sent, "\n"):find('"code":-32700', 1, true))
  local twice = served(root, { initialize(root), initialize(root) })
  local refusals = 0
  for _, body in ipairs(twice.sent) do
    local sent = sent_of(body)
    local why = sent.error
    if why ~= nil then
      assert(why.code == -32600, body)
      refusals = refusals + 1
    end
  end
  assert(#twice.sent == 2 and refusals == 1, "the second initialize is refused")
  assert(unknown.code == 0, "the stream ending after shutdown")
  local broken = served(root, { initialize(root) })
  assert(broken.code == 1, "the stream ending before shutdown")
end

local function test_a_session_over_a_loopback_connection()
  local root = session_fixture.project()
  local listener <close> = assert(Net.listen(Net.tcp("127.0.0.1", 0)))
  local address = listener.address
  local exchange: Exchange = { code = -1, sent = "" }
  Poll.run(function()
    Poll.spawn(function()
      local conn <close> = assert(listener:accept(Clock.seconds(10)))
      exchange.code = session.serve(session.new(root), conn, function(text: string): boolean, string
        return conn:write(text)
      end)
    end)
    local client <close> = assert(Net.connect(address, { timeout_ns = Clock.seconds(10) }))
    assert(client:write(framed({ initialize(root), SHUTDOWN, EXIT })))
    assert(client:shutdown("write"))
    exchange.sent = assert(Stream.read_all(client))
  end)
  assert(exchange.code == 0)
  local init = initialized(assert(bodies(exchange.sent)[1]))
  assert(init.serverInfo.name == "cosmic")
end

local function test_each_wrong_message_has_its_code()
  local root = session_fixture.project()
  local ran = served(root, { initialize(root),
    '{"jsonrpc":"2.0","id":2,"method":"textDocument/hover","params":{"textDocument":5}}',
    '{"jsonrpc":"2.0","id":3,"method":5}',
    "[1,2]",
    "{not json",
  })
  assert(failed(answer(ran, 2)) == -32602, "params that do not fit")
  local codes: mut {integer} = {}
  for _, body in ipairs(ran.sent) do
    local sent = sent_of(body)
    local why = sent.error
    if why ~= nil and sent.id == nil then codes[#codes + 1] = why.code end
  end
  assert(table.concat(codes, ",") == "-32600,-32600,-32700", table.concat(codes, ","))
end

local function test_a_lone_carriage_return_ends_a_line()
  local root = session_fixture.project()
  for _, ending in ipairs({ "\r", "\r\n", "\n" }) do
    local text = "local x = 1" .. ending .. 'local n: integer = "s"' .. ending .. "local m: integer = n + x" .. ending .. "return m" .. ending
    local start = edge(only(nth(served(root, { initialize(root), open(root, "main.tl", text) }), 1)), "start")
    assert(start.line == 1 and start.character == 19, tostring(ending:byte()) .. ": " ..
        tostring(start.line) .. ":" .. tostring(start.character))
  end
end

local function test_changes_already_read_are_checked_once()
  local root = session_fixture.project()
  local runs = published(served(root, {
    initialize(root),
    open(root, "main.tl", "return 1\n"),
    change(root, "main.tl", "local n: integer = 'x'\nreturn n\n"),
    change(root, "main.tl", "local n: integer = 1\nreturn n\n"),
    close(root, "main.tl"),
  }))
  assert(#runs == 3, "the first change is not checked: " .. tostring(#runs))
  local second = assert(runs[2])
  assert(#second == 0, messages_of(second))
end

local function test_a_record_shape_is_resolved_as_a_build_does()
  local root = session_fixture.project()
  local text = 'local Shape = require("cosmic.shape")\n' ..
    "local record R\n  n: integer\nend\n" ..
    'local R_SHAPE <const> = Shape.record_of("R") local bad: integer = "x"\n' ..
    "local r: R = assert(R_SHAPE:into({ n = 1 }))\nlocal n: integer = r.n\nlocal sum: integer = n + bad\nreturn sum\n"
  -- At `"x"` in the text as written, not as the build's rewrite moved it.
  local start = edge(only(nth(served(root, { initialize(root), open(root, "main.tl", text) }), 1)), "start")
  assert(start.line == 4 and start.character == 66, tostring(start.line) .. ":" .. tostring(start.character))
  -- A module required is rewritten too.
  local module = text:gsub(' local bad: integer = "x"', "")
  assert(Fs.write(root .. "/shaped.tl", (module:gsub("local sum: integer = n %+ bad\nreturn sum", "return r"))))
  local user = 'local shaped = require("shaped")\nlocal n: integer = shaped.n\nreturn n\n'
  local through = nth(served(root, { initialize(root), open(root, "user.tl", user) }), 1)
  assert(#through == 0, messages_of(through))
  -- The whole text is read for the calls.
  local tally = served(root, { initialize(root), open(root, "main.tl", text) }).tally
  assert(tally.whole_splices == 1, tostring(tally.whole_splices))
end

local function test_a_test_file_is_not_warned_of_its_tests()
  local root = session_fixture.project()
  local text = "local function test_it() assert(true) end\n"
  local ran = served(root, { initialize(root), open(root, "it_test.tl", text), open(root, "it.tl", text) })
  local test_file, other = nth(ran, 1), nth(ran, 2)
  assert(#test_file == 0, messages_of(test_file))
  assert(#other == 1, "a warning is published: " .. messages_of(other))
  assert(only(other).message:find("unused", 1, true), messages_of(other))
end

local function test_a_global_is_published_as_refused()
  local root = session_fixture.project()
  local refused = only(nth(served(root, { initialize(root),
    open(root, "main.tl", "local n = 1\nglobal shared_count: integer = n\nreturn shared_count\n") }), 1))
  assert(refused.message == "`global` declares a global, which only a declaration file does (global_in_program): " ..
      "write `local`; a program's globals are exactly the ones a declaration file (`.d.tl`) declares", refused.message)
  local start = edge(refused, "start")
  assert(start.line == 1 and start.character == 0, tostring(start.line) .. ":" .. tostring(start.character))
end

local function test_a_test_file_that_returns_a_value_is_refused()
  local root = session_fixture.project()
  local text = "local function test_it() assert(true) end\nreturn {}\n"
  local refused = only(nth(served(root, { initialize(root), open(root, "it_test.tl", text) }), 1))
  assert(refused.message:find("a test file may not both define test_* functions and return", 1, true),
    refused.message)
  assert(edge(refused, "start").line == 1, "at its return")
end

local function test_a_refused_record_shape_is_published_at_its_call()
  local root = session_fixture.project()
  local text = 'local Shape = require("cosmic.shape")\nlocal record R\n  n: integer\nend\n' ..
    'local name = "R"\nlocal R_SHAPE <const> = Shape.record_of(name)\nreturn R_SHAPE\n'
  local refused = only(nth(served(root, { initialize(root), open(root, "main.tl", text) }), 1))
  assert(refused.message:find("the name must be a string literal", 1, true), refused.message)
  assert(edge(refused, "start").line == 5, tostring(edge(refused, "start").line))
end

local function test_a_column_after_a_surrogate_pair_counts_two_units()
  local root = session_fixture.project()
  -- "😀" is four bytes and two UTF-16 units; the error is at `nope`.
  local text = 'local _ = { "😀", nope }\n'
  local wide = only(nth(served(root, { initialize(root), open(root, "main.tl", text) }), 1))
  assert(edge(wide, "start").character == 18, tostring(edge(wide, "start").character))
  assert(edge(wide, "end").character == 22, tostring(edge(wide, "end").character))
  local narrow = only(nth(served(root, { initialize(root, '{"general":{"positionEncodings":["utf-8"]}}'),
    open(root, "main.tl", text) }), 1))
  assert(edge(narrow, "start").character == 20, tostring(edge(narrow, "start").character))
end

local function test_hover_counts_bytes_when_utf8_is_negotiated()
  local root = assert(Fs.mkdtemp("cosmic-lsp-"))
  local text = 'local F = require("cosmic.fs")\nlocal _ = { "😀", F.read }\n'
  local ran = served(root, { initialize(root, '{"general":{"positionEncodings":["utf-8"]}}'),
    open(root, "main.tl", text),
    -- Byte 25 is the `d` of `read`; as UTF-16 units it would be the `}`.
    at(2, "textDocument/hover", root, "main.tl", 1, 25),
    -- Byte 19 is the space before `F`.
    at(3, "textDocument/hover", root, "main.tl", 1, 19),
  }, { fs_docs(root) })
  local value = assert(hovered(ran, 2), ran.err)
  assert(value:find("cosmic.fs.read", 1, true) ~= nil, value)
  assert(hovered(ran, 3) == nil, "the space before F")
end

local function test_the_last_of_several_changes_is_the_text()
  local root = session_fixture.project()
  local good, bad = "local n: integer = 1\nreturn n\n", "local n: integer = 'x'\nreturn n\n"
  local fixed = served(root, { initialize(root), open(root, "main.tl", bad), changes(root, "main.tl", { bad, good }) })
  assert(counts(fixed) == "1,0", counts(fixed))
  local broken = served(root, { initialize(root), open(root, "main.tl", good), changes(root, "main.tl", { good, bad }) })
  assert(counts(broken) == "0,1", counts(broken))
end

local function test_a_message_with_no_method_is_never_answered()
  local root = session_fixture.project()
  local responses: {string} = {
    '{"jsonrpc":"2.0","id":null,"result":null}',
    '{"jsonrpc":"2.0","id":5,"result":1}',
    '{"jsonrpc":"2.0","id":6,"error":{"code":-32601,"message":"no"}}',
    '{"jsonrpc":"2.0"}',
  }
  local before = served(root, responses)
  assert(#before.sent == 0, table.concat(before.sent, "\n"))
  local messages: mut {string} = { initialize(root) }
  for _, response in ipairs(responses) do messages[#messages + 1] = response end
  local after = served(root, messages)
  assert(#after.sent == 1, table.concat(after.sent, "\n"))
  initialized(assert(after.sent[1]))
end

local function test_an_example_that_returns_nothing_is_refused()
  local root = session_fixture.project()
  local text = "local record Example\nend\n--- One.\nfunction Example.one()\n  assert(true)\nend\n"
  local refused = only(nth(served(root, { initialize(root), open(root, "it_example.tl", text) }), 1))
  assert(refused.message:find("an example file must return the table", 1, true), refused.message)
  local fine = served(root, { initialize(root), open(root, "it_example.tl", text .. "return Example\n") })
  assert(counts(fine) == "0", messages_of(nth(fine, 1)))
end

local function test_a_policy_outside_a_test_is_refused_and_nothing_else()
  local root = session_fixture.project()
  local text = 'local Test = require("cosmic.test")\nlocal unused = 1\n' ..
    'Test.policy { loopback = { "127.0.0.1" } }\nreturn {}\n'
  local refused = only(nth(served(root, { initialize(root), open(root, "it.tl", text) }), 1))
  assert(refused.message:find("only a test or example module declares what its tests read", 1, true),
    refused.message)
  assert(edge(refused, "start").line == 2, tostring(edge(refused, "start").line))
end

local function test_a_policy_the_build_refuses_is_all_a_test_publishes()
  local root = session_fixture.project()
  local text = 'local Test = require("cosmic.test")\nTest.policy { reads = {} }\n' ..
    "local function test_x() assert(true) end\n"
  local refused = only(nth(served(root, { initialize(root), open(root, "it_test.tl", text) }), 1))
  assert(refused.message:find("test.policy", 1, true), refused.message)
  assert(refused.message:find("unused", 1, true) == nil, refused.message)
end

local function test_a_message_is_worded_as_a_build_words_it()
  local root = session_fixture.project()
  local text = "local function f(a: integer): integer\n  local b = 1\n  return a\nend\nreturn f\n"
  local unused = only(nth(served(root, { initialize(root), open(root, "it.tl", text) }), 1))
  assert(unused.message == "unused variable b (unused_variable): name it `_` or `_b` to say it is meant to be " ..
      "unused, or remove it", unused.message)
  assert(unused.code == "unused_variable", tostring(unused.code))
end

local function test_a_record_shape_in_a_function_body_is_resolved_too()
  local root = session_fixture.project()
  -- One call at the top, one in a body, after a tab and a two-byte "é".
  local text = 'local Shape = require("cosmic.shape")\n' ..
    "local record R\n  n: integer\nend\n" ..
    'local TOP <const> = Shape.record_of("R")\n' ..
    "local function f(): integer\n" ..
    '\tlocal _ = "é" local S = Shape.record_of("R") local bad: integer = "x"\n' ..
    "  return assert(S:into({ n = 1 })).n + bad\nend\n" ..
    "local record Out\n  f: function(): integer\n  n: integer\nend\n" ..
    "local out: Out = { f = f, n = assert(TOP:into({ n = 2 })).n }\nreturn out\n"
  local ran = served(root, { initialize(root), open(root, "main.tl", text) })
  local found = only(nth(ran, 1))
  assert(found.message == "`\"x\"` is `string`, where `integer` is wanted as the value of `bad` (not_assignable): " ..
      "pass a value of type `integer`, or change the declaration to `string`", found.message)
  -- One call is in a body: the whole text is read for them.
  assert(ran.tally.whole_splices == 1, tostring(ran.tally.whole_splices))
  -- At `"x"`, counted in UTF-16 units: the tab and "é" are one each.
  local start = edge(found, "start")
  assert(start.line == 6 and start.character == 67, tostring(start.line) .. ":" .. tostring(start.character))
end
