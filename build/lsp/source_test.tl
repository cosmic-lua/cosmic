--- What a `require` reads in a `cosmic lsp` session ([`build.lsp.source`]):
--- the working database the build stages, as it was staged, with an open
--- document standing in for its file; a package's `init.tl`, a
--- declaration, a template; the stage made again when the editor says a
--- file changed on disk, and only then; which roots are staged; and the
--- files a build reads no module from.

local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Json = require("cosmic.json")
local Sqlite = require("cosmic.sqlite")
local build_paths = require("build.paths")
local Proc = require("cosmic.proc")
local reboot = require("build.reboot")
local tree = require("build.tree")
local session_fixture = require("build.lsp.session_fixture")
local source = require("build.lsp.source")
local syntax_read = require("build.lsp.syntax_read")
local work = require("build.work")

local change, changed_on_disk, close = session_fixture.change, session_fixture.changed_on_disk,
  session_fixture.close
local counts, initialize, messages_of = session_fixture.counts, session_fixture.initialize,
  session_fixture.messages_of
local nth, only, open = session_fixture.nth, session_fixture.only, session_fixture.open
local publications, published = session_fixture.publications, session_fixture.published
local requests, save, served = session_fixture.requests, session_fixture.save, session_fixture.served
local served_between = session_fixture.served_between
local made_project, project = session_fixture.made_project, session_fixture.project
local serving = session_fixture.serving

--- The module `lib.shapes` written as the checker takes a module: a record, whose `sides` is of `kind` and `value`.
local function shapes_of(kind: string, value: string): string
  return "local record shapes\n  sides: " .. kind .. "\nend\nlocal s: shapes = { sides = " .. value .. " }\nreturn s\n"
end

local THREE <const> = shapes_of("integer", "3")
local FOUR <const> = shapes_of("integer", "4")
local STRINGS <const> = shapes_of("string", '"three"')

--- What a main is told of a module `lib.shapes` the database lists none of.
local NO_SHAPES <const> = "the project has no module `lib.shapes` (require_unknown): require a module of the " ..
  "project: `bin/cosmic docs` lists them"

--- A module with nothing in it, as the checker takes one.
local EMPTY <const> = "local record empty\nend\nlocal e: empty = {}\nreturn e\n"

--- What a main that reads `shapes.sides` into an `integer` is told of a module whose `sides` is a string.
local WRONG <const> = "`shapes.sides` is `string`, where `integer` is wanted as the value of `n` (not_assignable): " ..
  "pass a value of type `integer`, or change the declaration to `string`"

