--- What the program a session of `cosmic lsp` holds under the new checker ([`build.lsp.held`]) does between checks: an edit shows
--- an error and its fix clears it, the program is the session's and not each check's, a module served otherwise than it was
--- is put in it, a module the stage did not list is found once it does, and a long session of edits holds no more than a
--- short one.
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local Stream = require("cosmic.stream")
local Test = require("cosmic.test")
local check = require("build.lsp.check")
local session = require("build.lsp.session")
local held = require("build.lsp.held")
local schema = require("build.schema")
local session_fixture = require("build.lsp.session_fixture")

Test.policy{ profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" } } }

local change, changed_on_disk, counts = session_fixture.change, session_fixture.changed_on_disk, session_fixture.counts
local initialize, messages_of = session_fixture.initialize, session_fixture.messages_of
local nth, open, project = session_fixture.nth, session_fixture.open, session_fixture.project
local serving = session_fixture.serving

local HELPER <const> = "local record Api\n  twice: function(n: integer): integer\nend\n" ..
  "local function twice(n: integer): integer\n  return n * 2\nend\nlocal api: Api = { twice = twice }\nreturn api\n"
local RETYPED <const> = "local record Api\n  twice: function(n: integer): string\nend\n" ..
  "local function twice(n: integer): string\n  return tostring(n * 2)\nend\nlocal api: Api = { twice = twice }\nreturn api\n"
local MAIN <const> = 'local helper = require("helper")\nlocal n: integer = helper.twice(2)\nreturn n\n'

--- A project with `helper.tl` and `main.tl` on disk.
local function helped(): string
  local root = project()
  assert(Fs.write(root .. "/helper.tl", HELPER))
  assert(Fs.write(root .. "/main.tl", MAIN))
  return root
end

--- A checker at `root`, and the document `name` of it with `text`.
local function checker_at(root: string): check.Checker
  return check.new(root, function(_line: string) end, function(): check.Hinted
    return { databases = {}, public = {} }
  end)
end

local function document_of(root: string, name: string, text: string): check.Document
  return check.document("file://" .. root .. "/" .. name, name, text)
end

local function test_an_error_appears_when_a_document_is_edited_and_clears_when_it_is_fixed()
  local root = helped()
  local send = serving(root)
  local wrong = (MAIN:gsub("integer", "string"))
  send({ initialize(root), open(root, "main.tl", MAIN) })
  send({ change(root, "main.tl", wrong) })
  local ran = send({ change(root, "main.tl", MAIN) })
  assert(counts(ran) == "0,1,0", counts(ran))
  assert(messages_of(nth(ran, 2)):find("integer", 1, true) ~= nil, messages_of(nth(ran, 2)))
end

--- Serves `messages` to the session `s` in one stream, and answers the program it held as each message went out, once it held one.
local function programs_of(s: session.State, messages: {string}): {held.Program}
  local seen: mut {held.Program} = {}
  session.serve(s, Stream.from_string(session_fixture.framed(messages)), function(_: string): boolean, string
    local program = s.checker.program
    if program ~= nil then seen[#seen + 1] = program end
    return true, ""
  end)
  return seen
end

local function test_the_session_holds_one_program_for_all_its_checks()
  local root = helped()
  local s = session.new(root)
  local seen = programs_of(s, { initialize(root), open(root, "main.tl", MAIN), change(root, "main.tl", MAIN .. "-- one\n"),
    change(root, "main.tl", MAIN .. "-- two\n"), open(root, "helper.tl", HELPER) })
  local program = assert(seen[1], "no program after the first check")
  assert((s.checker.ran["main.tl"] or 0) >= 2, tostring(s.checker.ran["main.tl"]))
  for n, held_then in ipairs(seen) do
    assert(held_then == program, "the program was made again for the message " .. tostring(n))
  end
end

local function test_an_edit_lowers_the_document_again_and_not_the_standard_library_or_what_it_reads()
  local root = helped()
  local checker = checker_at(root)
  local main = document_of(root, "main.tl", MAIN)
  check.opened(checker, main)
  assert(#check.diagnose(checker, main, "utf-16") == 0)
  local program = assert(checker.program)
  local lowered = program.build.timing.lowerings
  assert(lowered > 2, "the first check lowers the library, the helper and the document")
  for n = 1, 3 do
    check.set_text(main, MAIN .. "-- " .. tostring(n) .. "\n")
    assert(#check.diagnose(checker, main, "utf-16") == 0)
    assert(checker.program == program, "the program was made again")
    assert(program.build.timing.lowerings == lowered + n,
      ("edit %d lowered %d modules, one was wanted"):format(n, program.build.timing.lowerings - lowered - n + 1))
  end
end

--- What a session at `root` publishes of `first`, then of `second` once `between` has run: one session, so the program it holds
--- is the one the first batch made.
local function then_(root: string, first: {string}, between: function(), second: {string}): session_fixture.Ran
  return session_fixture.served_between(root, { first, second }, function(_after: integer)
    between()
  end)
end

local function test_a_module_changed_on_disk_is_served_to_the_document_open_again()
  local root = helped()
  local ran = then_(root, { initialize(root), open(root, "main.tl", MAIN) }, function()
    assert(Fs.write(root .. "/helper.tl", RETYPED))
  end, { changed_on_disk(root, "helper.tl") })
  assert(counts(ran) == "0,1", counts(ran))
  assert(messages_of(nth(ran, 2)):find("string", 1, true) ~= nil, messages_of(nth(ran, 2)))
end

local function test_a_module_removed_from_disk_is_not_found_any_more()
  local root = helped()
  local ran = then_(root, { initialize(root), open(root, "main.tl", MAIN) }, function()
    assert(Fs.remove(root .. "/helper.tl"))
  end, { changed_on_disk(root, "helper.tl") })
  assert(counts(ran) == "0,1", counts(ran))
end

--- More modules served otherwise than they were than the program is put to ([`build.lsp.check`]) make it again, to the same
--- answers.
local function test_many_modules_changed_on_disk_make_the_program_again()
  local root = project()
  local requires: mut {string} = {}
  local sum: mut {string} = {}
  for n = 1, 14 do
    local name = "mod" .. tostring(n)
    assert(Fs.write(root .. "/" .. name .. ".tl", "local record Api\n  n: integer\nend\nlocal api: Api = { n = " .. tostring(n) .. " }\nreturn api\n"))
    requires[#requires + 1] = ('local %s = require("%s")'):format(name, name)
    sum[#sum + 1] = name .. ".n"
  end
  local main = table.concat(requires, "\n") .. "\nlocal total: integer = " .. table.concat(sum, " + ") .. "\nreturn total\n"
  assert(Fs.write(root .. "/main.tl", main))
  local watched: mut {string} = {}
  for n = 1, 14 do watched[#watched + 1] = changed_on_disk(root, "mod" .. tostring(n) .. ".tl") end
  local ran = session_fixture.served_between(root, { { initialize(root), open(root, "main.tl", main) }, watched },
    function(_after: integer)
      for n = 1, 14 do
        assert(Fs.write(root .. "/mod" .. tostring(n) .. ".tl",
          "local record Api\n  n: string\nend\nlocal api: Api = { n = \"x\" }\nreturn api\n"))
      end
    end)
  assert(counts(ran):match("^0,[1-9]%d*$") ~= nil, counts(ran))
end

local function test_a_module_added_on_disk_is_found_once_the_stage_lists_it()
  local root = helped()
  local lacking = 'local later = require("later")\nlocal n: integer = later.n\nreturn n\n'
  local ran = then_(root, { initialize(root), open(root, "later_user.tl", lacking) }, function()
    assert(Fs.write(root .. "/later.tl", "local record Later\n  n: integer\nend\nlocal later: Later = { n = 1 }\nreturn later\n"))
  end, { changed_on_disk(root, "later.tl") })
  assert(counts(ran) == "1,0", counts(ran))
end

local function test_a_document_left_is_read_again_as_what_it_serves()
  local root = helped()
  local checker = checker_at(root)
  local helper = document_of(root, "helper.tl", HELPER)
  local main = document_of(root, "main.tl", MAIN)
  check.opened(checker, helper)
  check.opened(checker, main)
  assert(#check.diagnose(checker, helper, "utf-16") == 0)
  assert(#check.diagnose(checker, main, "utf-16") == 0)
  -- The helper is edited while the main is the one checked last, and is put back from the text it has now.
  check.set_text(helper, RETYPED)
  assert(#check.diagnose(checker, helper, "utf-16") == 0)
  local told = check.diagnose(checker, main, "utf-16")
  assert(#told == 1, table.concat(told, "\n"))
  check.set_text(helper, HELPER)
  assert(#check.diagnose(checker, helper, "utf-16") == 0)
  assert(#check.diagnose(checker, main, "utf-16") == 0)
end

--- A top-level record the module does not export is no part of its stub: the module is served to the documents that require it
--- as the stub it serves, whichever document was checked last.
local function test_a_document_left_is_served_as_its_stub_and_not_as_its_source()
  local root = project()
  local helper = "local record Unused\n  f: Nope\nend\n" .. HELPER
  assert(Fs.write(root .. "/helper.tl", helper))
  assert(Fs.write(root .. "/main.tl", MAIN))
  local checker = checker_at(root)
  local helped_doc = document_of(root, "helper.tl", helper)
  local main = document_of(root, "main.tl", MAIN)
  check.opened(checker, helped_doc)
  check.opened(checker, main)
  assert(#check.diagnose(checker, helped_doc, "utf-16") >= 1)
  local told = check.diagnose(checker, main, "utf-16")
  assert(#told == 0, table.concat(told, "\n"))
end

local function test_a_document_the_stage_does_not_list_is_forgotten_when_it_is_left()
  local root = helped()
  local checker = checker_at(root)
  local scratch = document_of(root, "scratch.tl", "local n: integer = 1\nreturn n\n")
  local main = document_of(root, "main.tl", MAIN)
  check.opened(checker, main)
  assert(#check.diagnose(checker, scratch, "utf-16") == 0)
  local before = assert(checker.program)
  assert(#check.diagnose(checker, main, "utf-16") == 0)
  assert(checker.program ~= before, "the module only the document stood for stayed in the program")
end

--- A module required by name, `page`, that is a template, and the module it reads its type from.
local DATA <const> = "local record data\n  record Page\n    title: string\n  end\nend\nreturn data\n"
local PAGE_MAIN <const> = 'local page = require("page")\nlocal data = require("data")\n' ..
  'local p: data.Page = { title = "t" }\nlocal s: string = page.render(p)\nreturn s\n'

--- A template that stops compiling is served to its dependents no more: the document that required it is not answered from the
--- last text of the template the program held as the focus.
local function test_a_template_that_stops_compiling_is_not_answered_from_its_last_text()
  local root = project()
  assert(Fs.write(root .. "/data.tl", DATA))
  local bad_field = "{{type Page from data}}{{mode text}}one {{.nope}}"
  assert(Fs.write(root .. "/page.tmpl", bad_field))
  assert(Fs.write(root .. "/main.tl", PAGE_MAIN))
  local checker = checker_at(root)
  local page = document_of(root, "page.tmpl", bad_field)
  local main = document_of(root, "main.tl", PAGE_MAIN)
  check.opened(checker, page)
  check.opened(checker, main)
  -- A field it does not have is the template's own error: the module it makes still types its dependents.
  assert(#check.diagnose(checker, main, "utf-16") == 0)
  assert(#check.diagnose(checker, page, "utf-16") == 1)
  check.set_text(page, "{{type Page from data}}\n{{mode text}}one {{.title")
  local told = table.concat(check.diagnose(checker, main, "utf-16"), "\n")
  assert(told:find("nope", 1, true) == nil, "answered from the template's last text: " .. told)
  assert(told:find("the project has no module `page` (require_unknown)", 1, true) ~= nil, told)
  assert(told == table.concat(check.diagnose(checker, main, "utf-16"), "\n"), "the answer moved")
end

--- The most the heap may grow, in KiB, over the loops below after the first few of each: what a short session holds. An honest
--- session grows by about nothing; a program that kept every reading of the document grows by the reading of each edit.
local GROWTH_AT_MOST <const> = 256

--- A module of `functions` functions, each with a body to check, whose box holds a `kind`.
local function big_main(functions: integer, kind: string, noise: integer): string
  local text = 'local helper = require("helper")\nlocal record Box\n  n: ' .. kind .. "\nend\n"
  local sum = "helper.twice(2)"
  for k = 1, functions do
    text = text .. ("local function f%d(a: integer): integer\n  local b: integer = a + %d\n  return b * 2\nend\n"):format(k, k)
    sum = sum .. (" + f%d(1)"):format(k)
  end
  local value = '"x"'
  if kind == "integer" then value = "n" end
  return text .. "local n: integer = " .. sum .. "\nlocal box: Box = { n = " .. value .. " }\n-- edit " .. tostring(noise) ..
    "\nreturn box\n"
end

--- The heap after a full collection, in KiB.
local function heap(): number
  collectgarbage()
  collectgarbage()
  return collectgarbage("count")
end

local function test_a_long_session_of_edits_holds_no_more_than_a_short_one()
  local root = helped()
  local checker = checker_at(root)
  local main = document_of(root, "main.tl", big_main(12, "integer", 0))
  local helper = document_of(root, "helper.tl", HELPER)
  check.opened(checker, main)
  check.opened(checker, helper)
  assert(#check.diagnose(checker, main, "utf-16") == 0)
  local program = assert(checker.program)
  --- Every loop's edits alternate right and wrong, so the errors of an old reading are held too if they are.
  local function edit(n: integer)
    local right = n % 2 == 1
    check.set_text(main, big_main(12, if right then "integer" else "string" end, n))
    local told = check.diagnose(checker, main, "utf-16")
    assert(#told == (if right then 0 else 1 end), table.concat(told, "\n"))
  end
  --- Switching documents puts the one left back as its stub; the helper is retyped on disk, which the stage serves again.
  local function switch(n: integer)
    edit(n)
    assert(Fs.write(root .. "/helper.tl", HELPER .. "-- " .. tostring(n) .. "\n"))
    check.stale(checker)
    check.set_text(helper, HELPER .. "-- " .. tostring(n) .. "\n")
    assert(#check.diagnose(checker, helper, "utf-16") == 0)
  end
  for n = 1, 2 do edit(n) end
  for n = 3, 4 do switch(n) end
  local base = heap()
  local started = Clock.monotonic_ns()
  for n = 5, 12 do edit(n) end
  for n = 13, 16 do switch(n) end
  local took = Clock.monotonic_ns() - started
  local grown = heap() - base
  print(("lsp held: %d checks in %.0f ms, heap grown %.0f KiB"):format(20, took / 1e6, grown))
  assert(checker.program == program, "the program was made again")
  assert(grown < GROWTH_AT_MOST, ("the heap grew %.0f KiB over 8 edits and 4 switches"):format(grown))
end

--- The checker's kept results ([`build.lsp.check`]) are keyed by what each document reads, so that a change of a module it
--- does not read leaves its result as it is, and one it reads checks it again.
local OTHER <const> = "local record Other\n  n: integer\nend\nlocal other: Other = { n = 1 }\nreturn other\n"
local SIDE <const> = 'local other = require("other")\nlocal n: integer = other.n\nreturn n\n'

--- A project of `main.tl` (requiring `helper.tl`) and `side.tl` (requiring `other.tl`), the checker of it, and the documents
--- `main` and `side` of it, both checked once.
local function sided(): string, check.Checker, check.Document, check.Document
  local root = helped()
  assert(Fs.write(root .. "/other.tl", OTHER))
  assert(Fs.write(root .. "/side.tl", SIDE))
  local checker = checker_at(root)
  local main = document_of(root, "main.tl", MAIN)
  local side = document_of(root, "side.tl", SIDE)
  check.opened(checker, main)
  check.opened(checker, side)
  assert(#check.diagnose(checker, main, "utf-16") == 0)
  assert(#check.diagnose(checker, side, "utf-16") == 0)
  return root, checker, main, side
end

--- Guards against a module changed that a document does not read checking it again, as the checker's `epoch` did for every
--- module served otherwise than it was.
local function test_a_module_a_document_does_not_read_changing_leaves_its_result_kept()
  local root, checker, main, side = sided()
  assert(Fs.write(root .. "/other.tl", OTHER .. "-- changed\n"))
  check.stale(checker)
  assert(#check.diagnose(checker, side, "utf-16") == 0)
  assert(#check.diagnose(checker, main, "utf-16") == 0)
  assert(check.read(checker, main) ~= nil)
  assert(checker.ran["side.tl"] == 2, tostring(checker.ran["side.tl"]))
  assert(checker.ran["main.tl"] == 1, tostring(checker.ran["main.tl"]))
end

local function test_a_module_a_document_reads_changing_checks_it_again()
  local root, checker, main, _ = sided()
  assert(Fs.write(root .. "/helper.tl", RETYPED))
  check.stale(checker)
  local told = check.diagnose(checker, main, "utf-16")
  assert(#told == 1, table.concat(told, "\n"))
  assert(checker.ran["main.tl"] == 2, tostring(checker.ran["main.tl"]))
end

--- A module the document reads only through another it requires is read as well: it is the type of the one required.
local function test_a_module_read_through_another_checks_the_document_again()
  local root = project()
  local inner = "local record inner\n  n: integer\nend\nreturn inner\n"
  local middle = 'local inner = require("inner")\nlocal record middle\n  value: inner\nend\nreturn middle\n'
  local top = 'local middle = require("middle")\nlocal m: middle = { value = { n = 1 } }\nreturn m\n'
  assert(Fs.write(root .. "/inner.tl", inner))
  assert(Fs.write(root .. "/middle.tl", middle))
  assert(Fs.write(root .. "/top.tl", top))
  local checker = checker_at(root)
  local document = document_of(root, "top.tl", top)
  check.opened(checker, document)
  local first = check.diagnose(checker, document, "utf-16")
  assert(#first == 0, table.concat(first, "\n"))
  assert(Fs.write(root .. "/inner.tl", (inner:gsub("integer", "string"))))
  check.stale(checker)
  local told = check.diagnose(checker, document, "utf-16")
  assert(#told == 1, table.concat(told, "\n"))
  assert(checker.ran["top.tl"] == 2, tostring(checker.ran["top.tl"]))
end

--- Guards against a restage that lists the document's file, which it was checked without, keeping the result of the check
--- made before: nothing it requires was served otherwise, so no module key moved.
local function test_a_restage_that_lists_the_documents_file_checks_it_again()
  local root = project()
  local text = "local n: integer = 1\nreturn n\n"
  local checker = checker_at(root)
  local document = document_of(root, "late.tl", text)
  assert(#check.diagnose(checker, document, "utf-16") == 0)
  assert(#check.diagnose(checker, document, "utf-16") == 0)
  assert(checker.ran["late.tl"] == 1, tostring(checker.ran["late.tl"]))
  assert(Fs.write(root .. "/late.tl", text))
  check.stale(checker)
  assert(#check.diagnose(checker, document, "utf-16") == 0)
  assert(checker.ran["late.tl"] == 2, tostring(checker.ran["late.tl"]))
end

--- Guards against a change of the docs databases a hint looks a name up in leaving a result that may have worded it otherwise.
local function test_a_change_of_the_hint_databases_checks_the_document_again()
  local root = helped()
  local databases: mut {Sqlite.Handle} = {}
  local checker = check.new(root, function(_line: string) end, function(): check.Hinted
    return { databases = databases, public = {} }
  end)
  local main = document_of(root, "main.tl", MAIN)
  check.opened(checker, main)
  assert(#check.diagnose(checker, main, "utf-16") == 0)
  assert(#check.diagnose(checker, main, "utf-16") == 0)
  assert(checker.ran["main.tl"] == 1, tostring(checker.ran["main.tl"]))
  databases = { (assert(Sqlite.open(":memory:"))) }
  assert(#check.diagnose(checker, main, "utf-16") == 0)
  assert(checker.ran["main.tl"] == 2, tostring(checker.ran["main.tl"]))
end

--- Adds a documented `symbol` of `module` to the docs database `db`.
local function documented(db: Sqlite.Handle, module: string, symbol: string)
  assert(Sqlite.run(db,
    "INSERT INTO docs (module, symbol, source_symbol, exported, kind, signature, text, file, line) " ..
      "VALUES (?1, ?2, ?2, 1, 'function', '', 'Docs.', 'x.tl', 1)", { { text = module }, { text = symbol } }))
end

--- Guards against a docs database written in place under the handle a hint reads, which moves no handle, leaving a result
--- that worded its pointer from the old rows; and against a database nothing wrote to costing a check.
local function test_a_docs_database_written_in_place_checks_the_document_again()
  local root = helped()
  local path = root .. "/docs.db"
  local writer = assert(Sqlite.open(path, { writable = true }))
  for _, statement in ipairs(schema.create("")) do assert(writer:exec(statement)) end
  documented(writer, "cosmic.fs", "Fs.read")
  local reader = assert(Sqlite.open(path))
  local checker = check.new(root, function(_line: string) end, function(): check.Hinted
    return { databases = { reader }, public = { false } }
  end)
  local main = document_of(root, "main.tl", "print(read)\n")
  check.opened(checker, main)
  local function message(): string
    local found = check.diagnose(checker, main, "utf-16")
    assert(#found == 1, tostring(#found))
    return assert(found[1])
  end
  assert(message():find("see also in docs: Fs.read", 1, true) ~= nil, message())
  assert(message():find("Json.read", 1, true) == nil)
  assert(checker.ran["main.tl"] == 1, tostring(checker.ran["main.tl"]))
  documented(writer, "cosmic.json", "Json.read")
  assert(message():find("Json.read", 1, true) ~= nil, message())
  assert(checker.ran["main.tl"] == 2, tostring(checker.ran["main.tl"]))
  assert(message():find("Json.read", 1, true) ~= nil)
  assert(checker.ran["main.tl"] == 2, tostring(checker.ran["main.tl"]))
  assert(reader:close())
  assert(writer:close())
end

--- Guards against a docs database committed to while a check reads it being recorded as already read: the next ask checks again.
local function test_a_docs_database_written_during_a_check_checks_the_document_again()
  local root = helped()
  local path = root .. "/docs.db"
  local writer = assert(Sqlite.open(path, { writable = true }))
  for _, statement in ipairs(schema.create("")) do assert(writer:exec(statement)) end
  documented(writer, "cosmic.fs", "Fs.read")
  local reader = assert(Sqlite.open(path))
  local asked = 0
  local checker = check.new(root, function(_line: string) end, function(): check.Hinted
    asked = asked + 1
    -- The first ask is the key read before the check, the second the check's own lookup.
    if asked == 2 then documented(writer, "cosmic.json", "Json.read") end
    return { databases = { reader }, public = { false } }
  end)
  local main = document_of(root, "main.tl", "print(read)\n")
  check.opened(checker, main)
  assert(#check.diagnose(checker, main, "utf-16") == 1)
  assert(checker.ran["main.tl"] == 1, tostring(checker.ran["main.tl"]))
  local found = check.diagnose(checker, main, "utf-16")
  assert(checker.ran["main.tl"] == 2, tostring(checker.ran["main.tl"]))
  assert(assert(found[1]):find("Json.read", 1, true) ~= nil, assert(found[1]))
  assert(reader:close())
  assert(writer:close())
end

--- Guards against a module written while a check reads it being recorded as already read: the next ask checks again.
local function test_a_module_written_during_a_check_checks_the_document_again()
  local root = helped()
  local asked = 0
  local helper = document_of(root, "helper.tl", HELPER)
  local checker = check.new(root, function(_line: string) end, function(): check.Hinted
    asked = asked + 1
    -- The first ask is the key read before the check, the second the check's own lookup of a hint.
    if asked == 2 then check.set_text(helper, RETYPED) end
    return { databases = {}, public = {} }
  end)
  local main = document_of(root, "main.tl", 'local helper = require("helper")\nprint(read, helper)\nlocal n: integer = 1\nreturn n\n')
  check.opened(checker, helper)
  check.opened(checker, main)
  local told = check.diagnose(checker, main, "utf-16")
  assert(#told == 1, table.concat(told, "\n"))
  assert(asked >= 2, "the check looked up a hint")
  assert(checker.ran["main.tl"] == 1, tostring(checker.ran["main.tl"]))
  check.diagnose(checker, main, "utf-16")
  assert(checker.ran["main.tl"] == 2, tostring(checker.ran["main.tl"]))
end

--- Guards against a session holding the whole program of every document it has open: the documents asked of least recently
--- drop their results, are checked again when asked of, and publish what they published while nothing they read moved.
local function test_only_the_documents_asked_of_last_keep_their_results()
  local root = helped()
  local checker = checker_at(root)
  local documents: mut {check.Document} = {}
  for n = 1, 10 do
    local name = "d" .. tostring(n) .. ".tl"
    local text = "local n: integer = " .. tostring(n) .. "\nreturn n\n"
    assert(Fs.write(root .. "/" .. name, text))
    local document = document_of(root, name, text)
    check.opened(checker, document)
    documents[#documents + 1] = document
  end
  for _, document in ipairs(documents) do
    assert(#check.diagnose(checker, document, "utf-16") == 0)
    assert(check.read(checker, document) ~= nil)
  end
  local first, second, last = assert(documents[1]), assert(documents[2]), assert(documents[10])
  assert(first.kept == nil and first.parsed == nil and second.kept == nil, "the least recently asked kept its result")
  assert(last.kept ~= nil and last.parsed ~= nil, "the most recently asked lost its result")
  assert(#checker.recent == 8, tostring(#checker.recent))
  -- Its diagnostics stand while nothing it read moved, so publishing them checks nothing.
  assert(#check.diagnose(checker, first, "utf-16") == 0)
  assert(checker.ran["d1.tl"] == 1, tostring(checker.ran["d1.tl"]))
  -- The questions asked of its types check it again.
  assert(check.read(checker, first) ~= nil)
  assert(checker.ran["d1.tl"] == 2, tostring(checker.ran["d1.tl"]))
  assert(checker.ran["d10.tl"] == 1, tostring(checker.ran["d10.tl"]))
  assert(first.kept ~= nil and second.kept == nil and #checker.recent == 8)
end

--- A document closed drops its result, and its place among the most recently asked.
local function test_a_closed_document_keeps_no_result()
  local _, checker, main, _ = sided()
  assert(check.read(checker, main) ~= nil)
  assert(#checker.recent == 2, tostring(#checker.recent))
  check.closed(checker, main)
  assert(main.kept == nil and #checker.recent == 1, tostring(#checker.recent))
end

--- The most the heap may grow, in KiB, over asking of 40 documents after the 8 that keep a result: what the program holds of
--- each module it is put (about 100 KiB), not a result (about 750 KiB each, so 30 MiB, were every result kept).
local DOCUMENTS_GROWTH_AT_MOST <const> = 8192

--- The heap grown by asking of many more documents than keep a result, after the ones that do.
local function test_many_documents_asked_of_hold_no_more_than_the_few_that_keep_a_result()
  local root = helped()
  local checker = checker_at(root)
  local documents: mut {check.Document} = {}
  for n = 1, 48 do
    local name = "w" .. tostring(n) .. ".tl"
    local text = big_main(12, "integer", n)
    assert(Fs.write(root .. "/" .. name, text))
    local document = document_of(root, name, text)
    check.opened(checker, document)
    documents[#documents + 1] = document
  end
  local function ask(from: integer, to: integer)
    for n = from, to do
      local document = assert(documents[n])
      assert(check.read(checker, document) ~= nil, document.name)
    end
  end
  ask(1, 8)
  local base = heap()
  ask(9, 48)
  local grown = heap() - base
  print(("lsp held: 40 more documents asked of, heap grown %.0f KiB"):format(grown))
  assert(grown < DOCUMENTS_GROWTH_AT_MOST, ("the heap grew %.0f KiB over 40 documents"):format(grown))
end

--- Guards against a dependency edited to require another module, and not checked since, hiding that module from the
--- documents that require it: the modules a document reads are those of the open text, not of its last check.
local function test_an_open_dependency_edited_to_require_another_is_read_through_its_text()
  local root = project()
  local inner = "local record inner\n  n: integer\nend\nreturn inner\n"
  local before = "local record middle\n  record Plain\n    n: integer\n  end\n  value: Plain\nend\nreturn middle\n"
  local after = 'local inner = require("inner")\nlocal record middle\n  value: inner\nend\nreturn middle\n'
  local top = 'local middle = require("middle")\nlocal n: integer = middle.value.n\nreturn n\n'
  assert(Fs.write(root .. "/inner.tl", inner))
  assert(Fs.write(root .. "/middle.tl", before))
  assert(Fs.write(root .. "/top.tl", top))
  local checker = checker_at(root)
  local middle = document_of(root, "middle.tl", before)
  local document = document_of(root, "top.tl", top)
  check.opened(checker, middle)
  check.opened(checker, document)
  assert(#check.diagnose(checker, middle, "utf-16") == 0)
  local first = check.diagnose(checker, document, "utf-16")
  assert(#first == 0, table.concat(first, "\n"))
  check.set_text(middle, after)
  local second = check.diagnose(checker, document, "utf-16")
  assert(#second == 0, table.concat(second, "\n"))
  assert(Fs.write(root .. "/inner.tl", (inner:gsub("integer", "string"))))
  check.stale(checker)
  local told = check.diagnose(checker, document, "utf-16")
  assert(#told == 1, table.concat(told, "\n"))
end

--- Guards against completion in a document being typed in finding nothing once other documents were asked of: the last text
--- that parsed stays while the current one does not.
local function test_a_document_being_typed_in_keeps_the_last_text_that_parsed_when_evicted()
  local root = helped()
  local checker = checker_at(root)
  local typed = document_of(root, "main.tl", MAIN)
  check.opened(checker, typed)
  assert(check.read(checker, typed) ~= nil)
  check.set_text(typed, MAIN .. "local m: integer = helper.\n")
  local last = check.last(checker, typed)
  assert(last ~= nil and last.text == MAIN, "no last text that parsed")
  for n = 1, 9 do
    local name = "e" .. tostring(n) .. ".tl"
    local text = "local n: integer = " .. tostring(n) .. "\nreturn n\n"
    assert(Fs.write(root .. "/" .. name, text))
    local other = document_of(root, name, text)
    check.opened(checker, other)
    assert(check.read(checker, other) ~= nil)
  end
  assert(typed.kept == nil, "the document being typed in kept its result")
  local after = check.last(checker, typed)
  assert(after ~= nil and after.text == MAIN, "the last text that parsed was dropped")
  check.closed(checker, typed)
  assert(typed.parsed == nil)
end

--- A template an open document requires is read as the Teal it compiles to: the module its `type ... from` names is one the
--- document reads, so that module's change checks the document again.
local function test_a_module_read_through_an_open_template_checks_the_document_again()
  local root = project()
  local tmpl = "{{type Page from data}}{{mode text}}one {{.title}}"
  local top = 'local page = require("page")\nlocal s: string = page.render({ title = "t" })\nreturn s\n'
  assert(Fs.write(root .. "/data.tl", DATA))
  assert(Fs.write(root .. "/page.tmpl", tmpl))
  assert(Fs.write(root .. "/top.tl", top))
  local checker = checker_at(root)
  local page = document_of(root, "page.tmpl", tmpl)
  local document = document_of(root, "top.tl", top)
  check.opened(checker, page)
  check.opened(checker, document)
  local first = check.diagnose(checker, document, "utf-16")
  assert(#first == 0, table.concat(first, "\n"))
  assert(Fs.write(root .. "/data.tl", (DATA:gsub("title: string", "title: integer"))))
  check.stale(checker)
  local told = check.diagnose(checker, document, "utf-16")
  assert(#told >= 1, "the change of a module the template reads was not noticed")
end

--- A dependency whose open text does not parse requires none, and is read again once it parses: its key moved with the text.
local function test_an_open_dependency_that_does_not_parse_is_read_again_once_it_does()
  local root = project()
  local inner = "local record inner\n  n: integer\nend\nreturn inner\n"
  local broken = 'local inner = require(\n'
  local fixed = 'local inner = require("inner")\nlocal record middle\n  value: inner\nend\nreturn middle\n'
  local top = 'local middle = require("middle")\nlocal n: integer = middle.value.n\nreturn n\n'
  assert(Fs.write(root .. "/inner.tl", inner))
  assert(Fs.write(root .. "/middle.tl", fixed))
  assert(Fs.write(root .. "/top.tl", top))
  local checker = checker_at(root)
  local middle = document_of(root, "middle.tl", broken)
  local document = document_of(root, "top.tl", top)
  check.opened(checker, middle)
  check.opened(checker, document)
  local _ = check.diagnose(checker, document, "utf-16")
  check.set_text(middle, fixed)
  local second = check.diagnose(checker, document, "utf-16")
  assert(#second == 0, table.concat(second, "\n"))
  assert(Fs.write(root .. "/inner.tl", (inner:gsub("integer", "string"))))
  check.stale(checker)
  local told = check.diagnose(checker, document, "utf-16")
  assert(#told == 1, table.concat(told, "\n"))
end
