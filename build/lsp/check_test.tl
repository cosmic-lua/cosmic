--- What `cosmic lsp` publishes of a document as a build refuses it
--- ([`build.lsp.check`], [`build.lsp.graph`]): a `require` position
--- refuses, a cycle of imports, a template, a global an earlier text
--- declared, the wording of a refused type-only `require`, cosmic's own
--- tree's stubs, and the name a declaration is read under; and the other
--- open documents a change or a close checks again
--- ([`build.lsp.publish`]).

local Fs = require("cosmic.fs")
local check = require("build.lsp.check")
local tree = require("build.tree")
local session_fixture = require("build.lsp.session_fixture")

local change, close, counts = session_fixture.change, session_fixture.close, session_fixture.counts
local edge = session_fixture.edge
local initialize, messages_of = session_fixture.initialize, session_fixture.messages_of
local nth, only, open = session_fixture.nth, session_fixture.only, session_fixture.open
local project, publications = session_fixture.project, session_fixture.publications
local served, serving = session_fixture.served, session_fixture.serving

--- A module with nothing in it, and one with a number in it, written as
--- the checker takes a module: its value is declared by a record.
local EMPTY <const> = "local record empty\nend\nlocal e: empty = {}\nreturn e\n"
local NUMBER <const> = "local record count\n  n: integer\nend\nlocal v: count = { n = 1 }\nreturn v\n"

--- A module that requires `name` and returns a record of its own.
local function importing(name: string): string
  return 'local ' .. name .. ' = require("' .. name .. '")\nprint(' .. name .. ')\n' ..
    "local record shape\nend\nlocal s: shape = {}\nreturn s\n"
end

local function test_a_require_into_a_closed_directory_is_refused_at_it()
  local root = project()
  assert(Fs.mkdirs(root .. "/lib/priv"))
  assert(Fs.write(root .. "/lib/priv/init.tl", EMPTY))
  assert(Fs.write(root .. "/lib/priv/x.tl", NUMBER))
  local text = 'local x = require("lib.priv.x")\nlocal n: integer = x.n\nreturn n\n'
  local refused = only(nth(served(root, { initialize(root), open(root, "main.tl", text) }), 1))
  assert(refused.message == "lib.priv.x is private to lib/priv/; only a file inside it may import " ..
      "it (its entry is lib/priv/init.tl), or the module can say `--- @public`", refused.message)
  local start = edge(refused, "start")
  assert(start.line == 0 and start.character == 18, tostring(start.line) .. ":" .. tostring(start.character))
  local inside = served(root, { initialize(root), open(root, "lib/priv/y.tl", text) })
  assert(counts(inside) == "0", messages_of(nth(inside, 1)))
end

--- A `require` is found as a build finds one: a name in long brackets,
--- but not a field named `require`; with no parentheses it is no call.
local function test_a_require_is_found_as_a_build_finds_it()
  local root = project()
  assert(Fs.mkdirs(root .. "/lib/priv"))
  assert(Fs.write(root .. "/lib/priv/init.tl", EMPTY))
  assert(Fs.write(root .. "/lib/priv/x.tl", NUMBER))
  local field = "local record object\n  require: function(string): integer\nend\n" ..
    "local o: object = { require = function(_: string): integer return 1 end }\n" ..
    'local n: integer = o.require("lib.priv.x")\nreturn n\n'
  local fine = served(root, { initialize(root), open(root, "main.tl", field) })
  assert(counts(fine) == "0", messages_of(nth(fine, 1)))
  local long = "local x = require([[lib.priv.x]])\nlocal n: integer = x.n\nreturn n\n"
  local refused = only(nth(served(root, { initialize(root), open(root, "main.tl", long) }), 1))
  assert(refused.message:find("lib.priv.x is private to lib/priv/", 1, true) == 1, refused.message)
  assert(edge(refused, "start").character == 18, tostring(edge(refused, "start").character))
  -- A call with a string in place of its arguments is not in the grammar,
  -- so a `require` with no parentheses is no require: the grammar refuses it.
  for _, argument in ipairs({ '"lib.priv.x"', "[[lib.priv.x]]" }) do
    local text = "local x = require " .. argument .. "\nlocal n: integer = x.n\nreturn n\n"
    local found = only(nth(served(root, { initialize(root), open(root, "main.tl", text) }), 1))
    assert(found.message == "a call with a string in place of its arguments is not in the grammar " ..
        "(string_call): put the string in parentheses: `f(" .. argument .. ")`", found.message)
  end
