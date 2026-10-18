--- What `cosmic lsp` publishes of a document as a build refuses it
--- ([`build.lsp.check`], [`build.lsp.graph`]): a `require` position
--- refuses, a cycle of imports, a template, a global an earlier text
--- declared, the wording of a refused type-only `require`, cosmic's own
--- tree's stubs, and the name a declaration is read under; and the other
--- open documents a change or a close checks again
--- ([`build.lsp.publish`]).

local Fs = require("cosmic.fs")
local session_fixture = require("build.lsp.session_fixture")

local change, close, counts = session_fixture.change, session_fixture.close, session_fixture.counts
local edge = session_fixture.edge
local initialize, messages_of = session_fixture.initialize, session_fixture.messages_of
local nth, only, open = session_fixture.nth, session_fixture.only, session_fixture.open
local project, publications = session_fixture.project, session_fixture.publications
local served, serving = session_fixture.served, session_fixture.serving

local function test_a_require_into_a_closed_directory_is_refused_at_it()
  local root = project()
  assert(Fs.mkdirs(root .. "/lib/priv"))
  assert(Fs.write(root .. "/lib/priv/init.tl", "return {}\n"))
  assert(Fs.write(root .. "/lib/priv/x.tl", "return { n = 1 }\n"))
  local text = 'local x = require("lib.priv.x")\nreturn x\n'
  local refused = only(nth(served(root, { initialize(root), open(root, "main.tl", text) }), 1))
  assert(refused.message == "lib.priv.x is private to lib/priv/; only a file inside it may import " ..
      "it (its entry is lib/priv/init.tl)", refused.message)
  local start = edge(refused, "start")
  assert(start.line == 0 and start.character == 18, tostring(start.line) .. ":" .. tostring(start.character))
  local inside = served(root, { initialize(root), open(root, "lib/priv/y.tl", text) })
  assert(counts(inside) == "0", messages_of(nth(inside, 1)))
end

--- A `require` is found as a build finds one: with no parentheses, or a
--- name in long brackets, but not a field named `require`.
local function test_a_require_is_found_as_a_build_finds_it()
  local root = project()
  assert(Fs.mkdirs(root .. "/lib/priv"))
  assert(Fs.write(root .. "/lib/priv/init.tl", "return {}\n"))
  assert(Fs.write(root .. "/lib/priv/x.tl", "return { n = 1 }\n"))
  local field = "local o = { require = function(_: string): integer return 1 end }\n" ..
    'local n: integer = o.require("lib.priv.x")\nreturn n\n'
  local fine = served(root, { initialize(root), open(root, "main.tl", field) })
  assert(counts(fine) == "0", messages_of(nth(fine, 1)))
  for _, text in ipairs({ 'local x = require "lib.priv.x"\nreturn x\n',
      "local x = require [[lib.priv.x]]\nreturn x\n" }) do
    local refused = only(nth(served(root, { initialize(root), open(root, "main.tl", text) }), 1))
    assert(refused.message:find("lib.priv.x is private to lib/priv/", 1, true) == 1, refused.message)
    assert(edge(refused, "start").character == 18, text .. tostring(edge(refused, "start").character))
  end
end

local function test_cosmics_own_tree_keeps_build_to_itself()
  local root = assert(Fs.mkdtemp("cosmic-lsp-"))
  -- What tells cosmic's own tree ([`build.tree`]).
  assert(Fs.mkdirs(root .. "/core"))
  assert(Fs.mkdirs(root .. "/build"))
  assert(Fs.write(root .. "/build/importer.tl", "return {}\n"))
  local text = 'local importer = require("build.importer")\nreturn importer\n'
  local refused = only(nth(served(root, { initialize(root), open(root, "lib/thing.tl", text) }), 1))
  assert(refused.message == "build.importer is private to build/; only build/, cmd/, test/ and " ..
      "tests may import it", refused.message)
  local test = served(root, { initialize(root), open(root, "lib/thing_test.tl",
    'local importer = require("build.importer")\nlocal function test_it() assert(importer) end\n') })
  assert(counts(test) == "0", messages_of(nth(test, 1)))
end

