--- What `cosmic lsp` publishes of a project written in the new grammar, in a session that checks with the new checker
--- ([`build.grammar_mode`]): a module with `mut`, `name?: T` and a class checks clean; a type error, a syntax error and a
--- module that requires another are published where they are, and the dependents of a module are checked again when what it
--- serves changes. Every session here asks for the new checker, whatever the mode of the suite.
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Stream = require("cosmic.stream")
local Test = require("cosmic.test")
local check = require("build.lsp.check")
local session = require("build.lsp.session")
local session_fixture = require("build.lsp.session_fixture")
local source = require("build.lsp.source")
local syntax_read = require("build.lsp.syntax_read")

Test.policy{ cpu_features = true, profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" } } }

local change, counts, edge = session_fixture.change, session_fixture.counts, session_fixture.edge
local initialize, messages_of = session_fixture.initialize, session_fixture.messages_of
local nth, only, open = session_fixture.nth, session_fixture.only, session_fixture.open
local project, publications = session_fixture.project, session_fixture.publications

--- A module in the new grammar: a record with a `mut` field and an optional one, a class with a method, and a function
--- with a `mut` collection and an optional parameter.
local BOX <const> = table.concat({
  "local record Box",
  "  mut n: integer",
  "  name?: string",
  "end",
  "local class Counter",
  "  label: string",
  "  mut count: integer",
  "  function bump(self, by: integer): integer",
  "    self.count = self.count + by",
  "    return self.count",
  "  end",
  "end",
  "local function make(xs: mut {string}, skip?: integer): Box",
  "  local counter: Counter = { label = \"c\", count = 0 }",
  "  return { n = counter:bump(#xs + (skip or 0)) }",
  "end",
  "local record Api",
  "  make: function(xs: mut {string}, skip?: integer): Box",
  "end",
  "local api: Api = { make = make }",
  "return api",
  "",
}, "\n")

--- What a session of the new checker at `root` publishes of the messages, one batch.
local function served(root: string, messages: {string}): session_fixture.Ran
  return session_fixture.served(root, messages)
end

local function test_a_module_with_mut_an_optional_field_and_a_class_checks_clean()
  local root = project()
  local ran = served(root, { initialize(root), open(root, "box.tl", BOX) })
  assert(counts(ran) == "0", messages_of(nth(ran, 1)))
end

local function test_a_type_error_is_published_where_the_new_checker_finds_it()
  local root = project()
  local text = "local record Box\n  mut n: integer\nend\nlocal box: Box = { n = 1 }\nbox.n = \"two\"\nreturn box\n"
  local told = only(nth(served(root, { initialize(root), open(root, "box.tl", text) }), 1))
  assert(told.message:find("string", 1, true) ~= nil and told.message:find("integer", 1, true) ~= nil, told.message)
  assert(edge(told, "start").line == 4, tostring(edge(told, "start").line))
end

local function test_a_field_that_is_not_mut_is_refused_when_it_is_assigned()
  local root = project()
  local text = "local record Box\n  n: integer\nend\nlocal box: Box = { n = 1 }\nbox.n = 2\nreturn box\n"
  local told = only(nth(served(root, { initialize(root), open(root, "box.tl", text) }), 1))
  assert(edge(told, "start").line == 4, tostring(edge(told, "start").line) .. " " .. told.message)
end

local function test_a_syntax_error_is_published_in_the_parsers_words_at_its_place()
  local root = project()
  local told = only(nth(served(root, { initialize(root), open(root, "bad.tl", "local x: integer = 1\nlocal y: = 2\nreturn x\n") }), 1))
  assert(edge(told, "start").line == 1, tostring(edge(told, "start").line))
  assert(told.message:find("(", 1, true) ~= nil, told.message)
end

local function test_a_session_of_the_new_grammar_offers_formatting_and_lays_out_a_document()
  local root = project()
  local ran = served(root, { initialize(root), open(root, "box.tl", BOX), session_fixture.format(2, root, "box.tl") })
  local init = session_fixture.initialized(session_fixture.answer(ran, 1))
  assert(init.capabilities.documentFormattingProvider == true, "formatting is not offered")
  assert(init.capabilities.hoverProvider == true)
  local body = session_fixture.answer(ran, 2)
  assert(body:find('"error"', 1, true) == nil, body)
  local loose = served(root, { initialize(root), open(root, "n.tl", "local   n =  1\nreturn n\n"),
    session_fixture.format(2, root, "n.tl") })
  local laid = session_fixture.answer(loose, 2)
  assert(laid:find('"newText":"local n = 1\\nreturn n\\n"', 1, true) ~= nil, laid)
end

--- A project whose `helper` is in the new grammar and which `main` requires, each on disk.
local function helped(helper: string): string
  local root = project()
  assert(Fs.write(root .. "/helper.tl", helper))
  assert(Fs.write(root .. "/main.tl", 'local helper = require("helper")\nlocal n: integer = helper.twice(2)\nreturn n\n'))
  return root
end

local TWICE <const> = "local record Api\n  twice: function(n: integer): integer\nend\n" ..
  "local function twice(n: integer): integer\n  return n * 2\nend\nlocal api: Api = { twice = twice }\nreturn api\n"
local TEXT <const> = "local record Api\n  twice: function(n: integer): string\nend\n" ..
  "local function twice(n: integer): string\n  return tostring(n * 2)\nend\nlocal api: Api = { twice = twice }\nreturn api\n"

local function test_a_module_is_read_through_the_module_it_requires()
  local root = helped(TWICE)
  local main = assert(Fs.read(root .. "/main.tl"))
  local clean = served(root, { initialize(root), open(root, "main.tl", main) })
  assert(counts(clean) == "0", messages_of(nth(clean, 1)))
  -- The same document against a helper that serves another type, open beside it.
  local wrong = served(root, { initialize(root), open(root, "helper.tl", TEXT), open(root, "main.tl", main) })
  local told = only(nth(wrong, 2))
  assert(edge(told, "start").line == 1, tostring(edge(told, "start").line) .. " " .. told.message)
end

--- The dependents are checked again only where what a module serves changed: a comment moves no token, a type does.
local function test_the_dependents_of_a_module_are_checked_again_when_what_it_serves_changes()
  local root = helped(TWICE)
  local main = assert(Fs.read(root .. "/main.tl"))
  local start = { initialize(root), open(root, "helper.tl", TWICE), open(root, "main.tl", main) }
  -- What a document serves is keyed once no message waits, so the change is sent after the open with time between.
  local function then_changed(text: string): session_fixture.Ran
    return session_fixture.served_between(root, { start, { change(root, "helper.tl", text) } },
      function(_after: integer) end)
  end
  local quiet = then_changed(TWICE .. "-- Twice.\n")
  assert(quiet.dependents == 0, tostring(quiet.dependents))
  local typed = then_changed(TEXT)
  assert(typed.dependents == 1, tostring(typed.dependents))
  local last = assert(publications(typed)[#publications(typed)])
  assert(last.uri:sub(-8) == "/main.tl" and #last.diagnostics == 1, last.uri)
end

--- The calls of [`Shape.record_of`] are resolved in the text the checker reads, and a place after one is the document's own
--- place: the error after the call on its line is at the column the document has it, not the spliced text's.
local function test_a_place_after_a_resolved_shape_call_is_the_documents_own()
  local root = project()
  local line = 'local _spec = Shape.record_of("R") local bad: integer = "x"'
  local text = 'local Shape = require("cosmic.shape")\nlocal record R\n  n: integer\nend\n' .. line ..
    "\nlocal r: R = { n = bad }\nreturn r\n"
  local ran = served(root, { initialize(root), open(root, "shaped.tl", text) })
  local told = only(nth(ran, 1))
  assert(edge(told, "start").line == 4, tostring(edge(told, "start").line) .. " " .. told.message)
  assert(edge(told, "start").character == (line:find('"x"', 1, true) or 0) - 1,
    tostring(edge(told, "start").character) .. " " .. told.message)
  assert(ran.tally.whole_splices == 1, tostring(ran.tally.whole_splices))
end

--- A module in the new grammar (`mut`, `name?: T`) that a dependent reads through its stub.
local HELPER <const> = table.concat({
  "local record Box",
  "  mut n: integer",
  "  name?: string",
  "end",
  "local record Api",
  "  make: function(n: integer): Box",
  "end",
  "local function make(n: integer): Box",
  "  return { n = n }",
  "end",
  "local api: Api = { make = make }",
  "return api",
  "",
}, "\n")

local MAIN <const> = 'local helper = require("helper")\nlocal box = helper.make(1)\nlocal n: integer = box.n\nreturn n\n'

--- The tree is staged with the session's checker: a module in the new grammar on disk is a module, and is read through the
--- stub the stage derived (a stage by the fork's, which cannot read `mut`, finds no module `helper`).
local function test_a_module_in_the_new_grammar_on_disk_is_staged_and_read()
  local root = project()
  assert(Fs.write(root .. "/helper.tl", HELPER))
  assert(Fs.write(root .. "/main.tl", MAIN))
  local ran = served(root, { initialize(root), open(root, "main.tl", MAIN) })
  assert(counts(ran) == "0", messages_of(nth(ran, 1)) .. "\n" .. ran.err)
  assert(ran.tally.database_stubs == 1, tostring(ran.tally.database_stubs))
end

--- An open module that was edited has its stub made here from the new parser (the scratch database's row): the fork's cannot
--- read the module, and serves it whole.
local function test_an_open_module_in_the_new_grammar_is_served_as_a_stub_made_here()
  local root = project()
  assert(Fs.write(root .. "/helper.tl", HELPER))
  local ran = served(root, { initialize(root), open(root, "helper.tl", HELPER .. "-- edited\n"),
    open(root, "main.tl", MAIN) })
  assert(counts(ran) == "0,0", counts(ran) .. messages_of(nth(ran, 2)))
  assert(ran.tally.made_stubs == 1, tostring(ran.tally.made_stubs))
end

--- What a module serves its dependents is keyed by the tokens of its served text as the new lexer reads them.
local function test_what_a_module_serves_is_keyed_by_the_new_lexer()
  local root = project()
  assert(Fs.write(root .. "/helper.tl", HELPER))
  local s = session.new(root)
  local messages = { initialize(root), open(root, "helper.tl", HELPER), open(root, "main.tl", MAIN) }
  session.serve(s, Stream.from_string(session_fixture.framed(messages)), function(_: string): boolean, string
    return true, ""
  end)
  local named = assert(source.module(s.checker.source, "helper.tl"))
  local served_form = assert(source.served(s.checker.source, named.path,
    check.open_files(s.checker), true))
  local expected = Hash.hex_sha256(table.concat(syntax_read.token_parts(served_form.text, served_form.file), "\0"))
  local keyed = ""
  for uri, key in pairs(s.queue.served) do
    if uri:sub(-10) == "/helper.tl" then keyed = key end
  end
  assert(keyed ~= "", "the module was not keyed")
  assert(keyed == expected, "the key is not the new lexer's")
end

--- A template is checked as a build checks one: its Teal translated, then read as the new grammar.
local function test_a_template_is_checked_as_a_build_checks_one()
  local root = project()
  assert(Fs.write(root .. "/data.tl", "local record data\n  record Page\n    title: string\n  end\nend\nreturn data\n"))
  local good = "{{type Page from data}}{{mode text}}one {{.title}}"
  assert(Fs.write(root .. "/page.tmpl", good))
  local valid = served(root, { initialize(root), open(root, "page.tmpl", good) })
  assert(counts(valid) == "0", messages_of(nth(valid, 1)))
  local wrong = only(nth(served(root, { initialize(root),
    open(root, "page.tmpl", "{{type Page from data}}{{mode text}}one {{.nope}}") }), 1))
  assert(wrong.message:find("nope", 1, true) ~= nil, wrong.message)
  -- A place in the template's Teal is none in the template: its start.
  assert(edge(wrong, "start").line == 0 and edge(wrong, "start").character == 0)
end

--- A module the document requires whose types do not stand is flagged where the document requires it: the module is not
--- checked, and its own errors show only where it is open.
local function test_a_broken_dependency_shows_in_the_document_that_requires_it()
  local root = project()
  local helper = "local record Api\n  f: function(): Nope\nend\nlocal function f(): integer\n  return 1\nend\n" ..
    "local api: Api = { f = f }\nreturn api\n"
  assert(Fs.write(root .. "/helper.tl", helper))
  local main = 'local helper = require("helper")\nlocal n: integer = helper.f()\nreturn n\n'
  assert(Fs.write(root .. "/main.tl", main))
  local told = nth(served(root, { initialize(root), open(root, "main.tl", main) }), 1)
  assert(#told >= 1, "a dependency that does not stand is silent")
  local first = assert(told[1])
  assert(first.message:find("Nope", 1, true) ~= nil, messages_of(told))
  assert(edge(first, "start").line == 0, tostring(edge(first, "start").line))
end