local function test_a_require_reads_an_open_document_before_the_disk()
  local root = project()
  assert(Fs.mkdirs(root .. "/lib"))
  assert(Fs.write(root .. "/lib/shapes.tl", THREE))
  local main = 'local shapes = require("lib.shapes")\nlocal n: integer = shapes.sides\nreturn n\n'
  local ran = served(root, {
    initialize(root),
    open(root, "main.tl", main),
    open(root, "lib/shapes.tl", STRINGS),
    change(root, "main.tl", main),
    change(root, "lib/shapes.tl", FOUR),
    change(root, "main.tl", main),
  })
  assert(#published(ran) == 5)
  assert(#nth(ran, 1) == 0, "the file on disk types")
  assert(#nth(ran, 3) == 1, "the open document's string is what main reads")
  assert(#nth(ran, 5) == 0, "the document's change is read again")
end

local function test_a_package_module_is_its_init()
  local root = project()
  assert(Fs.mkdirs(root .. "/lib/shapes"))
  assert(Fs.write(root .. "/lib/shapes/init.tl", THREE))
  assert(Fs.write(root .. "/lib/decl.d.tl", "local record decl\n  sides: integer\nend\nreturn decl\n"))
  local main = 'local shapes = require("lib.shapes")\nlocal decl = require("lib.decl")\n' ..
    "local n: integer = shapes.sides + decl.sides\nreturn n\n"
  local diagnostics = nth(served(root, { initialize(root), open(root, "main.tl", main) }), 1)
  assert(#diagnostics == 0, messages_of(diagnostics))
end

local function test_a_closed_document_no_longer_shadows_the_file()
  local root = project()
  assert(Fs.mkdirs(root .. "/lib"))
  assert(Fs.write(root .. "/lib/shapes.tl", THREE))
  local main = 'local shapes = require("lib.shapes")\nlocal n: integer = shapes.sides\nreturn n\n'
  local ran = served(root, {
    initialize(root),
    open(root, "lib/shapes.tl", STRINGS),
    open(root, "main.tl", main),
    close(root, "lib/shapes.tl"),
    change(root, "main.tl", main),
  })
  local sent = publications(ran)
  assert(#sent == 4, tostring(#sent))
  assert(counts(ran) == "0,1,0,0", counts(ran))
  -- The close clears its own, and main, changed after, reads the file.
  local closed, main_again = assert(sent[3]), assert(sent[4])
  assert(closed.uri:sub(-14) == "/lib/shapes.tl", closed.uri)
  assert(main_again.uri:sub(-8) == "/main.tl", main_again.uri)
end

local function test_a_save_stages_again_and_publishes_what_changed()
  local root = project()
  assert(Fs.mkdirs(root .. "/lib"))
  assert(Fs.write(root .. "/lib/shapes.tl", THREE))
  local main = 'local shapes = require("lib.shapes")\nlocal n: integer = shapes.sides\nreturn n\n'
  local send = serving(root)
  send({ initialize(root), open(root, "main.tl", main), open(root, "other.tl", "return 2\n") })
  assert(Fs.write(root .. "/lib/shapes.tl", STRINGS))
  local sent = publications(send({ save(root, "lib/shapes.tl") }))
  assert(#sent == 3, "only main changed: " .. tostring(#sent))
  local third = assert(sent[3])
  assert(third.uri == "file://" .. root .. "/main.tl" and #third.diagnostics == 1, third.uri)
end

local function test_the_same_text_checks_the_same_each_time()
  local root = project()
  -- A module the document reads, and a global no declaration file declares.
  assert(Fs.write(root .. "/g.tl", EMPTY))
  local reader = 'local g = require("g")\nprint(g)\nlocal n: integer = G_VAL\nreturn n\n'
  local declares = "global G_OWN: integer = 1\nlocal s: string = G_OWN\nreturn s\n"
  -- A request between two changes keeps the second from standing for
  -- both ([`build.lsp.session`] checks only the last of changes read together).
  local between = '{"jsonrpc":"2.0","id":7,"method":"nosuch"}'
  local ran = served(root, { initialize(root),
    open(root, "m2.tl", reader), change(root, "m2.tl", reader), between, change(root, "m2.tl", reader),
    open(root, "own.tl", declares), change(root, "own.tl", declares),
  })
  assert(counts(ran) == "1,1,1,1,1", counts(ran) .. "\n" .. messages_of(nth(ran, 2)))
  assert(messages_of(nth(ran, 1)) == messages_of(nth(ran, 3)), messages_of(nth(ran, 1)) .. "\n--\n" .. messages_of(nth(ran, 3)))
  local own, again = messages_of(nth(ran, 4)), messages_of(nth(ran, 5))
  assert(own == again and own:find("(global_in_program)", 1, true) ~= nil, own .. "\n--\n" .. again)
end

--- A `file:` URI of `path`, a space and a `%` escaped.
local function escaped(path: string): string
  return "file://" .. (path:gsub("%%", "%%25"):gsub(" ", "%%20"))
end

local function test_a_root_is_read_from_its_escaped_uri_or_its_path_or_folder()
  local base = assert(Fs.mkdtemp("cosmic-lsp-"))
  local root = base .. "/a b%c"
  assert(Fs.mkdirs(root .. "/lib"))
  made_project(root)
  assert(Fs.write(root .. "/lib/shapes.tl", STRINGS))
  local main = 'local shapes = require("lib.shapes")\nlocal n: integer = shapes.sides\nreturn n\n'
  local opened = '{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":' ..
    Json.quote(escaped(root .. "/main.tl")) .. ',"languageId":"teal","version":1,"text":' ..
    Json.quote(main) .. "}}}"
  local inits: {string} = {
    '{"rootUri":' .. Json.quote(escaped(root)) .. "}",
    '{"rootPath":' .. Json.quote(root) .. "}",
    '{"workspaceFolders":[{"uri":' .. Json.quote(escaped(root)) .. ',"name":"w"}]}',
  }
  for _, params in ipairs(inits) do
    local init = '{"jsonrpc":"2.0","id":1,"method":"initialize","params":' .. params .. "}"
    -- The session starts at another directory: only the root it is
    -- given finds lib/shapes.tl.
    local found = only(nth(served(base, { init, opened }), 1))
    assert(found.message == WRONG, params .. ": " .. found.message)
  end
end

local function test_a_template_is_a_module_and_testdata_is_none()
  local root = project()
  assert(Fs.mkdirs(root .. "/testdata"))
  assert(Fs.write(root .. "/data.tl", "local record data\n  record Page\n    title: string\n  end\nend\nreturn data\n"))
  assert(Fs.write(root .. "/page.tmpl", "{{type Page from data}}{{mode text}}one {{.title}}"))
  assert(Fs.write(root .. "/testdata/m.tl", EMPTY))
  local main = 'local page = require("page")\nlocal data = require("data")\n' ..
    'local p: data.Page = { title = "t" }\nlocal n: integer = page.render(p)\nreturn n\n'
  local rendered = only(nth(served(root, { initialize(root), open(root, "main.tl", main) }), 1))
  assert(rendered.message == "`page.render(p)` is `string`, where `integer` is wanted as the value of `n` " ..
      "(not_assignable): pass a value of type `integer`, or change the declaration to `string`",
    "the template renders a string: " .. rendered.message)
  local fixture = 'local m = require("testdata.m")\nlocal n: integer = m.n\nreturn n\n'
  local unfound = only(nth(served(root, { initialize(root), open(root, "main.tl", fixture) }), 1))
  assert(unfound.message:find("testdata.m", 1, true), unfound.message)
end

local function test_the_disk_is_read_only_when_the_editor_says_it_changed()
  local root = project()
  assert(Fs.mkdirs(root .. "/lib"))
  assert(Fs.write(root .. "/lib/shapes.tl", THREE))
  local main = 'local shapes = require("lib.shapes")\nlocal n: integer = shapes.sides\nreturn n\n'
  local watching = '{"workspace":{"didChangeWatchedFiles":{"dynamicRegistration":true}}}'
  local initialized = '{"jsonrpc":"2.0","method":"initialized","params":{}}'
  local registered = '{"jsonrpc":"2.0","id":1,"result":null}'
  local first = served(root, { initialize(root, watching), initialized, registered,
    open(root, "main.tl", main) })
  local asked = table.concat(requests(first), " ")
  assert(asked == "client/registerCapability", asked)
  assert(table.concat(first.sent, "\n"):find('"globPattern":"**/*.tl"', 1, true))
  assert(#requests(served(root, { initialize(root), initialized })) == 0,
    "no registration where the editor takes none")
  local declined = '{"workspace":{"didChangeWatchedFiles":{"dynamicRegistration":false}}}'
  assert(#requests(served(root, { initialize(root, declined), initialized })) == 0,
    "no registration where the editor says it takes none")
  -- One session, sent messages with time between: the file changes on
  -- disk, then main changes, then the editor says the file did.
  local send = serving(root)
  send({ initialize(root, watching), initialized, open(root, "main.tl", main) })
  assert(Fs.write(root .. "/lib/shapes.tl", STRINGS))
  send({ change(root, "main.tl", main .. "\n") })
  -- A module the stage has not seen is not found, though the file is there.
  assert(Fs.write(root .. "/lib/more.tl", EMPTY))
  send({ change(root, "main.tl", 'local _ = require("lib.more")\n' .. main) })
  local ran = send({ changed_on_disk(root, "lib/shapes.tl") })
  assert(counts(ran) == "0,0,1,1", "as staged, until the editor says it changed: " .. counts(ran) ..
      "\n" .. messages_of(nth(ran, 3)) .. "\n" .. messages_of(nth(ran, 4)))
  assert(messages_of(nth(ran, 3)):find("lib.more", 1, true), messages_of(nth(ran, 3)))
  assert(messages_of(nth(ran, 4)) == WRONG, messages_of(nth(ran, 4)))
end

--- While another run holds the database's write transaction open, with
--- more written than its cache holds (in rollback mode, a spill that
--- holds the file whole), the session stages nothing and reads the last
--- commit at once: it waits on no lock, and none fails its read.
local function test_a_busy_database_is_read_at_once_as_last_committed()
  local root = project()
  assert(Fs.mkdirs(root .. "/lib"))
  assert(Fs.write(root .. "/lib/shapes.tl", THREE))
  local main = 'local shapes = require("lib.shapes")\nlocal n: integer = shapes.sides\nreturn n\n'
  local send = serving(root)
  send({ initialize(root), open(root, "main.tl", main) })
  assert(Fs.write(root .. "/lib/shapes.tl", STRINGS))
  -- Another run holds the database's write lock, as a build's does, and
  -- has written more than its cache of a few pages holds.
  local held = assert(Sqlite.open(build_paths.under((assert(build_paths.directory(root)))).working,
    { writable = true }))
  assert(held:exec("BEGIN IMMEDIATE"))
  assert(held:exec("PRAGMA cache_size = 10"))
  -- Uncommitted, the file is gone: a read of it would find no module.
  assert(held:exec("DELETE FROM files WHERE path = 'lib/shapes.tl'"))
  assert(held:exec("WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n " ..
      "WHERE i < 4000) INSERT INTO meta (key, value) SELECT 'filler ' || i, " ..
      "hex(randomblob(512)) FROM n"))
  local started = Clock.monotonic_ns()
  local busy = send({ save(root, "lib/shapes.tl") })
  local took = Clock.monotonic_ns() - started
  assert(busy.err:find("another cosmic run holds the write lock", 1, true), busy.err)
  assert(busy.err:find("locked", 1, true) == nil, busy.err)
  assert(counts(busy) == "0", "nothing changed as last committed: " .. counts(busy))
  assert(took < Clock.seconds(10), "the answer took " .. tostring(took) .. " ns")
  assert(held:exec("ROLLBACK"))
  assert(held:close())
  local ran = send({ change(root, "main.tl", main .. "\n") })
  assert(counts(ran) == "0,1", "staged once the lock is free: " .. counts(ran))
end

--- A database of another schema, another tool's, the session neither
--- stages nor reads, saying so, and leaves where it is; once a build of
--- this tool makes it again, it stages it.
local function test_a_database_of_another_schema_is_neither_staged_nor_read()
  local root = project()
  assert(Fs.mkdirs(root .. "/lib"))
  assert(Fs.write(root .. "/lib/shapes.tl", THREE))
  local main = 'local shapes = require("lib.shapes")\nlocal n: integer = shapes.sides\nreturn n\n'
  local send = serving(root)
  send({ initialize(root), open(root, "main.tl", main) })
  local working = build_paths.under((assert(build_paths.directory(root)))).working
  local stale = assert(Sqlite.open(working, { writable = true }))
  assert(stale:exec("UPDATE meta SET value = 'another' WHERE key = 'schema'"))
  assert(stale:close())
  local before = assert(Fs.stat(working)).ino
  assert(Fs.write(root .. "/lib/shapes.tl", STRINGS))
  local other = send({ save(root, "lib/shapes.tl") })
  assert(other.err:find("is of schema another", 1, true), other.err)
  assert(assert(Fs.stat(working)).ino == before, "the file was removed")
  -- None of its modules is read.
  assert(counts(other) == "0,1", counts(other))
  assert(messages_of(nth(other, 2)) == NO_SHAPES, messages_of(nth(other, 2)))
  assert(work.close((assert(work.open(root)))))
  local ran = send({ change(root, "main.tl", main .. "\n") })
  assert(counts(ran) == "0,1,1", "staged once made again: " .. counts(ran))
  assert(messages_of(nth(ran, 3)) == WRONG, messages_of(nth(ran, 3)))
end

--- Stamps the working database at `path` with another schema, through
--- `db` where given, else a handle of its own.
local function stamp_another(path: string, db?: Sqlite.Handle)
  local handle = db or assert(Sqlite.open(path, { writable = true }))
  assert(handle:exec("UPDATE meta SET value = 'another' WHERE key = 'schema'"))
  if db == nil then assert(handle:close()) end
end

--- Whether `src` holds a read handle on the database.
local function holds(src: source.View): boolean
  return src.db ~= nil
end

--- A session that finds the working database of another schema lets go
--- of the handle it read it through: a handle kept would be one on
--- another tool's file, from which a later read reads that tool's rows.
local function test_a_database_of_another_schema_is_let_go_of()
  local root = project()
  local src = source.new(root, function(_: string) end)
  source.refresh(src)
  assert(holds(src), "the database is not read")
  stamp_another(assert(src.working))
  source.stale(src)
  source.refresh(src)
  assert(not holds(src), "a handle on a database of another schema is kept")
  source.close(src)
end

--- A stage that refused a pair is told of it by the files of the pair, whichever of the two is asked, and by no other file;
--- a pair under `testdata/` is a fixture of a test, no part of the program, and is told nothing. The stage that staged
--- clears it.
local function test_a_refused_pair_is_told_to_its_files_and_to_no_testdata()
  local root = project()
  assert(Fs.mkdirs(root .. "/lib"))
  assert(Fs.mkdirs(root .. "/testdata"))
  local text = "local record M\n  n: integer\nend\nreturn M\n"
  for _, dir in ipairs({ "lib", "testdata" }) do
    assert(Fs.write(root .. "/" .. dir .. "/m.d.tl", text))
    assert(Fs.write(root .. "/" .. dir .. "/m.tl", text))
  end
  assert(Fs.write(root .. "/lib/other.tl", "local n: integer = 1\nreturn n\n"))
  local src = source.new(root, function(_: string) end)
  source.refresh(src)
  assert(source.refused(src), "the stage staged a pair")
  local told = source.refusal(src, "lib/m.tl")
  assert(told ~= nil and told:find("lib/m.d.tl: lib/m.tl is already the module lib.m.", 1, true) == 1, tostring(told))
  assert(source.refusal(src, "lib/m.d.tl") == told)
  assert(source.refusal(src, "lib/other.tl") == nil)
  assert(source.refusal(src, "testdata/m.tl") == nil and source.refusal(src, "testdata/m.d.tl") == nil)
  assert(Fs.remove(root .. "/lib/m.d.tl"))
  source.stale(src)
  source.refresh(src)
  assert(not source.refused(src) and source.refusal(src, "lib/m.tl") == nil)
  source.close(src)
end

--- A session that reads the database finds, at its next check, the
--- file made again under it as another schema's, another tool's: it
--- reads none of the new file, which lists the same modules, and says
--- why.
local function test_a_database_made_again_of_another_schema_under_the_session_is_not_read()
  local root = project()
  assert(Fs.mkdirs(root .. "/lib"))
  assert(Fs.write(root .. "/lib/shapes.tl", THREE))
  local main = 'local shapes = require("lib.shapes")\nlocal n: integer = shapes.sides\nreturn n\n'
  local working = build_paths.under((assert(build_paths.directory(root)))).working
  local ran = served_between(root, { { initialize(root), open(root, "main.tl", main) },
    { change(root, "main.tl", main .. "\n") } }, function(_after: integer)
      -- A copy at another inode, stamped as another tool's. The old
      -- file's log, which keeps its name, is emptied first, so the copy
      -- is read as it is.
      local copy = working .. ".another"
      local db = assert(Sqlite.open(working, { writable = true }))
      assert(Sqlite.text_rows(db, "PRAGMA wal_checkpoint(TRUNCATE)"))
      assert(Sqlite.run(db, "VACUUM INTO ?1", { { text = copy } }))
      assert(db:close())
      stamp_another(copy)
      assert(Fs.rename(copy, working))
    end)
  assert(ran.err:find("is of schema another", 1, true), "not said: " .. ran.err)
  assert(ran.tally.reopened == 1, tostring(ran.tally.reopened))
  assert(counts(ran) == "0,1", "a module of another schema's file is read: " .. counts(ran))
  assert(messages_of(nth(ran, 2)) == NO_SHAPES, messages_of(nth(ran, 2)))
end

--- A session that has said the database is busy still says when it then
--- finds it of another schema: each is said once, apart.
local function test_a_busy_database_found_of_another_schema_is_said_so()
  local root = project()
  local main = "return 1\n"
  local send = serving(root)
  send({ initialize(root), open(root, "main.tl", main) })
  local working = build_paths.under((assert(build_paths.directory(root)))).working
  local held = assert(Sqlite.open(working, { writable = true }))
  assert(held:exec("BEGIN IMMEDIATE"))
  local busy = send({ save(root, "main.tl") })
  assert(busy.err:find("another cosmic run holds the write lock", 1, true), busy.err)
  stamp_another(working, held)
  assert(held:exec("COMMIT"))
  assert(held:close())
  local other = send({ change(root, "main.tl", main .. "\n") })
  assert(other.err:find("is of schema another", 1, true), "not said: " .. other.err .. counts(other) .. " reopened " .. tostring(other.tally.reopened) .. " stages " .. tostring(other.tally.stages))
  -- What the session has said so far: each once.
  local said = send({ change(root, "main.tl", main) }).err
  local _, busy_times = said:gsub("holds the write lock", "")
  local _, other_times = said:gsub("is of schema another", "")
  assert(busy_times == 1 and other_times == 1, said)
end

--- A module is served as the stub the stage derived, as a stub made here
--- of an open document, or as its source where it has no stub: a
--- declaration. (A module that returns nothing is none to require: the
--- checker reports the binding of it, `unchecked_binding`.)
local function test_each_module_is_served_as_its_stub_where_it_has_one()
  local root = project()
  assert(Fs.mkdirs(root .. "/lib"))
  assert(Fs.write(root .. "/lib/shapes.tl", THREE))
  assert(Fs.write(root .. "/lib/decl.d.tl", "local record decl\n  sides: integer\nend\nreturn decl\n"))
  local main = 'local shapes = require("lib.shapes")\nlocal decl = require("lib.decl")\n' ..
    'local n: integer = shapes.sides + decl.sides\nreturn n\n'
  local send = serving(root)
  local first = send({ initialize(root), open(root, "main.tl", main) })
  assert(counts(first) == "0", messages_of(nth(first, 1)))
  local tally = first.tally
  assert(tally.database_stubs == 1 and tally.made_stubs == 0 and tally.sources == 1,
    tostring(tally.database_stubs) .. "," .. tostring(tally.made_stubs) .. "," .. tostring(tally.sources))
  local after = send({ open(root, "lib/shapes.tl", FOUR), change(root, "main.tl", main) }).tally
  assert(after.made_stubs == 1 and after.database_stubs == 1, tostring(after.made_stubs))
end

--- Where the database's stubs are another analyzer's, each is made here
--- from the source the database holds.
local function test_a_stub_of_another_analyzer_is_made_here()
  local root = project()
  assert(Fs.mkdirs(root .. "/lib"))
  assert(Fs.write(root .. "/lib/shapes.tl", THREE))
  local main = 'local shapes = require("lib.shapes")\nlocal n: integer = shapes.sides\nreturn n\n'
  assert(counts(served(root, { initialize(root), open(root, "main.tl", main) })) == "0")
  local held = assert(Sqlite.open(build_paths.under((assert(build_paths.directory(root)))).working,
    { writable = true }))
  assert(held:exec("UPDATE meta SET value = 'another' WHERE key = 'analyzer'"))
  -- Held, so the next session stages nothing and reads the rows as they are.
  assert(held:exec("BEGIN IMMEDIATE"))
  local ran = served(root, { initialize(root), open(root, "main.tl", main) })
  assert(held:exec("ROLLBACK"))
  assert(held:close())
  assert(counts(ran) == "0", messages_of(nth(ran, 1)))
  assert(ran.tally.made_stubs == 1 and ran.tally.database_stubs == 0,
    tostring(ran.tally.made_stubs) .. "," .. tostring(ran.tally.database_stubs))
end

--- A stage that fails says so, and the tree is read as last staged.
local function test_a_stage_that_fails_answers_from_the_last()
  local root = project()
  assert(Fs.mkdirs(root .. "/lib"))
  assert(Fs.write(root .. "/lib/shapes.tl", THREE))
  local main = 'local shapes = require("lib.shapes")\nlocal n: integer = shapes.sides\nreturn n\n'
  local send = serving(root)
  assert(counts(send({ initialize(root), open(root, "main.tl", main) })) == "0")
  assert(Fs.write(root .. "/lib/shapes.tl", STRINGS))
  assert(Fs.write(root .. "/lib/broken.tl", "local = \n"))
  local ran = send({ save(root, "lib/broken.tl") })
  assert(ran.err:find("cosmic: lsp: not staged, answering from the tree as last staged", 1, true),
    ran.err)
  assert(ran.tally.stages == 1, tostring(ran.tally.stages))
  assert(counts(ran) == "0", "as last staged: " .. counts(ran))
end

--- How many times `ran` showed the person a message.
local function shown(ran: session_fixture.Ran): integer
  local out = 0
  for _, body in ipairs(ran.sent) do
    if session_fixture.sent(body).method == "window/showMessage" then out = out + 1 end
  end
  return out
end

--- A root no build was started in is not staged, nor given a build
--- directory: none of its modules is found, so nothing is checked there,
--- and the person is shown once what to run. The first check after a
--- build is started there stages it, with no save or watched file, and
--- publishes what the build refuses.
local function test_a_root_no_build_was_started_in_publishes_nothing_until_one_is()
  local root = assert(Fs.mkdtemp("cosmic-lsp-"))
  assert(Fs.mkdirs(root .. "/lib"))
  assert(Fs.write(root .. "/lib/shapes.tl", THREE))
  local main = 'local shapes = require("lib.shapes")\nlocal s: string = shapes.sides\nreturn s\n'
  local send = serving(root)
  local before = send({ initialize(root), open(root, "main.tl", main), change(root, "main.tl", main .. "\n"),
    save(root, "main.tl") })
  assert(counts(before) == "0,0", counts(before))
  assert(shown(before) == 1, table.concat(before.sent, "\n"))
  assert(before.tally.stages == 0)
  local made, trouble = Fs.exists((assert(build_paths.directory(root))))
  assert(made ~= nil, trouble)
  assert(made == false, "a root that is no project gets a build directory")
  -- A build is started there, as `cosmic test` starts one.
  assert(work.close((assert(work.open(root)))))
  local after = send({ change(root, "main.tl", main) })
  assert(counts(after) == "0,0,1", counts(after))
  assert(only(nth(after, 3)).message == "`shapes.sides` is `integer`, where `string` is wanted as the value of `s` " ..
      "(not_assignable): pass a value of type `string`, or change the declaration to `integer`", messages_of(nth(after, 3)))
  assert(shown(after) == 1, table.concat(after.sent, "\n"))
  assert(after.tally.stages == 1, tostring(after.tally.stages))
end

--- The first request after a build is started where there was none may be a definition's: it stages the tree, and the
--- documents it left unchecked are checked again by the next change all the same.
local function test_a_definition_that_finds_a_build_started_leaves_the_open_documents_to_be_checked_again()
  local root = assert(Fs.mkdtemp("cosmic-lsp-"))
  assert(Fs.mkdirs(root .. "/lib"))
  assert(Fs.write(root .. "/lib/shapes.tl", THREE))
  local main = 'local shapes = require("lib.shapes")\nlocal s: string = shapes.sides\nreturn s\n'
  local other = "local n = 1\nreturn n\n"
  local send = serving(root)
  local before = send({ initialize(root), open(root, "main.tl", main), open(root, "other.tl", other) })
  assert(counts(before) == "0,0", counts(before))
  assert(work.close((assert(work.open(root)))))
  local after = send({ session_fixture.at(7, "textDocument/definition", root, "other.tl", 1, 8),
    change(root, "other.tl", other .. "\n") })
  local found = 0
  for _, diagnostics in ipairs(published(after)) do
    if #diagnostics == 1 and diagnostics[1].message:find("not_assignable", 1, true) ~= nil then
      found = found + 1
    end
  end
  assert(found == 1, "main is checked against the build now there: " .. counts(after))
end

--- A run that finds the database's schema stale makes it again
--- ([`work.open`]): the session reads the new file, not the one its
--- handle held.
local function test_a_database_made_again_is_opened_again()
  local root = project()
  assert(Fs.mkdirs(root .. "/lib"))
  assert(Fs.write(root .. "/lib/shapes.tl", THREE))
  local main = 'local shapes = require("lib.shapes")\nlocal n: integer = shapes.sides\nreturn n\n'
  local working = build_paths.under((assert(build_paths.directory(root)))).working
  local ran = served_between(root, { { initialize(root), open(root, "main.tl", main) },
    { change(root, "main.tl", main .. "\n") } }, function(_after: integer)
      assert(Fs.write(root .. "/lib/shapes.tl", STRINGS))
      local stale = assert(Sqlite.open(working, { writable = true }))
      assert(stale:exec("UPDATE meta SET value = 'stale' WHERE key = 'schema'"))
      assert(stale:close())
      -- A build makes the file again; a stage, which removes no file,
      -- then stages the change in it.
      assert(work.close((assert(work.open(root)))))
      assert(counts(served(root, { initialize(root), open(root, "main.tl", main) })) == "1")
    end)
  assert(ran.tally.reopened == 1, tostring(ran.tally.reopened))
  assert(counts(ran) == "0,1", "the new file is read: " .. counts(ran))
end

--- A directory whose first build failed, which left the working database
--- every build opens first but no projection, is a project, as `cosmic
--- test` treats it: it is staged, and a document is held to what the
--- build refuses, not told its modules are not found.
local function test_a_root_whose_first_build_failed_is_staged()
  local root = assert(Fs.mkdtemp("cosmic-lsp-"))
  assert(work.close((assert(work.open(root)))))
  local a = 'local b = require("b")\nreturn { b = b }\n'
  assert(Fs.write(root .. "/a.tl", a))
  assert(Fs.write(root .. "/b.tl", 'local a = require("a")\nreturn { a = a }\n'))
  local ran = served(root, { initialize(root), open(root, "a.tl", a) })
  assert(only(nth(ran, 1)).message == "a cycle of imports reaches a", messages_of(nth(ran, 1)))
  assert(ran.tally.stages == 1, tostring(ran.tally.stages))
  assert(shown(ran) == 0, table.concat(ran.sent, "\n"))
end

--- A file a build reads no module from -- a `testdata` directory's, a
--- site's static files -- publishes nothing, however wrong, and an open
--- one is no module a `require` finds.
local function test_a_file_a_build_reads_no_module_from_publishes_nothing()
  local root = project()
  local bad = 'local x: integer = "no"\nreturn x\n'
  local ran = served(root, { initialize(root), open(root, "testdata/bad.tl", bad),
    open(root, "lib/testdata/bad.tl", bad), open(root, "testdata/page.tmpl", "{{.nope"),
    open(root, "static/page.tmpl", "{{.nope"),
    open(root, "main.tl", 'local m = require("testdata.bad")\nlocal n: integer = m.n\nreturn n\n') })
  assert(counts(ran) == "0,0,0,0,1", counts(ran) .. "\n" .. messages_of(nth(ran, 5)))
  assert(only(nth(ran, 5)).message:find("testdata.bad", 1, true), messages_of(nth(ran, 5)))
end

--- Another run that derives the stubs again with another analyzer is
--- seen at the session's next check, with no stage of its own: each
--- module is then made here from its source.
local function test_stubs_another_run_derived_are_trusted_no_more()
  local root = project()
  assert(Fs.mkdirs(root .. "/lib"))
  assert(Fs.write(root .. "/lib/shapes.tl", THREE))
  local main = 'local shapes = require("lib.shapes")\nlocal n: integer = shapes.sides\nreturn n\n'
  local working = build_paths.under((assert(build_paths.directory(root)))).working
  local ran = served_between(root, { { initialize(root), open(root, "main.tl", main) },
    { change(root, "main.tl", main .. "\n") } }, function(_after: integer)
      local other = assert(Sqlite.open(working, { writable = true }))
      assert(other:exec("UPDATE meta SET value = 'another' WHERE key = 'analyzer'"))
      assert(other:close())
    end)
  assert(counts(ran) == "0,0", counts(ran))
  assert(ran.tally.stages == 1 and ran.tally.database_stubs == 1 and ran.tally.made_stubs == 1,
    tostring(ran.tally.stages) .. "," .. tostring(ran.tally.database_stubs) .. "," ..
      tostring(ran.tally.made_stubs))
end

--- `cosmic lsp` whose tool check went on without holding the tool to
--- the tree, another run holding the working database
--- ([`reboot.unchecked`]), stages nothing at any check, even once the
--- database is free, rather than derive stubs with code that may be
--- older than the tree's; it serves the stubs last staged and says why
--- once: on stderr, and to the person.
local function test_an_unchecked_lsp_stages_nothing_and_says_so_once()
  local root = project()
  assert(Fs.mkdirs(root .. "/core"))
  assert(Fs.mkdirs(root .. "/build"))
  assert(Fs.write(root .. "/build/importer.tl", "return {}\n"))
  assert(work.close((assert(work.open(root)))))
  local working = build_paths.resolve(root).working
  local held = assert(Sqlite.open(working, { writable = true }))
  assert(held:exec("BEGIN IMMEDIATE"))
  local built = assert(tree.built_from(root))
  local code = reboot.stale_exit({ "lsp" }, true, root,
    { tool = assert(Proc.executable()), environment = {}, meta = { built_from = built } })
  assert(held:exec("ROLLBACK"))
  assert(held:close())
  assert(code == nil, tostring(code))
  assert(reboot.unchecked(root), "the skipped check is not remembered")
  local send = serving(root)
  local main = "return 1\n"
  send({ initialize(root), open(root, "main.tl", main) })
  local ran = send({ change(root, "main.tl", main .. "\n"), save(root, "main.tl"),
    changed_on_disk(root, "main.tl"), change(root, "main.tl", main) })
  assert(ran.tally.stages == 0, "staged " .. tostring(ran.tally.stages) .. " times unchecked")
  local _, said = ran.err:gsub("was not checked against the tree", "")
  assert(said == 1, ran.err)
  local told = 0
  for _, body in ipairs(ran.sent) do
    if session_fixture.sent(body).method == "window/showMessage" and
        body:find("was not checked against the tree", 1, true) ~= nil then
      told = told + 1
    end
  end
  assert(told == 1, table.concat(ran.sent, "\n"))
end

--- A session whose tool was not checked against the tree takes none of
--- the database's stubs for its own: the analyzer the database records
--- is not taken as one this session staged with.
local function test_an_unchecked_lsp_trusts_no_analyzer_the_database_records()
  local root = project()
  assert(Fs.mkdirs(root .. "/core"))
  assert(Fs.mkdirs(root .. "/build"))
  assert(Fs.write(root .. "/build/importer.tl", "return {}\n"))
  assert(work.close((assert(work.open(root)))))
  local working = build_paths.resolve(root).working
  local held = assert(Sqlite.open(working, { writable = true }))
  assert(Sqlite.run(held, "INSERT OR REPLACE INTO meta (key, value) VALUES ('analyzer', 'another analyzer')"))
  assert(held:exec("BEGIN IMMEDIATE"))
  local built = assert(tree.built_from(root))
  local code = reboot.stale_exit({ "lsp" }, true, root,
    { tool = assert(Proc.executable()), environment = {}, meta = { built_from = built } })
  assert(held:exec("ROLLBACK"))
  assert(held:close())
  assert(code == nil, tostring(code))
  local src = source.new(root, function(_: string) end, built)
  source.refresh(src)
  assert(src.analyzer ~= "another analyzer", "took the database's analyzer for its own")
  assert(not src.stubs, "trusted the database's stubs")
end

--- What a session has said, line by line.
local record Said
  mut said: string
end

--- A session finds no module in a database that another tool's code
--- staged last, another run's ([`work.other_code`]), while that run
--- holds it, saying so once, and reads it again once its own stage,
--- with the database free, stages it.
local function test_a_database_another_code_staged_is_read_none_of_until_staged_again()
  local root = project()
  assert(Fs.mkdirs(root .. "/lib"))
  assert(Fs.write(root .. "/lib/shapes.tl", THREE))
  local held: Said = { said = "" }
  local src = source.new(root, function(line: string) held.said = held.said .. line .. "\n" end)
  source.refresh(src)
  assert(source.module(src, "lib/shapes.tl") ~= nil, "the staged module is not found")
  -- Another run stages it with its code and holds it on, so the session
  -- cannot stage it again.
  local other = assert(Sqlite.open(assert(src.working), { writable = true }))
  assert(other:exec("UPDATE meta SET value = 'another tool' WHERE key = 'staged_by'"))
  assert(other:exec("BEGIN IMMEDIATE"))
  source.refresh(src)
  assert(source.module(src, "lib/shapes.tl") == nil, "a module another code staged is found")
  source.refresh(src)
  assert(source.module(src, "lib/shapes.tl") == nil, "a module another code staged is found")
  local _, told = held.said:gsub("was staged by the tool of boot hash another tool", "")
  assert(told == 1, held.said)
  assert(other:exec("ROLLBACK"))
  assert(other:close())
  source.refresh(src)
  assert(source.module(src, "lib/shapes.tl") ~= nil, "the module its own stage staged is not found")
  source.close(src)
end

--- A session that finds the database staged by another tool's code,
--- with no run holding it, stages the tree again with its own code at
--- its next refresh, with no word from the editor, and finds its modules
--- again: the stage of a `cosmic test` that rebuilt the tool does not
--- leave every `require` unresolved until a file is saved.
local function test_a_database_another_code_staged_is_staged_again_at_the_next_refresh()
  local root = project()
  assert(Fs.mkdirs(root .. "/lib"))
  assert(Fs.write(root .. "/lib/shapes.tl", THREE))
  local src = source.new(root, function(_: string) end)
  source.refresh(src)
  assert(src.tally.stages == 1, tostring(src.tally.stages))
  local other = assert(Sqlite.open(assert(src.working), { writable = true }))
  assert(other:exec("UPDATE meta SET value = 'another tool' WHERE key = 'staged_by'"))
  assert(other:close())
  for _ = 1, 5 do
    source.refresh(src)
    assert(source.module(src, "lib/shapes.tl") ~= nil, "the module is not found again")
  end
  assert(src.tally.stages == 2, "staged " .. tostring(src.tally.stages) .. " times")
  source.close(src)
end

--- No document is open.
local function none_open(_file: string): source.Text?
  return nil
end

--- The document `file` open with `text`, and no other.
local function open_with(file: string, text: string): source.Open
  return function(name: string): source.Text?
    if name ~= file then return nil end
    return { text = text, hash = Hash.hex_sha256(text) }
  end
end

--- A module of two types, a field and a function that adds to the first.
local POINT <const> = "local record point\n  x: integer\n  record Corner\n    y: integer\n  end\nend\n\n" ..
  "function point.origin(): point\n  return { x = 0 }\nend\n\nreturn point\n"

--- The number of rows of `table` that hold the text `hash` in `db`.
local function rows_of(db: Sqlite.Handle, table_name: string, hash: string): integer
  local rows = assert(Sqlite.text_rows(db, "SELECT count(*) FROM " .. table_name .. " WHERE source_hash = ?1",
    { { text = hash } }))
  return math.tointeger(tonumber(assert(rows[1]):text(1))) or -1
end

--- The places of the staged module `lib.point`, read from the `places` rows the stage derived: nothing is derived, and a
--- row changed in the database changes the answer, which only a read of the rows does.
local function test_the_places_of_a_staged_module_are_read_from_the_database_and_not_derived()
  local root = project()
  assert(Fs.mkdirs(root .. "/lib"))
  assert(Fs.write(root .. "/lib/point.tl", POINT))
  local src = source.new(root, function(_: string) end)
  source.refresh(src)
  local placed = assert(source.places(src, "lib.point", none_open))
  assert(placed.file == "lib/point.tl" and placed.text() == POINT)
  local x, corner, origin = assert(placed.spots["point.x"]), assert(placed.spots["point.Corner"]),
    assert(placed.spots["point.origin"])
  assert(x.line == 2 and x.column == 3 and x.length == 1)
  assert(corner.line == 3 and corner.column == 10 and corner.length == 6)
  assert(assert(placed.spots["point.Corner.y"]).line == 4)
  assert(origin.line == 8 and origin.column == 16 and origin.length == 6)
  assert(placed.spots["point.missing"] == nil and src.tally.derived == 0, tostring(src.tally.derived))
  -- A row written by hand, in a module whose rows are read for the first time, is what is found.
  local held = assert(Sqlite.open(assert(src.working), { writable = true }))
  assert(held:exec("UPDATE places SET line = 6, column = 1, length = 3 WHERE symbol = 'point.x'"))
  assert(held:close())
  source.close(src)
  local again = source.new(root, function(_: string) end)
  source.refresh(again)
  local moved = assert(assert(source.places(again, "lib.point", none_open)).spots["point.x"])
  assert(moved.line == 6 and moved.column == 1 and moved.length == 3 and again.tally.derived == 0)
  assert(source.places(again, "lib.missing", none_open) == nil)
  source.close(again)
end

--- A header in the syscall grammar: `read` is declared on line 8.
local SYSCALLS_H <const> = table.concat({
  "/*",
  " * --- Reads bytes.",
  " * ---@param fd integer descriptor",
  " * ---@return string|nil data bytes",
  " * ---@return string error failure",
  " * ---@return integer errno number",
  " */",
  "COSMIC_SYSCALL(read, 1);",
  "",
}, "\n") .. "\n"

--- A project that is cosmic's own tree, with the header [`cosmic.sys`] is generated from staged.
local function own_tree_with_header(header?: string): string, string
  local root = project()
  assert(Fs.mkdirs(root .. "/core"))
  assert(Fs.mkdirs(root .. "/build"))
  assert(Fs.write(root .. "/build/importer.tl", "return {}\n"))
  assert(Fs.write(root .. "/core/syscalls.h", header or SYSCALLS_H))
  local built = assert(tree.built_from(root))
  return root, built
end

--- A field named like an annotation tag is found at its name, not at the tag on the same line.
local function test_a_generated_places_column_skips_the_annotation_tag_of_the_same_name()
  local header = table.concat({
    "/*", " * ---@class Constants", " * ---@field field integer a constant", " */", "COSMIC_CONSTANT(field)", "",
    "/*", " * --- Reads bytes.", " * ---@param fd integer descriptor", " * ---@return string|nil data bytes",
    " * ---@return string error failure", " * ---@return integer errno number", " */", "COSMIC_SYSCALL(read, 1);", "",
  }, "\n")
  local root, built = own_tree_with_header(header)
  local src = source.new(root, function(_: string) end, built)
  source.refresh(src)
  local spot = assert(assert(source.places(src, "cosmic.sys", none_open)).spots["sys.field"])
  assert(spot.line == 3 and spot.column == 14 and spot.length == 5,
    tostring(spot.line) .. ":" .. tostring(spot.column) .. ":" .. tostring(spot.length))
  source.close(src)
end

--- A module generated from a header has the places its `-- line` map names, at the lines of the header, in the header's
--- text and file: the generated source's own lines say nothing of it.
local function test_the_places_of_a_generated_module_are_the_headers_and_at_its_lines()
  local root, built = own_tree_with_header()
  local src = source.new(root, function(_: string) end, built)
  source.refresh(src)
  local placed = assert(source.places(src, "cosmic.sys", none_open))
  assert(placed.file == "core/syscalls.h" and placed.text() == SYSCALLS_H, placed.file)
  local read = assert(placed.spots["sys.read"])
  assert(read.line == 8 and read.column == 16 and read.length == 4,
    tostring(read.line) .. ":" .. tostring(read.column) .. ":" .. tostring(read.length))
  -- A symbol the map does not name has no place, and nothing is derived for the module.
  assert(placed.spots["sys"] == nil and placed.spots["sys.missing"] == nil and src.tally.derived == 0)
  -- An open document of the header, one the same as the staged file, is the staged file.
  local same = assert(source.places(src, "cosmic.sys", open_with("core/syscalls.h", SYSCALLS_H)))
  assert(assert(same.spots["sys.read"]).line == 8)
  -- One edited and not saved has its own lines: the generator is run on it.
  local edited_text = "/* edited */\n" .. SYSCALLS_H
  local edited = assert(source.places(src, "cosmic.sys", open_with("core/syscalls.h", edited_text)))
  local moved = assert(edited.spots["sys.read"])
  assert(edited.text() == edited_text and moved.line == 9 and moved.column == 16 and moved.length == 4,
    tostring(moved.line) .. ":" .. tostring(moved.column))
  assert(src.tally.derived == 0, "nothing is derived into the scratch database")
  -- A header being typed that the generator does not read has none.
  local shifted = "/* edited */\n" .. SYSCALLS_H .. "/*\n * --- X.\n */\nCOSMIC_SYSCALL(half, 2);\n"
  assert(source.places(src, "cosmic.sys", open_with("core/syscalls.h", shifted)) == nil,
    "lines inserted above and a half-typed call below: the staged lines are no answer")
  source.close(src)
end

--- A tree that lists no module generated from a header (its header was deleted since the stage) is answered from the
--- header the tool carries.
local function test_a_generated_module_of_a_tree_without_its_header_is_the_one_the_tool_carries()
  local root = project()
  local header = "/* A. */\nCOSMIC_SYSCALL(getpid, 0);\n"
  local db = session_fixture.carrying_origin("cosmic.sys", "core/syscalls.h", header, {
    { "sys.getpid", "field", "2", "1", "0", "0" } })
  local src = source.new(root, function(_: string) end, nil, { db })
  source.refresh(src)
  local placed = assert(source.places(src, "cosmic.sys", none_open))
  assert(placed.carried == Hash.hex_sha256(header) and assert(placed.spots["sys.getpid"]).column == 16)
  source.close(src)
  assert(db:close())
end

--- An open document the same as the staged file is the staged file; an edited one is derived once, into the scratch database.
local function test_the_places_of_an_open_module_are_derived_only_where_it_differs_from_the_staged_file()
  local root = project()
  assert(Fs.mkdirs(root .. "/lib"))
  assert(Fs.write(root .. "/lib/point.tl", POINT))
  local src = source.new(root, function(_: string) end)
  source.refresh(src)
  local same = assert(source.places(src, "lib.point", open_with("lib/point.tl", POINT)))
  assert(assert(same.spots["point.x"]).line == 2 and src.tally.derived == 0, tostring(src.tally.derived))
  local edited = "-- moved down\n\n" .. POINT
  for _ = 1, 3 do
    local placed = assert(source.places(src, "lib.point", open_with("lib/point.tl", edited)))
    assert(placed.text() == edited and assert(placed.spots["point.x"]).line == 4)
  end
  assert(src.tally.derived == 1, tostring(src.tally.derived))
  -- The file as staged is still what the rows say.
  assert(assert(assert(source.places(src, "lib.point", none_open)).spots["point.x"]).line == 2)
  assert(src.tally.derived == 1)
  source.close(src)
end

--- Rows another analyzer derived are none to read: the text is derived here, and read again when they are the running one's.
local function test_the_places_of_another_analyzers_rows_are_derived_here()
  local root = project()
  assert(Fs.mkdirs(root .. "/lib"))
  assert(Fs.write(root .. "/lib/point.tl", POINT))
  local src = source.new(root, function(_: string) end)
  source.refresh(src)
  local held = assert(Sqlite.open(assert(src.working), { writable = true }))
  assert(held:exec("UPDATE places SET line = 6"))
  assert(held:exec("UPDATE meta SET value = 'another' WHERE key = 'analyzer'"))
  assert(held:close())
  -- Read again, as every refresh does, finding the rows are not the running analyzer's.
  source.refresh(src)
  assert(assert(assert(source.places(src, "lib.point", none_open)).spots["point.x"]).line == 2)
  assert(src.tally.derived == 1, tostring(src.tally.derived))
  local hash = Hash.hex_sha256(POINT)
  assert(rows_of(assert(src.scratch), "places", hash) > 0, "served from the rows derived here")
  assert(src.tally.derived == 1)
  source.close(src)
end

--- A database another code staged is read none of, its places too.
local function test_the_places_of_a_database_another_code_staged_are_none()
  local root = project()
  assert(Fs.mkdirs(root .. "/lib"))
  assert(Fs.write(root .. "/lib/point.tl", POINT))
  local src = source.new(root, function(_: string) end)
  source.refresh(src)
  assert(source.places(src, "lib.point", none_open) ~= nil)
  local other = assert(Sqlite.open(assert(src.working), { writable = true }))
  assert(other:exec("UPDATE meta SET value = 'another tool' WHERE key = 'staged_by'"))
  assert(other:exec("BEGIN IMMEDIATE"))
  source.refresh(src)
  assert(source.places(src, "lib.point", none_open) == nil)
  assert(other:exec("ROLLBACK"))
  assert(other:close())
  source.close(src)
end

--- A staged module with no `parsed` row (one a stage recorded as broken, which a stage that refuses it does not list) has
--- no rows, which says nothing of what it declares: it is derived here from the text, and not found empty. A module that parsed
--- and declares nothing is found empty without a derive.
local function test_the_places_of_a_module_the_stage_has_no_parse_of_are_derived_here()
  local root = project()
  assert(Fs.mkdirs(root .. "/lib"))
  assert(Fs.write(root .. "/lib/point.tl", POINT))
  assert(Fs.write(root .. "/lib/none.tl", "return 1\n"))
  local src = source.new(root, function(_: string) end)
  source.refresh(src)
  assert(assert(source.places(src, "lib.none", none_open)).spots["none"] == nil and src.tally.derived == 0)
  local held = assert(Sqlite.open(assert(src.working), { writable = true }))
  assert(held:exec("DELETE FROM places"))
  assert(held:exec("DELETE FROM parsed WHERE source_hash IN (SELECT source_hash FROM inputs WHERE path = 'lib.point')"))
  assert(held:close())
  local placed = assert(source.places(src, "lib.point", none_open))
  assert(assert(placed.spots["point.x"]).line == 2 and src.tally.derived == 1, tostring(src.tally.derived))
  source.close(src)
end

--- An edited open document is derived into the scratch database and into `build.db` never; a new edit of the file replaces
--- the rows of the old, and the same text twice derives once.
local function test_an_edited_buffer_is_derived_into_the_scratch_database_alone()
  local root = project()
  assert(Fs.mkdirs(root .. "/lib"))
  assert(Fs.write(root .. "/lib/point.tl", POINT))
  local src = source.new(root, function(_: string) end)
  source.refresh(src)
  local edited = "-- moved down\n\n" .. POINT
  local hash = Hash.hex_sha256(edited)
  for _ = 1, 2 do
    local placed = assert(source.places(src, "lib.point", open_with("lib/point.tl", edited)))
    assert(assert(placed.spots["point.x"]).line == 4)
  end
  assert(src.tally.derived == 1, tostring(src.tally.derived))
  local scratch = assert(src.scratch)
  assert(rows_of(scratch, "places", hash) > 0 and rows_of(scratch, "parsed", hash) == 1)
  assert(rows_of(assert(src.db), "places", hash) == 0 and rows_of(assert(src.db), "parsed", hash) == 0,
    "build.db holds no row of an unsaved text")
  -- A new edit drops the rows of the text before it.
  local again = "-- moved down again\n\n\n" .. POINT
  local placed = assert(source.places(src, "lib.point", open_with("lib/point.tl", again)))
  assert(assert(placed.spots["point.x"]).line == 5 and src.tally.derived == 2, tostring(src.tally.derived))
  assert(rows_of(scratch, "places", hash) == 0 and rows_of(scratch, "parsed", hash) == 0)
  assert(rows_of(scratch, "places", Hash.hex_sha256(again)) > 0)
  source.close(src)
end

--- The members of a staged module are read from `build.db` and derived nowhere; an edited buffer's are derived once into the
--- scratch database with the docs of its text, and the rows of the text before an edit go with it.
local function test_the_members_of_a_module_are_read_from_the_database_or_derived_once_and_forgotten_on_an_edit()
  local root = project()
  assert(Fs.mkdirs(root .. "/lib"))
  assert(Fs.write(root .. "/lib/point.tl", POINT))
  local src = source.new(root, function(_: string) end)
  source.refresh(src)
  local staged = assert(source.members(src, "lib.point", none_open))
  assert(src.tally.derived == 0 and staged["point"] ~= nil and assert(staged["point"]).kind == "record")
  local first = assert(assert(staged["point"]).members[1])
  assert(first.name == "x" and first.type == "integer" and first.kind == "field")
  assert(source.members(src, "lib.missing", none_open) == nil)
  local edited = "--- Edited.\n" .. POINT:gsub("local record point\n", "local record point\n  --- The x.\n", 1)
  local hash = Hash.hex_sha256(edited)
  for _ = 1, 2 do
    local held = assert(source.members(src, "lib.point", open_with("lib/point.tl", edited)))
    assert(assert(assert(held["point"]).members[1]).doc == "The x.")
  end
  assert(src.tally.derived == 1, tostring(src.tally.derived))
  local scratch = assert(src.scratch)
  assert(rows_of(scratch, "members", hash) > 0 and rows_of(assert(src.db), "members", hash) == 0)
  local again = edited .. "\n"
  assert(source.members(src, "lib.point", open_with("lib/point.tl", again)) ~= nil)
  assert(rows_of(scratch, "members", hash) == 0 and rows_of(scratch, "docs", hash) == 0, "the rows of the earlier text go")
  assert(rows_of(scratch, "members", Hash.hex_sha256(again)) > 0)
  -- A text that does not parse has no members, as it has no parse.
  assert(source.members(src, "lib.point", open_with("lib/point.tl", "local record point\n  x: \n")) == nil)
  source.close(src)
end

--- Another run holds the write lock of `build.db` for as long as it builds; an edited buffer is still answered, as it
--- writes nowhere that run holds.
local function test_an_edited_buffer_is_answered_while_build_db_is_write_locked()
  local root = project()
  assert(Fs.mkdirs(root .. "/lib"))
  assert(Fs.write(root .. "/lib/point.tl", POINT))
  local src = source.new(root, function(_: string) end)
  source.refresh(src)
  local held = assert(Sqlite.open(assert(src.working), { writable = true }))
  assert(held:exec("BEGIN IMMEDIATE"))
  local placed = assert(source.places(src, "lib.point", open_with("lib/point.tl", "\n" .. POINT)))
  assert(assert(placed.spots["point.x"]).line == 3 and src.tally.derived == 1, tostring(src.tally.derived))
  assert(held:exec("ROLLBACK"))
  assert(held:close())
  source.close(src)
end

--- A closed document lets go of its rows; a save, which stages the text, lets them go and the rows of `build.db` answer.
local function test_a_closed_or_saved_buffer_lets_go_of_its_scratch_rows()
  local root = project()
  assert(Fs.mkdirs(root .. "/lib"))
  assert(Fs.write(root .. "/lib/point.tl", POINT))
  local src = source.new(root, function(_: string) end)
  source.refresh(src)
  local edited = "-- moved down\n\n" .. POINT
  local hash = Hash.hex_sha256(edited)
  local buffer = open_with("lib/point.tl", edited)
  assert(source.places(src, "lib.point", buffer) ~= nil)
  local scratch = assert(src.scratch)
  assert(rows_of(scratch, "places", hash) > 0)
  source.release(src, "lib/point.tl")
  assert(rows_of(scratch, "places", hash) == 0 and rows_of(scratch, "parsed", hash) == 0)
  -- Derived again, then saved: the file on disk is the buffer, and the stage derives it.
  assert(source.places(src, "lib.point", buffer) ~= nil and src.tally.derived == 2)
  assert(rows_of(scratch, "places", hash) > 0)
  assert(Fs.write(root .. "/lib/point.tl", edited))
  source.stale(src)
  source.refresh(src)
  assert(rows_of(scratch, "places", hash) == 0 and rows_of(scratch, "parsed", hash) == 0,
    "the refresh drops what the stage now answers")
  local placed = assert(source.places(src, "lib.point", buffer))
  assert(assert(placed.spots["point.x"]).line == 4 and src.tally.derived == 2, tostring(src.tally.derived))
  source.close(src)
end

--- Two files holding one text share its rows: the first to go leaves them.
local function test_a_text_two_files_hold_keeps_its_rows_until_both_let_go()
  local root = project()
  assert(Fs.mkdirs(root .. "/lib"))
  assert(Fs.write(root .. "/lib/point.tl", POINT))
  assert(Fs.write(root .. "/lib/other.tl", POINT .. "-- other\n"))
  local src = source.new(root, function(_: string) end)
  source.refresh(src)
  local edited = "-- moved down\n\n" .. POINT
  local hash = Hash.hex_sha256(edited)
  assert(source.places(src, "lib.point", open_with("lib/point.tl", edited)) ~= nil)
  assert(source.places(src, "lib.other", open_with("lib/other.tl", edited)) ~= nil)
  assert(src.tally.derived == 1, tostring(src.tally.derived))
  source.release(src, "lib/point.tl")
  assert(rows_of(assert(src.scratch), "places", hash) > 0)
  source.release(src, "lib/other.tl")
  assert(rows_of(assert(src.scratch), "places", hash) == 0)
  source.close(src)
end

--- A buffer being typed does not parse, and the places of what the parser recovered are still found.
local function test_the_places_of_a_buffer_with_a_syntax_error_are_still_found()
  local root = project()
  assert(Fs.mkdirs(root .. "/lib"))
  assert(Fs.write(root .. "/lib/point.tl", POINT))
  local src = source.new(root, function(_: string) end)
  source.refresh(src)
  local broken = POINT .. "local x = = 1\n"
  local placed = assert(source.places(src, "lib.point", open_with("lib/point.tl", broken)), "no places")
  assert(assert(placed.spots["point.x"], "no places while the buffer has a syntax error").line == 2)
  assert(rows_of(assert(src.scratch), "parsed", Hash.hex_sha256(broken)) == 0)
  source.close(src)
end

--- A file the tree stops listing lets go of its scratch rows at the next refresh.
local function test_a_file_the_tree_no_longer_lists_lets_go_of_its_scratch_rows()
  local root = project()
  assert(Fs.mkdirs(root .. "/lib"))
  assert(Fs.write(root .. "/lib/point.tl", POINT))
  local src = source.new(root, function(_: string) end)
  source.refresh(src)
  local edited = "-- moved down\n\n" .. POINT
  assert(source.places(src, "lib.point", open_with("lib/point.tl", edited)) ~= nil)
  local scratch = assert(src.scratch)
  assert(rows_of(scratch, "places", Hash.hex_sha256(edited)) > 0)
  assert(Fs.remove(root .. "/lib/point.tl"))
  source.stale(src)
  source.refresh(src)
  assert(rows_of(scratch, "places", Hash.hex_sha256(edited)) == 0)
  source.close(src)
end

--- A buffer broken and then fixed: the places-only rows of the broken text go, and the fixed text is derived whole.
local function test_a_broken_buffer_that_is_fixed_is_derived_whole()
  local root = project()
  assert(Fs.mkdirs(root .. "/lib"))
  assert(Fs.write(root .. "/lib/point.tl", POINT))
  local src = source.new(root, function(_: string) end)
  source.refresh(src)
  local broken = POINT .. "local x = = 1\n"
  local fixed = "-- fixed\n" .. POINT
  assert(source.places(src, "lib.point", open_with("lib/point.tl", broken)) ~= nil)
  local scratch = assert(src.scratch)
  assert(rows_of(scratch, "places", Hash.hex_sha256(broken)) > 0)
  local placed = assert(source.places(src, "lib.point", open_with("lib/point.tl", fixed)))
  assert(assert(placed.spots["point.x"]).line == 3 and src.tally.derived == 2, tostring(src.tally.derived))
  assert(rows_of(scratch, "parsed", Hash.hex_sha256(fixed)) == 1)
  assert(rows_of(scratch, "places", Hash.hex_sha256(fixed)) > 0)
  assert(rows_of(scratch, "places", Hash.hex_sha256(broken)) == 0)
  source.close(src)
end

local THING <const> = "--- A thing.\nlocal record thing\n  size: integer\nend\nfunction thing.make()\nend\nreturn thing\n"

--- A database as the tool carries one, holding the module `cosmic.thing` and its places, a module with none, and the
--- module [`cosmic.sys`] of a tool whose generated module has none.
local function carrying(): Sqlite.Handle
  local db = session_fixture.carrying("cosmic.thing", "cosmic/thing.tl", THING, {
    { "thing", "type", "2", "14", "5", "1" }, { "thing.size", "field", "3", "3", "4", "1" }, { "thing.make", "field", "5", "16", "4", "1" },
  })
  assert(db:exec("INSERT INTO modules (path, file, kind, source_hash, key, bytecode, tests, source) " ..
      "VALUES ('cosmic.bare', 'cosmic/bare.tl', 'module', CAST('ab' AS BLOB), x'00', x'00', '', deflate('return 1'))"))
  return db
end

--- The places of a module of the binary are read from the `places` and the `modules` of the database the tool carries, in
--- the text it carries; a name that is no module of the standard library, a module with no places, and a database that
--- lacks the table (a tool from before it) have none.
local function test_the_places_of_a_binary_module_are_read_from_the_database_the_tool_carries()
  local db = carrying()
  local src = source.new(project(), function(_: string) end, nil, { db })
  local placed = assert(source.places(src, "cosmic.thing", none_open))
  assert(placed.file == "cosmic/thing.tl" and placed.text() == THING, placed.text())
  assert(placed.carried == Hash.hex_sha256(THING), tostring(placed.carried))
  local size = assert(placed.spots["thing.size"])
  assert(size.line == 3 and size.column == 3 and size.length == 4)
  assert(assert(placed.spots["thing"]).column == 14 and placed.spots["thing.none"] == nil)
  assert(source.places(src, "cosmic.missing", none_open) == nil, "a module the database lacks")
  assert(source.places(src, "cosmic.bare", none_open) == nil, "a module with no places")
  assert(source.places(src, "lib.thing", none_open) == nil, "a name outside the standard library")
  assert(db:exec("DROP TABLE places"))
  local bare = source.new(project(), function(_: string) end, nil, { db })
  assert(source.places(bare, "cosmic.thing", none_open) == nil, "a tool with no places table")
  assert(db:exec("DROP TABLE modules"))
  assert(source.places(bare, "cosmic.thing", none_open) == nil, "a database with no modules table")
  assert(source.places(source.new(project(), function(_: string) end, nil, {}), "cosmic.thing", none_open) == nil,
    "no database")
  assert(db:close())
end

--- A module of the binary generated from a header has no `modules` row: its places are the header's lines, with the column
--- of each name found in the header the tool carries, and the header is the file it is placed in.
local function test_the_places_of_a_generated_binary_module_are_in_the_header_the_tool_carries()
  local header = "/* A. */\nint a;\nCOSMIC_SYSCALL(getpid, 0);\n"
  local db = session_fixture.carrying_origin("cosmic.sys", "core/syscalls.h", header, {
    { "sys.getpid", "field", "3", "1", "0", "0" }, { "sys.gone", "field", "9", "1", "0", "0" } })
  local src = source.new(project(), function(_: string) end, nil, { db })
  local placed = assert(source.places(src, "cosmic.sys", none_open))
  assert(placed.file == "core/syscalls.h" and placed.text() == header and placed.carried == Hash.hex_sha256(header))
  local spot = assert(placed.spots["sys.getpid"])
  assert(spot.line == 3 and spot.column == 16 and spot.length == 6 and not spot.plain, tostring(spot.column) .. "+" .. tostring(spot.length))
  assert(rawequal(placed, source.places(src, "cosmic.sys", none_open)), "the places are kept")
  assert(db:exec("DELETE FROM origins"))
  assert(source.places(src, "cosmic.sys", none_open) == nil, "a tool carrying no header of it")
  assert(db:close())
end

--- In a project, which the working database lists no `cosmic.*` module of, the places of a module of the binary are the
--- tool's own and are put in a read-only file below the build directory, once for a text and named for it. A module the
--- tool carries no places of has none.
local function test_a_binary_module_of_a_project_is_placed_in_a_file_the_build_directory_owns()
  local root = project()
  local db = carrying()
  local src = source.new(root, function(_: string) end, nil, { db })
  source.refresh(src)
  local placed = assert(source.places(src, "cosmic.thing", none_open))
  assert(assert(placed.spots["thing.make"]).line == 5 and placed.file == "cosmic/thing.tl")
  local directory = build_paths.under((assert(build_paths.directory(root)))).cosmic_source
  local path = assert(source.extracted(src, placed))
  assert(path == directory .. "/" .. Hash.hex_sha256(THING) .. "/cosmic/thing.tl", path)
  assert(Fs.read(path) == THING)
  assert(assert(Fs.stat(path)).mode & 0x1ff == 0x124, "the file is read-only")
  assert(source.extracted(src, placed) == path, "a second ask names the same file")
  assert(Fs.write(path, "tampered", 0x1a4))
  assert(source.extracted(src, placed) == path)
  assert(Fs.read(path) == THING and assert(Fs.stat(path)).mode & 0x1ff == 0x124, "a changed file is written again")
  -- The places of a module are kept by its hash: the database is read for the hash alone, and read whole when it moves.
  local again = assert(source.places(src, "cosmic.thing", none_open))
  assert(rawequal(again, placed), "the places are kept")
  assert(db:exec("UPDATE modules SET source_hash = CAST('cd' AS BLOB) WHERE path = 'cosmic.thing'"))
  local moved = assert(source.places(src, "cosmic.thing", none_open))
  assert(not rawequal(moved, placed) and moved.carried == "cd", "a module with another hash is read again")
  assert(source.places(src, "cosmic.sys", none_open) == nil)
  assert(source.places(src, "cosmic.bare", none_open) == nil)
  source.close(src)
  assert(db:close())
end

--- A module whose first line holds non-ASCII before its type's name, and whose later lines are ASCII.
local WIDE <const> = 'local s = "é😀" local record point\n  x: integer\nend\nreturn point\n'

--- A place on an ASCII line is put in the protocol's units without the module's text, which is read, once, only for a place
--- on a line that holds non-ASCII or follows an "\n\r" (the lexer counts it as one break, the protocol as two).
local function test_a_place_on_an_ascii_line_is_answered_without_reading_the_text()
  local root = project()
  assert(Fs.mkdirs(root .. "/lib"))
  assert(Fs.write(root .. "/lib/point.tl", WIDE))
  assert(Fs.write(root .. "/lib/crlf.tl", "-- a\n\rlocal record crlf\n  x: integer\nend\nreturn crlf\n"))
  local src = source.new(root, function(_: string) end)
  source.refresh(src)
  local placed = assert(source.places(src, "lib.point", none_open))
  local record, field = assert(placed.spots["point"]), assert(placed.spots["point.x"])
  assert(not record.plain and field.plain, "the line of the type holds non-ASCII, the field's does not")
  assert(src.tally.texts_read == 0, tostring(src.tally.texts_read))
  assert(placed.text() == WIDE and placed.text() == WIDE and src.tally.texts_read == 1, tostring(src.tally.texts_read))
  local doubled = assert(source.places(src, "lib.crlf", none_open))
  assert(not assert(doubled.spots["crlf"]).plain and not assert(doubled.spots["crlf.x"]).plain,
    "the lines after an \"\\n\\r\" are numbered another way by the protocol")
  -- An edited open document is derived with the flag, and its text is the document's: none is read.
  local edited = assert(source.places(src, "lib.point", open_with("lib/point.tl", "-- é\n" .. WIDE)))
  assert(assert(edited.spots["point.x"]).plain and not assert(edited.spots["point"]).plain)
  assert(src.tally.texts_read == 1, tostring(src.tally.texts_read))
  source.close(src)
end

--- The stub of an edited open document is the `stubs` row of its text in the scratch database, made once: none is made
--- here of the text, and the rows of a document that is the staged file's are the database's.
local function test_the_stub_of_an_edited_open_document_is_read_from_the_scratch_database()
  local root = project()
  assert(Fs.mkdirs(root .. "/lib"))
  assert(Fs.write(root .. "/lib/shapes.tl", THREE))
  local src = source.new(root, function(_: string) end)
  source.refresh(src)
  assert(source.served(src, "lib.shapes", open_with("lib/shapes.tl", THREE)) ~= nil)
  assert(src.tally.scratch_stubs == 0 and src.tally.database_stubs == 1 and next(src.made) == nil)
  local edited = open_with("lib/shapes.tl", STRINGS)
  for _ = 1, 3 do
    local stub = assert(source.served(src, "lib.shapes", edited))
    assert(stub.text:find("string", 1, true) ~= nil, stub.text)
  end
  assert(src.tally.scratch_stubs == 3 and src.tally.derived == 1 and next(src.made) == nil,
    tostring(src.tally.scratch_stubs) .. "," .. tostring(src.tally.derived))
  assert(rows_of(assert(src.scratch), "stubs", Hash.hex_sha256(STRINGS)) == 1)
  -- A text that does not parse has no row to read, and no stub: the source is served.
  local broken = assert(source.served(src, "lib.shapes", open_with("lib/shapes.tl", "local record shapes\n")))
  assert(broken.text == "local record shapes\n" and next(src.made) == nil, "parsed once, and not again for a stub")
  source.close(src)
end

--- What an open document requires is read of the rows of its text: the scratch database's where it was edited, `build.db`'s
--- where it is the staged file, and none where its text does not parse, a declaration or a template.
local function test_what_an_open_document_requires_is_read_from_the_rows_of_its_text()
  local root = project()
  assert(Fs.mkdirs(root .. "/lib"))
  assert(Fs.write(root .. "/lib/shapes.tl", THREE))
  local main = 'local shapes = require("lib.shapes")\nlocal n: integer = shapes.sides\nreturn n\n'
  assert(Fs.write(root .. "/main.tl", main))
  assert(Fs.write(root .. "/lib/decl.d.tl", "local record decl\n  sides: integer\nend\nreturn decl\n"))
  local src = source.new(root, function(_: string) end)
  source.refresh(src)
  local found = assert(source.module(src, "main.tl"))
  local staged = assert(source.requires_of(src, found, main, Hash.hex_sha256(main)))
  assert(table.concat(staged, ",") == "lib.shapes" and src.tally.scratch_requires == 0 and src.tally.derived == 0)
  local more = 'local decl = require("lib.decl")\n' .. main
  local edited = assert(source.requires_of(src, found, more, Hash.hex_sha256(more)))
  assert(table.concat(edited, ",") == "lib.decl,lib.shapes" and src.tally.scratch_requires == 1, table.concat(edited, ","))
  assert(source.requires_of(src, found, "local x =\n", Hash.hex_sha256("local x =\n")) == nil, "a text that does not parse")
  assert(source.requires_of(src, assert(source.module(src, "lib/decl.d.tl")), more, Hash.hex_sha256(more)) == nil,
    "a declaration is required by no one")
  source.close(src)
end

--- A session serves an edited open document to its dependents as its scratch stub, and keeps what it requires from the rows
--- of its text: a dependent sees its new exports at each edit, and no stub is made of its text here.
local function test_a_session_serves_an_edited_open_document_from_its_scratch_rows()
  local root = project()
  assert(Fs.mkdirs(root .. "/lib"))
  assert(Fs.write(root .. "/lib/shapes.tl", THREE))
  local main = 'local shapes = require("lib.shapes")\nlocal n: integer = shapes.sides\nreturn n\n'
  assert(Fs.write(root .. "/main.tl", "return 1\n"))
  local send = serving(root)
  local ran = send({ initialize(root), open(root, "main.tl", main), open(root, "lib/shapes.tl", STRINGS),
    change(root, "main.tl", main) })
  local first = publications(ran)
  assert(#assert(first[#first]).diagnostics == 1, "main reads the string the edited document exports")
  local after = send({ change(root, "lib/shapes.tl", FOUR), change(root, "main.tl", main) })
  local second = publications(after)
  assert(#assert(second[#second]).diagnostics == 0, "main reads the integer the document exports now")
  local tally = after.tally
  assert(tally.scratch_stubs >= 2 and tally.scratch_stubs == tally.made_stubs and tally.scratch_requires >= 3,
    tostring(tally.made_stubs) .. "," .. tostring(tally.scratch_stubs) .. "," .. tostring(tally.scratch_requires))
end

--- A text a quiet ask (a stub, the requires) cannot derive is not marked as derived: a later ask for its places derives it,
--- and says why where its rows fail to write, which a quiet ask did not.
local function test_a_text_a_quiet_ask_could_not_derive_is_derived_for_the_places_that_ask_later()
  local root = project()
  assert(Fs.mkdirs(root .. "/lib"))
  assert(Fs.write(root .. "/lib/shapes.tl", THREE))
  local said: mut {string} = {}
  local src = source.new(root, function(line: string) said[#said + 1] = line end)
  source.refresh(src)
  local found = assert(source.module(src, "lib/shapes.tl"))
  local broken = "local record shapes\n  sides: integer\n"
  local refused = 'local Test = require("cosmic.test")\nlocal function f() Test.policy{} end\nreturn {}\n'
  for _, text in ipairs({ broken, refused }) do
    local opened = open_with("lib/shapes.tl", text)
    for _ = 1, 2 do
      assert(source.served(src, "lib.shapes", opened) ~= nil)
      assert(source.requires_of(src, found, text, Hash.hex_sha256(text)) == nil or text == refused)
    end
    assert(src.scratched["lib/shapes.tl"] == nil and #said == 0, "a quiet ask marks and says nothing")
  end
  assert(src.tally.derived == 0, tostring(src.tally.derived))
  -- The places of the text that does not parse are those the parser recovered.
  local placed = assert(source.places(src, "lib.shapes", open_with("lib/shapes.tl", broken)))
  assert(assert(placed.spots["shapes.sides"]).line == 2 and src.tally.derived == 1 and #said == 0)
  -- The one the analysis refuses is said at the first ask for its places, and answers none.
  local none = assert(source.places(src, "lib.shapes", open_with("lib/shapes.tl", refused)))
  assert(next(none.spots) == nil and #said == 1 and said[1]:find("deriving lib/shapes.tl", 1, true) ~= nil, table.concat(said, "\n"))
  source.close(src)
end

--- The names the rows of a text give as its requires are the names the check reads of its syntax tree, for the forms of a
--- `require` the tree knows: both are [`build.syntax_node.require_sites`] of one parse of the text, so they cannot differ.
local function test_the_requires_rows_of_a_text_are_the_names_the_check_reads_of_its_tree()
  local root = project()
  assert(Fs.mkdirs(root .. "/lib"))
  assert(Fs.write(root .. "/lib/shapes.tl", THREE))
  local src = source.new(root, function(_: string) end)
  source.refresh(src)
  local found = assert(source.module(src, "lib/shapes.tl"))
  local text = table.concat({
    'local b = require("lib.b")', 'local a = require("lib.a")', 'local again = require("lib.b")',
    'local ok, c = pcall(require, "lib.c")', 'local type T = require("lib.d")', "return {}", "",
  }, "\n")
  local planned = syntax_read.plan_of("lib/shapes.tl", text, "lib.shapes", "module", false, false)
  local read: mut {string} = {}
  for _, site in ipairs(planned.requires) do read[#read + 1] = site.name end
  local rows = assert(source.requires_of(src, found, text, Hash.hex_sha256(text)))
  assert(#read == 4 and table.concat(rows, ",") == table.concat(read, ","), table.concat(rows, ",") .. " / " .. table.concat(read, ","))
  source.close(src)
end