end

local function test_cosmics_own_tree_keeps_build_to_itself()
  local root = assert(Fs.mkdtemp("cosmic-lsp-"))
  -- What tells cosmic's own tree ([`build.tree`]).
  assert(Fs.mkdirs(root .. "/core"))
  assert(Fs.mkdirs(root .. "/build"))
  assert(Fs.write(root .. "/build/importer.tl", EMPTY))
  local text = 'local importer = require("build.importer")\nreturn importer\n'
  local built = assert(tree.built_from(root))
  local refused = only(nth(served(root, { initialize(root), open(root, "lib/thing.tl", text) }, nil, built), 1))
  assert(refused.message == "build.importer is private to build/ in cosmic's own tree; only build/, a main, a test " ..
      "and test support may import it", refused.message)
  local test = served(root, { initialize(root), open(root, "lib/thing_test.tl",
    'local importer = require("build.importer")\nlocal function test_it() assert(importer) end\n') }, nil, built)
  assert(counts(test) == "0", messages_of(nth(test, 1)))
end

local function test_a_cycle_of_imports_is_refused_in_each_document_of_it()
  local root = project()
  assert(Fs.write(root .. "/a.tl", importing("b")))
  assert(Fs.write(root .. "/b.tl", importing("a")))
  local send = serving(root)
  local first = send({ initialize(root), open(root, "a.tl", importing("b")),
    open(root, "b.tl", importing("a")) })
  local in_a, in_b = only(nth(first, 1)), only(nth(first, 2))
  assert(in_a.message == "a cycle of imports reaches a", in_a.message)
  -- Worded as the build words it, whichever document is checked: the
  -- build visits modules by import path.
  assert(in_b.message == "a cycle of imports reaches a", in_b.message)
  assert(edge(in_a, "start").character == 18, tostring(edge(in_a, "start").character))
  -- b no longer requires a: both documents are published again, clear.
  local after = publications(send({ change(root, "b.tl", EMPTY) }))
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
  assert(wrong.message == "`data.Page` has no field `nope` (field_unknown): declare `nope` in `data.Page`",
    wrong.message)
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
  local root = project()
  local ran = served(root, { initialize(root),
    open(root, "a.tl", "global G_X: integer\n" .. EMPTY),
    change(root, "a.tl", "global G_X: string\n" .. EMPTY),
    open(root, "b.tl", "global G_X: boolean\n" .. EMPTY),
  })
  assert(counts(ran) == "1,1,1", counts(ran) .. "\n" .. messages_of(nth(ran, 2)) .. "\n" ..
      messages_of(nth(ran, 3)))
  assert(messages_of(nth(ran, 3)) == "`global` declares a global, which only a declaration file does " ..
      "(global_in_program): write `local`; a program's globals are exactly the ones a declaration file " ..
      "(`.d.tl`) declares", messages_of(nth(ran, 3)))
end

local function test_a_refused_type_require_is_worded_as_a_build_words_it()
  local root = project()
  assert(Fs.write(root .. "/ledger.tl", "local total: integer = 1\nreturn total\n"))
  local text = 'local type L = require("ledger")\nlocal m: L.Month = { n = 1 }\nreturn m\n'
  local found = only(nth(served(root, { initialize(root), open(root, "main.tl", text) }), 1))
  assert(found.message == "the module `ledger` returns no declaration, so `L.Month` names no type " ..
      "(member_missing): return a record, class, interface or enum from `ledger` (`return Name`), " ..
      "or import a module that does", found.message)
  assert(edge(found, "start").line == 1 and edge(found, "start").character == 9,
    tostring(edge(found, "start").line) .. ":" .. tostring(edge(found, "start").character))
end