local function test_a_cycle_of_imports_is_refused_in_each_document_of_it()
  local root = project()
  assert(Fs.write(root .. "/a.tl", 'local b = require("b")\nreturn { b = b }\n'))
  assert(Fs.write(root .. "/b.tl", 'local a = require("a")\nreturn { a = a }\n'))
  local send = serving(root)
  local first = send({ initialize(root), open(root, "a.tl", 'local b = require("b")\nreturn { b = b }\n'),
    open(root, "b.tl", 'local a = require("a")\nreturn { a = a }\n') })
  local in_a, in_b = only(nth(first, 1)), only(nth(first, 2))
  assert(in_a.message == "a cycle of imports reaches a", in_a.message)
  -- Worded as the build words it, whichever document is checked: the
  -- build visits modules by import path.
  assert(in_b.message == "a cycle of imports reaches a", in_b.message)
  assert(edge(in_a, "start").character == 18, tostring(edge(in_a, "start").character))
  -- b no longer requires a: both documents are published again, clear.
  local after = publications(send({ change(root, "b.tl", "return {}\n") }))
  assert(#after == 4, tostring(#after))
  local b, a = assert(after[3]), assert(after[4])
  assert(b.uri:sub(-5) == "/b.tl" and #b.diagnostics == 0, b.uri)
  assert(a.uri:sub(-5) == "/a.tl" and #a.diagnostics == 0, a.uri)
end

local function test_a_template_is_checked_as_a_build_checks_one()
  local root = project()
  assert(Fs.write(root .. "/data.tl", "local record data\n  record Page\n    title: string\n  end\nend\nreturn data\n"))
  local good = "{{type Page from data}}{{mode text}}one {{.title}}"
  assert(Fs.write(root .. "/page.tmpl", good))
  local valid = served(root, { initialize(root), open(root, "page.tmpl", good) })
  assert(counts(valid) == "0", messages_of(nth(valid, 1)))
  local wrong = only(nth(served(root, { initialize(root),
    open(root, "page.tmpl", "{{type Page from data}}{{mode text}}one {{.nope}}") }), 1))
  assert(wrong.message:find("invalid key 'nope' in record 'd' of type data.Page", 1, true) == 1, wrong.message)
  -- A place in the template's Teal is none in the template: its start.
  assert(edge(wrong, "start").line == 0 and edge(wrong, "start").character == 0)
  local broken = only(nth(served(root, { initialize(root),
    open(root, "page.tmpl", "{{type Page from data}}\n{{mode text}}one {{.title") }), 1))
  assert(broken.message == "unterminated action: no closing }}", broken.message)
  assert(edge(broken, "start").line == 1 and edge(broken, "start").character == 17,
    tostring(edge(broken, "start").line) .. ":" .. tostring(edge(broken, "start").character))
end

--- A global an earlier text declared is no longer declared: neither its
--- own document's next text nor another document is checked against it.
local function test_a_global_an_earlier_text_declared_is_gone()
  local root = assert(Fs.mkdtemp("cosmic-lsp-"))
  local ran = served(root, { initialize(root),
    open(root, "a.tl", "global G_X: integer\nreturn {}\n"),
    change(root, "a.tl", "global G_X: string\nreturn {}\n"),
    open(root, "b.tl", "global G_X: boolean\nreturn {}\n"),
  })
  assert(counts(ran) == "1,1,1", counts(ran) .. "\n" .. messages_of(nth(ran, 2)) .. "\n" ..
      messages_of(nth(ran, 3)))
  assert(messages_of(nth(ran, 3)):find("a global is not allowed", 1, true) ~= nil, messages_of(nth(ran, 3)))
end

local function test_a_refused_type_require_is_worded_as_a_build_words_it()
  local root = project()
  assert(Fs.write(root .. "/ledger.tl", "local record Ledger\n  record Month\n    n: integer\n  end\n" ..
      "  total: integer\nend\nlocal l: Ledger = { total = 1 }\nreturn l\n"))
  local text = 'local type L = require("ledger")\nlocal m: L.Month = { n = 1 }\nreturn m\n'
  local found = nth(served(root, { initialize(root), open(root, "main.tl", text) }), 1)
  assert(#found == 2, messages_of(found))
  local refused, unknown = assert(found[1]), assert(found[2])
  assert(refused.message == "'require' did not return a type, got record Ledger -- ledger returns " ..
      "a value of its record, not the record type: a `local type` require needs the type, as " ..
      "`local record M ... end return M` or a `.d.tl` does; or require it as a value", refused.message)
  -- No type is reached through `L`: what follows from the refusal is
  -- told nothing more.
  assert(unknown.message == "unknown type L.Month", unknown.message)
end

local function test_cosmics_own_tree_holds_a_standard_module_to_its_stub()
  local root = assert(Fs.mkdtemp("cosmic-lsp-"))
  local unpruned = "local x = 1\nreturn { x = x }\n"
  local elsewhere = served(root, { initialize(root), open(root, "cosmic/thing.tl", unpruned) })
  assert(counts(elsewhere) == "0", messages_of(nth(elsewhere, 1)))
  -- What tells cosmic's own tree ([`build.tree`]).
  assert(Fs.mkdirs(root .. "/core"))
  assert(Fs.mkdirs(root .. "/build"))
  assert(Fs.write(root .. "/build/importer.tl", "return {}\n"))
  local own = only(nth(served(root, { initialize(root), open(root, "cosmic/thing.tl", unpruned) }), 1))
  assert(own.message:find("its stub keeps every statement", 1, true) ~= nil, own.message)
  local pruned = "--- Things.\nlocal record thing\nend\n\n--- Twice `n`.\n" ..
    "function thing.double(n: integer): integer\n  return n * 2\nend\n\nreturn thing\n"
  local good = served(root, { initialize(root), open(root, "cosmic/thing.tl", pruned) })
  assert(counts(good) == "0", messages_of(nth(good, 1)))
end

--- A declaration is read under its own `.d.tl` below the root, as a
--- build reads it: a type inferred in it is said to be.
local function test_a_declaration_is_read_under_its_own_name()
  local root = project()
  assert(Fs.mkdirs(root .. "/lib"))
  assert(Fs.write(root .. "/lib/decl.d.tl", 'local pair = { 1, "a" }\nreturn { pair = pair }\n'))
  assert(Fs.write(root .. "/lib/decl.tl", "return { pair = { 1 } }\n"))
  local text = 'local d = require("lib.decl")\nlocal s: string = d.list\nreturn s\n'
  local found = only(nth(served(root, { initialize(root), open(root, "main.tl", text) }), 1))
  assert(found.message:find("(inferred at " .. root .. "/lib/decl.d.tl:1:14)", 1, true) ~= nil, found.message)
end

--- Closing a document that stood for its file with another text checks
--- the other open documents again: the cycle of imports it closed is gone
--- with it.
local function test_closing_an_unsaved_document_checks_the_others_again()
  local root = project()
  local a = 'local b = require("b")\nreturn { b = b }\n'
  assert(Fs.write(root .. "/a.tl", a))
  assert(Fs.write(root .. "/b.tl", 'local c = require("c")\nreturn { c = c }\n'))
  assert(Fs.write(root .. "/c.tl", "return {}\n"))
  local send = serving(root)
  local first = send({ initialize(root), open(root, "a.tl", a),
    open(root, "c.tl", 'local a = require("a")\nreturn { a = a }\n') })
  assert(counts(first) == "0,1,1", counts(first))
  assert(only(nth(first, 3)).message == "a cycle of imports reaches a", messages_of(nth(first, 3)))
  local closed = publications(send({ close(root, "c.tl") }))
  assert(#closed == 5, tostring(#closed))
  local c, a_again = assert(closed[4]), assert(closed[5])
  assert(c.uri:sub(-5) == "/c.tl" and #c.diagnostics == 0, c.uri)
  assert(a_again.uri:sub(-5) == "/a.tl" and #a_again.diagnostics == 0, a_again.uri)
end

--- A change of an open module checks again the open documents that
--- require it, once its own check is published, and so does closing it;
--- changes read together are checked as their last.
local function test_the_dependents_of_a_changed_or_closed_document_are_checked_again()
  local root = project()
  local integer = "local function twice(n: integer): integer return n * 2 end\nreturn { twice = twice }\n"
  local text = "local function twice(n: integer): string return tostring(n * 2) end\n" ..
    "return { twice = twice }\n"
  assert(Fs.write(root .. "/helper.tl", integer))
  local main = 'local helper = require("helper")\nlocal n: integer = helper.twice(2)\nreturn n\n'
  local send = serving(root)
  assert(counts(send({ initialize(root), open(root, "helper.tl", integer), open(root, "main.tl", main) })) ==
      "0,0")
  local changed = publications(send({ change(root, "helper.tl", text) }))
  assert(#changed == 4, tostring(#changed))
  local dependent = assert(changed[4])
  assert(dependent.uri:sub(-8) == "/main.tl", dependent.uri)
  assert(only(dependent.diagnostics).message:find("got string", 1, true) ~= nil,
    messages_of(dependent.diagnostics))
  local closed = publications(send({ close(root, "helper.tl") }))
  assert(#closed == 6, tostring(#closed))
  local cleared = assert(closed[6])
  assert(cleared.uri:sub(-8) == "/main.tl" and #cleared.diagnostics == 0, cleared.uri)
  -- Read together, a change and its undoing are one change, to the text
  -- main was checked against: helper alone is published.
  local again = serving(root)
  again({ initialize(root), open(root, "helper.tl", integer), open(root, "main.tl", main) })
  local undone = publications(again({ change(root, "helper.tl", text), change(root, "helper.tl", integer) }))
  assert(#undone == 3, tostring(#undone))
end