--- A standard-library module of cosmic's own tree is held to its stub:
--- it must end by returning a name whose last declaration spells its type.
--- The checker already refuses a module that returns anything else
--- (`export_not_declared`), wherever it stands, so no module it accepts
--- has a stub that keeps every statement.
local function test_cosmics_own_tree_holds_a_standard_module_to_its_stub()
  local root = project()
  local unpruned = "local x = 1\nreturn { x = x }\n"
  local refusal = "this module returns `{ x = x }`, which no declaration describes (export_not_declared): " ..
    "return a record, class, interface or enum of the module, or a local declared with its type"
  local elsewhere = only(nth(served(root, { initialize(root), open(root, "cosmic/thing.tl", unpruned) }), 1))
  assert(elsewhere.message == refusal, elsewhere.message)
  -- What tells cosmic's own tree ([`build.tree`]).
  assert(Fs.mkdirs(root .. "/core"))
  assert(Fs.mkdirs(root .. "/build"))
  assert(Fs.write(root .. "/build/importer.tl", EMPTY))
  local own = only(nth(served(root, { initialize(root), open(root, "cosmic/thing.tl", unpruned) }), 1))
  assert(own.message == refusal, own.message)
  local pruned = "--- Things.\nlocal record thing\nend\n\n--- Twice `n`.\n" ..
    "function thing.double(n: integer): integer\n  return n * 2\nend\n\nreturn thing\n"
  local good = served(root, { initialize(root), open(root, "cosmic/thing.tl", pruned) })
  assert(counts(good) == "0", messages_of(nth(good, 1)))
end

--- A declaration is read under its own `.d.tl` below the root, as a
--- build reads it: the module is the type it declares.
local function test_a_declaration_is_read_under_its_own_name()
  local root = project()
  assert(Fs.mkdirs(root .. "/lib"))
  assert(Fs.write(root .. "/lib/decl.d.tl", "--- @kind binding\nlocal record Decl\n  list: {integer}\nend\nreturn Decl\n"))
  local text = 'local d = require("lib.decl")\nlocal s: string = d.list\nreturn s\n'
  local found = only(nth(served(root, { initialize(root), open(root, "main.tl", text) }), 1))
  assert(found.message == "`d.list` is `{integer}`, where `string` is wanted as the value of `s` " ..
      "(not_assignable): pass a value of type `string`, or change the declaration to `{integer}`", found.message)
end

--- A project file named for a module of the language is never what a `require` of it reads, as in a build: the module is the
--- binary's own, which is a global.
local function test_a_file_named_for_a_module_of_the_language_is_not_what_its_require_reads()
  local root = project()
  assert(Fs.write(root .. "/math.d.tl", "--- @kind binding\nlocal record M\n  abs: function(integer): string\nend\nreturn M\n"))
  local text = 'local s: string = require("math").abs(-1)\nreturn s\n'
  local found = only(nth(served(root, { initialize(root), open(root, "main.tl", text) }), 1))
  assert(found.message:find("the project has no module `math` (require_unknown)", 1, true) ~= nil, found.message)
  assert(found.message:find("`math` is a global the language declares, available without `require`", 1, true) ~= nil,
    found.message)
end

--- A `.d.tl` beside a `.tl` of its module is refused by the build, and each of the two documents is told so at its first
--- line, in the words the build uses ([`build.driver.pairing`]); deleting the declaration clears it, though the pair was cached.
local function test_a_declaration_beside_its_source_is_refused_in_each_document_of_the_pair()
  local root = project()
  assert(Fs.mkdirs(root .. "/lib"))
  local declaration = "local record M\n  n: integer\nend\nreturn M\n"
  local source = "local record M\n  n: integer\nend\nlocal m: M = { n = 1 }\nreturn m\n"
  assert(Fs.write(root .. "/lib/m.d.tl", declaration))
  assert(Fs.write(root .. "/lib/m.tl", source))
  local send = serving(root)
  local first = send({ initialize(root), open(root, "lib/m.tl", source), open(root, "lib/m.d.tl", declaration) })
  local words = "lib/m.tl is already the module lib.m. A .d.tl is only for a module implemented in C, and the .tl is what " ..
    "is checked, so one module cannot have both. If the .tl is the module, delete lib/m.d.tl. To keep both, rename " ..
    "one of them so that they are different modules."
  local in_source, in_declaration = only(nth(first, 1)), only(nth(first, 2))
  assert(in_source.message == words, in_source.message)
  assert(in_declaration.message == words, in_declaration.message)
  assert(edge(in_source, "start").line == 0 and edge(in_source, "start").character == 0)
  -- The declaration is deleted and its document closed: the pair is gone, and the source is published clear.
  assert(Fs.remove(root .. "/lib/m.d.tl"))
  local after = send({ close(root, "lib/m.d.tl"), session_fixture.changed_on_disk(root, "lib/m.d.tl"),
    change(root, "lib/m.tl", source .. "\n") })
  local last = publications(after)
  local final = assert(last[#last])
  assert(final.uri:sub(-9) == "/lib/m.tl" and #final.diagnostics == 0, final.uri .. " " .. tostring(#final.diagnostics))
end

--- A `.d.tl` that names no kind is refused by the build, and its document is told so at its first line, in the words the build
--- uses ([`build.driver.naming`]); tagged a binding it is published clear, and tagged `language` outside the two files of
--- the globals it is refused again.
local function test_a_declaration_that_names_nothing_is_refused_in_its_document()
  local root = project()
  assert(Fs.mkdirs(root .. "/lib"))
  local record_text = "local record M\n  n: integer\nend\nreturn M\n"
  assert(Fs.write(root .. "/lib/m.d.tl", record_text))
  local send = serving(root)
  local first = send({ initialize(root), open(root, "lib/m.d.tl", record_text) })
  local told = only(nth(first, 1))
  assert(told.message == "a .d.tl must name what it is, and this one names nothing. If it declares a module " ..
      "implemented in C, add the line `--- @kind binding` to its leading comment; otherwise write it as a .tl (types and " ..
      "code in a .tl are checked and real at run time).", told.message)
  assert(edge(told, "start").line == 0 and edge(told, "start").character == 0)
  -- Tagged a binding, the document is published clear.
  local tagged = "--- @kind binding\n" .. record_text
  assert(Fs.write(root .. "/lib/m.d.tl", tagged))
  local after = send({ session_fixture.changed_on_disk(root, "lib/m.d.tl"), change(root, "lib/m.d.tl", tagged) })
  local last = assert(publications(after)[#publications(after)])
  assert(last.uri:sub(-11) == "/lib/m.d.tl" and #last.diagnostics == 0, last.uri .. " " .. tostring(#last.diagnostics))
  -- Tagged for the language, outside the two files of the globals, it is refused.
  local language = "--- @kind language\n" .. record_text
  assert(Fs.write(root .. "/lib/m.d.tl", language))
  local again = send({ session_fixture.changed_on_disk(root, "lib/m.d.tl"), change(root, "lib/m.d.tl", language) })
  local refused = assert(publications(again)[#publications(again)])
  local message = assert(refused.diagnostics[1]).message
  assert(#refused.diagnostics == 1 and message:find("`--- @kind language` is accepted only when building cosmic's own tree", 1, true) == 1, message)
end

--- The two files of the language's globals are accepted when they are opened in cosmic's own tree, and a project's file at the
--- same path is refused for the kind.
local function test_the_language_files_are_accepted_in_the_own_tree_and_refused_in_a_project()
  local text = "--- @kind language\ndo\nend\n"
  local root = assert(Fs.mkdtemp("cosmic-lsp-"))
  assert(Fs.mkdirs(root .. "/core"))
  assert(Fs.mkdirs(root .. "/build"))
  assert(Fs.mkdirs(root .. "/lang"))
  assert(Fs.write(root .. "/build/importer.tl", EMPTY))
  assert(Fs.write(root .. "/lang/stdlib.d.tl", text))
  local built = assert(tree.built_from(root))
  local own = served(root, { initialize(root), open(root, "lang/stdlib.d.tl", text) }, nil, built)
  assert(counts(own) == "0", messages_of(nth(own, 1)))
  for _, file in ipairs({ "lang/stdlib.d.tl", "lang/prelude.d.tl" }) do
    local project_root = project()
    assert(Fs.mkdirs(project_root .. "/lang"))
    assert(Fs.write(project_root .. "/" .. file, text))
    local told = only(nth(served(project_root, { initialize(project_root), open(project_root, file, text) }), 1))
    assert(told.message:find("`--- @kind language` is accepted only when building cosmic's own tree", 1, true) == 1, told.message)
  end
end

--- A pair that appears after a good stage, and one that is gone, are told with no change to the text of the open document:
--- the stage moves what the check was of, so the publish kept is made again.
local function test_a_pair_that_comes_and_goes_on_disk_moves_a_document_that_did_not_change()
  local root = project()
  assert(Fs.mkdirs(root .. "/lib"))
  local declaration = "local record M\n  n: integer\nend\nreturn M\n"
  local source = "local record M\n  n: integer\nend\nlocal m: M = { n = 1 }\nreturn m\n"
  assert(Fs.write(root .. "/lib/m.tl", source))
  local send = serving(root)
  local good = send({ initialize(root), open(root, "lib/m.tl", source) })
  assert(counts(good) == "0", messages_of(nth(good, 1)))
  -- The declaration appears on disk beside the source; the document is the same text.
  assert(Fs.write(root .. "/lib/m.d.tl", declaration))
  local refused = publications(send({ session_fixture.changed_on_disk(root, "lib/m.d.tl"),
    change(root, "lib/m.tl", source) }))
  local told = assert(refused[#refused])
  assert(told.uri:sub(-9) == "/lib/m.tl" and #told.diagnostics == 1, told.uri .. " " .. tostring(#told.diagnostics))
  -- It is deleted again; the document is still the same text.
  assert(Fs.remove(root .. "/lib/m.d.tl"))
  local cleared = publications(send({ session_fixture.changed_on_disk(root, "lib/m.d.tl"),
    change(root, "lib/m.tl", source) }))
  local clear = assert(cleared[#cleared])
  assert(clear.uri:sub(-9) == "/lib/m.tl" and #clear.diagnostics == 0, clear.uri .. " " .. tostring(#clear.diagnostics))
end

--- A pair under `testdata/` is a fixture of a test, left out of the program, and its documents are told nothing, though
--- another pair of the tree is refused.
local function test_a_pair_under_testdata_is_told_nothing_though_another_pair_is_refused()
  local root = project()
  assert(Fs.mkdirs(root .. "/lib"))
  assert(Fs.mkdirs(root .. "/testdata"))
  local declaration = "local record M\n  n: integer\nend\nreturn M\n"
  local source = "local record M\n  n: integer\nend\nlocal m: M = { n = 1 }\nreturn m\n"
  for _, dir in ipairs({ "lib", "testdata" }) do
    assert(Fs.write(root .. "/" .. dir .. "/m.d.tl", declaration))
    assert(Fs.write(root .. "/" .. dir .. "/m.tl", source))
  end
  local ran = served(root, { initialize(root), open(root, "lib/m.tl", source), open(root, "testdata/m.tl", source),
    open(root, "testdata/m.d.tl", declaration) })
  assert(#nth(ran, 1) == 1, messages_of(nth(ran, 1)))
  assert(#nth(ran, 2) == 0, messages_of(nth(ran, 2)))
  assert(#nth(ran, 3) == 0, messages_of(nth(ran, 3)))
end

--- Closing a document that stood for its file with another text checks
--- the other open documents again: the cycle of imports it closed is gone
--- with it.
local function test_closing_an_unsaved_document_checks_the_others_again()
  local root = project()
  local a = importing("b")
  assert(Fs.write(root .. "/a.tl", a))
  assert(Fs.write(root .. "/b.tl", importing("c")))
  assert(Fs.write(root .. "/c.tl", EMPTY))
  local send = serving(root)
  local first = send({ initialize(root), open(root, "a.tl", a),
    open(root, "c.tl", importing("a")) })
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
  local integer = "local record helper\nend\n\nfunction helper.twice(n: integer): integer\n  return n * 2\nend\n\nreturn helper\n"
  local text = "local record helper\nend\n\nfunction helper.twice(n: integer): string\n  return tostring(n * 2)\nend\n\n" ..
    "return helper\n"
  assert(Fs.write(root .. "/helper.tl", integer))
  local main = 'local helper = require("helper")\nlocal n: integer = helper.twice(2)\nreturn n\n'
  local send = serving(root)
  assert(counts(send({ initialize(root), open(root, "helper.tl", integer), open(root, "main.tl", main) })) ==
      "0,0")
  local changed = publications(send({ change(root, "helper.tl", text) }))
  assert(#changed == 4, tostring(#changed))
  local dependent = assert(changed[4])
  assert(dependent.uri:sub(-8) == "/main.tl", dependent.uri)
  assert(only(dependent.diagnostics).message == "`helper.twice(2)` is `string`, where `integer` is wanted " ..
      "as the value of `n` (not_assignable): pass a value of type `integer`, or change the declaration to `string`",
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

--- The dependents of a changed document are every open document that
--- reaches it through the modules on disk: one that requires a module
--- that requires it, and one the stage does not list, which requires one
--- that does.
local function test_a_dependent_reached_through_another_module_is_checked_again()
  local root = project()
  local integer = "local record helper\n  record Item\n    n: integer\n  end\nend\n\nreturn helper\n"
  local text = "local record helper\n  record Item\n    n: string\n  end\nend\n\nreturn helper\n"
  assert(Fs.write(root .. "/helper.tl", integer))
  assert(Fs.write(root .. "/mid.tl", 'local helper = require("helper")\nlocal type Item = helper.Item\n\n' ..
      "local record mid\nend\n\nfunction mid.item(): Item\n  return { n = 1 }\nend\n\nreturn mid\n"))
  local top = 'local mid = require("mid")\nlocal item = mid.item()\nlocal n: integer = item.n\nreturn n\n'
  assert(Fs.write(root .. "/top.tl", top))
  local send = serving(root)
  -- fresh.tl is on no disk: the stage lists no module of it.
  assert(counts(send({ initialize(root), open(root, "helper.tl", integer), open(root, "top.tl", top),
    open(root, "fresh.tl", top) })) == "0,0,0")
  local changed = publications(send({ change(root, "helper.tl", text) }))
  -- What each document was told after the change, by its file's name.
  local told: mut {string:string} = {}
  for i = 4, #changed do
    local publication = assert(changed[i])
    told[publication.uri:match("[^/]+$") or ""] = messages_of(publication.diagnostics)
  end
  local wrong = "`item.n` is `string`, where `integer` is wanted as the value of `n` (not_assignable): " ..
    "pass a value of type `integer`, or change the declaration to `string`"
  assert(told["top.tl"] == wrong, "the open document requiring mid, which requires helper: " ..
      (told["top.tl"] or "not published"))
  assert(told["fresh.tl"] == wrong, "the open document no stage lists, requiring mid: " ..
      (told["fresh.tl"] or "not published"))
end

--- In cosmic's own tree, a document of a tree of its own inside it
--- (`ci/`), which a build of it never reads, publishes nothing.
local function test_a_tree_of_its_own_inside_cosmics_publishes_nothing()
  local root = assert(Fs.mkdtemp("cosmic-lsp-"))
  -- What tells cosmic's own tree ([`build.tree`]).
  assert(Fs.mkdirs(root .. "/core"))
  assert(Fs.mkdirs(root .. "/build"))
  assert(Fs.write(root .. "/build/importer.tl", EMPTY))
  local bad = 'local n: integer = "no"\nreturn n\n'
  local ran = served(root, { initialize(root), open(root, "ci/thing.tl", bad), open(root, "cin/thing.tl", bad) }, nil,
    (assert(tree.built_from(root))))
  assert(counts(ran) == "0,1", counts(ran) .. "\n" .. messages_of(nth(ran, 2)))
end

--- A document that is no file below the root publishes nothing, which
--- no build there reads: one of another directory, an `untitled:` one,
--- and one whose path leaves the root by `..`. One below the root that
--- the stage does not list yet is the root's, and is checked, as is one
--- whose path leaves the root and comes back.
local function test_a_document_that_is_no_file_below_the_root_publishes_nothing()
  local root = project()
  local elsewhere = assert(Fs.mkdtemp("cosmic-lsp-"))
  local bad = 'local n: integer = "no"\nreturn n\n'
  local untitled = '{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":' ..
    '{"uri":"untitled:Untitled-1.tl","languageId":"teal","version":1,"text":' ..
    '"local n: integer = \\"no\\"\\nreturn n\\n"}}}'
  local ran = served(root, { initialize(root), open(elsewhere, "y.tl", bad), untitled,
    open(root, "../" .. (elsewhere:match("[^/]+$") or "") .. "/y.tl", bad), open(root, "sub/../new.tl", bad),
    open(root, "../" .. (root:match("[^/]+$") or "") .. "/back.tl", bad) })
  assert(counts(ran) == "0,0,0,1,1", counts(ran))
  local new = assert(publications(ran)[4])
  assert(new.uri:sub(-14) == "/sub/../new.tl", new.uri)
end

local function test_the_probe_made_for_a_document_goes_when_the_document_is_closed()
  local root = project()
  local checker = check.new(root, function(_: string) end, function(): check.Hinted
    return { databases = {}, public = {} }
  end)
  local document = check.document("file://" .. root .. "/main.tl", "main.tl", "local a = 1\nreturn a\n")
  check.opened(checker, document)
  assert(check.probe(checker, document, "local a = 2\nreturn a\n") ~= nil)
  assert(checker.probed ~= nil)
  -- The probe of another document stays.
  local other = check.document("file://" .. root .. "/other.tl", "other.tl", "return 1\n")
  check.opened(checker, other)
  check.closed(checker, other)
  assert(checker.probed ~= nil)
  check.closed(checker, document)
  assert(checker.probed == nil)
  check.close(checker)
end
