--- What a `require` reads in a `cosmic lsp` session ([`build.lsp.source`]):
--- the working database the build stages, as it was staged, with an open
--- document standing in for its file; a package's `init.tl`, a
--- declaration, a template; the stage made again when the editor says a
--- file changed on disk, and only then; which roots are staged; and the
--- files a build reads no module from.

local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Json = require("cosmic.json")
local Sqlite = require("cosmic.sqlite")
local build_paths = require("build.paths")
local session_fixture = require("build.lsp.session_fixture")
local source = require("build.lsp.source")
local teal = require("build.teal")
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

local function test_a_require_reads_an_open_document_before_the_disk()
  local root = project()
  assert(Fs.mkdirs(root .. "/lib"))
  assert(Fs.write(root .. "/lib/shapes.tl", "return { sides = 3 }\n"))
  local main = 'local shapes = require("lib.shapes")\nlocal n: integer = shapes.sides\nreturn n\n'
  local ran = served(root, {
    initialize(root),
    open(root, "main.tl", main),
    open(root, "lib/shapes.tl", 'return { sides = "three" }\n'),
    change(root, "main.tl", main),
    change(root, "lib/shapes.tl", "return { sides = 4 }\n"),
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
  assert(Fs.write(root .. "/lib/shapes/init.tl", "return { sides = 3 }\n"))
  assert(Fs.write(root .. "/lib/decl.d.tl", "local record decl\n  sides: integer\nend\nreturn decl\n"))
  assert(Fs.write(root .. "/lib/decl.tl", 'return { sides = "three" }\n'))
  local main = 'local shapes = require("lib.shapes")\nlocal decl = require("lib.decl")\n' ..
    "local n: integer = shapes.sides + decl.sides\nreturn n\n"
  local diagnostics = nth(served(root, { initialize(root), open(root, "main.tl", main) }), 1)
  assert(#diagnostics == 0, messages_of(diagnostics))
end

local function test_a_closed_document_no_longer_shadows_the_file()
  local root = project()
  assert(Fs.mkdirs(root .. "/lib"))
  assert(Fs.write(root .. "/lib/shapes.tl", "return { sides = 3 }\n"))
  local main = 'local shapes = require("lib.shapes")\nlocal n: integer = shapes.sides\nreturn n\n'
  local ran = served(root, {
    initialize(root),
    open(root, "lib/shapes.tl", 'return { sides = "three" }\n'),
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
  assert(Fs.write(root .. "/lib/shapes.tl", "return { sides = 3 }\n"))
  local main = 'local shapes = require("lib.shapes")\nlocal n: integer = shapes.sides\nreturn n\n'
  local send = serving(root)
  send({ initialize(root), open(root, "main.tl", main), open(root, "other.tl", "return 2\n") })
  assert(Fs.write(root .. "/lib/shapes.tl", 'return { sides = "three" }\n'))
  local sent = publications(send({ save(root, "lib/shapes.tl") }))
  assert(#sent == 3, "only main changed: " .. tostring(#sent))
  local third = assert(sent[3])
  assert(third.uri == "file://" .. root .. "/main.tl" and #third.diagnostics == 1, third.uri)
end

local function test_the_same_text_checks_the_same_each_time()
  local root = project()
  -- A module that declares a global, which the document reads.
  assert(Fs.write(root .. "/g.tl", "global G_VAL: integer = 1\nreturn {}\n"))
  local reader = 'local _ = require("g")\nlocal n: integer = G_VAL\nreturn n\n'
  local declares = "global G_OWN: integer = 1\nlocal s: string = G_OWN\nreturn s\n"
  -- A request between two changes keeps the second from standing for
  -- both ([`build.lsp.session`] checks only the last of changes read together).
  local between = '{"jsonrpc":"2.0","id":7,"method":"nosuch"}'
  local ran = served(root, { initialize(root),
    open(root, "m2.tl", reader), change(root, "m2.tl", reader), between, change(root, "m2.tl", reader),
    open(root, "own.tl", declares), change(root, "own.tl", declares),
  })
  assert(counts(ran) == "0,0,0,2,2", counts(ran) .. "\n" .. messages_of(nth(ran, 2)))
  local own, again = messages_of(nth(ran, 4)), messages_of(nth(ran, 5))
  assert(own == again, own .. "\n--\n" .. again)
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
  assert(Fs.write(root .. "/lib/shapes.tl", 'return { sides = "three" }\n'))
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
    assert(found.message:find("expected integer", 1, true), params .. ": " .. found.message)
  end
end

local function test_a_template_is_a_module_and_testdata_is_none()
  local root = project()
  assert(Fs.mkdirs(root .. "/testdata"))
  assert(Fs.write(root .. "/data.tl", "local record data\n  record Page\n    title: string\n  end\nend\nreturn data\n"))
  assert(Fs.write(root .. "/page.tmpl", "{{type Page from data}}{{mode text}}one {{.title}}"))
  assert(Fs.write(root .. "/testdata/m.tl", "return { n = 1 }\n"))
  local main = 'local page = require("page")\nlocal data = require("data")\n' ..
    'local p: data.Page = { title = "t" }\nlocal n: integer = page.render(p)\nreturn n\n'
  local rendered = only(nth(served(root, { initialize(root), open(root, "main.tl", main) }), 1))
  assert(rendered.message:find("expected integer", 1, true), "the template renders a string: " ..
      rendered.message)
  local fixture = 'local m = require("testdata.m")\nreturn m\n'
  local unfound = only(nth(served(root, { initialize(root), open(root, "main.tl", fixture) }), 1))
  assert(unfound.message:find("testdata.m", 1, true), unfound.message)
end

local function test_the_disk_is_read_only_when_the_editor_says_it_changed()
  local root = project()
  assert(Fs.mkdirs(root .. "/lib"))
  assert(Fs.write(root .. "/lib/shapes.tl", "return { sides = 3 }\n"))
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
  assert(Fs.write(root .. "/lib/shapes.tl", 'return { sides = "three" }\n'))
  send({ change(root, "main.tl", main .. "\n") })
  -- A module the stage has not seen is not found, though the file is there.
  assert(Fs.write(root .. "/lib/more.tl", "return { n = 1 }\n"))
  send({ change(root, "main.tl", 'local _ = require("lib.more")\n' .. main) })
  local ran = send({ changed_on_disk(root, "lib/shapes.tl") })
  assert(counts(ran) == "0,0,1,1", "as staged, until the editor says it changed: " .. counts(ran) ..
      "\n" .. messages_of(nth(ran, 3)) .. "\n" .. messages_of(nth(ran, 4)))
  assert(messages_of(nth(ran, 3)):find("lib.more", 1, true), messages_of(nth(ran, 3)))
  assert(messages_of(nth(ran, 4)):find("got string", 1, true), messages_of(nth(ran, 4)))
end

--- While another run holds the database's write transaction open, with
--- more written than its cache holds (in rollback mode, a spill that
--- holds the file whole), the session stages nothing and reads the last
--- commit at once: it waits on no lock, and none fails its read.
local function test_a_busy_database_is_read_at_once_as_last_committed()
  local root = project()
  assert(Fs.mkdirs(root .. "/lib"))
  assert(Fs.write(root .. "/lib/shapes.tl", "return { sides = 3 }\n"))
  local main = 'local shapes = require("lib.shapes")\nlocal n: integer = shapes.sides\nreturn n\n'
  local send = serving(root)
  send({ initialize(root), open(root, "main.tl", main) })
  assert(Fs.write(root .. "/lib/shapes.tl", 'return { sides = "three" }\n'))
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
  assert(Fs.write(root .. "/lib/shapes.tl", "return { sides = 3 }\n"))
  local main = 'local shapes = require("lib.shapes")\nlocal n: integer = shapes.sides\nreturn n\n'
  local send = serving(root)
  send({ initialize(root), open(root, "main.tl", main) })
  local working = build_paths.under((assert(build_paths.directory(root)))).working
  local stale = assert(Sqlite.open(working, { writable = true }))
  assert(stale:exec("UPDATE meta SET value = 'another' WHERE key = 'schema'"))
  assert(stale:close())
  local before = assert(Fs.stat(working)).ino
  assert(Fs.write(root .. "/lib/shapes.tl", 'return { sides = "three" }\n'))
  local other = send({ save(root, "lib/shapes.tl") })
  assert(other.err:find("is of schema another", 1, true), other.err)
  assert(assert(Fs.stat(working)).ino == before, "the file was removed")
  -- None of its modules is read.
  assert(counts(other) == "0,1", counts(other))
  assert(messages_of(nth(other, 2)):find("module not found: 'lib.shapes'", 1, true),
    messages_of(nth(other, 2)))
  assert(work.close((assert(work.open(root)))))
  local ran = send({ change(root, "main.tl", main .. "\n") })
  assert(counts(ran) == "0,1,1", "staged once made again: " .. counts(ran))
  assert(messages_of(nth(ran, 3)):find("got string", 1, true), messages_of(nth(ran, 3)))
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
  local built = assert(teal.load())
  source.refresh(src, built)
  assert(holds(src), "the database is not read")
  stamp_another(assert(src.working))
  source.stale(src)
  source.refresh(src, built)
  assert(not holds(src), "a handle on a database of another schema is kept")
  source.close(src)
end

--- A session that reads the database finds, at its next check, the
--- file made again under it as another schema's, another tool's: it
--- reads none of the new file, which lists the same modules, and says
--- why.
local function test_a_database_made_again_of_another_schema_under_the_session_is_not_read()
  local root = project()
  assert(Fs.mkdirs(root .. "/lib"))
  assert(Fs.write(root .. "/lib/shapes.tl", "return { sides = 3 }\n"))
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
  assert(messages_of(nth(ran, 2)):find("module not found: 'lib.shapes'", 1, true),
    messages_of(nth(ran, 2)))
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
--- declaration, or a source that returns nothing.
local function test_each_module_is_served_as_its_stub_where_it_has_one()
  local root = project()
  assert(Fs.mkdirs(root .. "/lib"))
  assert(Fs.write(root .. "/lib/shapes.tl", "return { sides = 3 }\n"))
  assert(Fs.write(root .. "/lib/decl.d.tl", "local record decl\n  sides: integer\nend\nreturn decl\n"))
  assert(Fs.write(root .. "/lib/none.tl", "local _ = 1\n"))
  local main = 'local shapes = require("lib.shapes")\nlocal decl = require("lib.decl")\n' ..
    'local _ = require("lib.none")\nlocal n: integer = shapes.sides + decl.sides\nreturn n\n'
  local send = serving(root)
  local first = send({ initialize(root), open(root, "main.tl", main) })
  assert(counts(first) == "0", messages_of(nth(first, 1)))
  local tally = first.tally
  assert(tally.database_stubs == 1 and tally.made_stubs == 0 and tally.sources == 2,
    tostring(tally.database_stubs) .. "," .. tostring(tally.made_stubs) .. "," .. tostring(tally.sources))
  local after = send({ open(root, "lib/shapes.tl", "return { sides = 4 }\n"), change(root, "main.tl", main) }).tally
  assert(after.made_stubs == 1 and after.database_stubs == 1, tostring(after.made_stubs))
end

--- Where the database's stubs are another analyzer's, each is made here
--- from the source the database holds.
local function test_a_stub_of_another_analyzer_is_made_here()
  local root = project()
  assert(Fs.mkdirs(root .. "/lib"))
  assert(Fs.write(root .. "/lib/shapes.tl", "return { sides = 3 }\n"))
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
  assert(Fs.write(root .. "/lib/shapes.tl", "return { sides = 3 }\n"))
  local main = 'local shapes = require("lib.shapes")\nlocal n: integer = shapes.sides\nreturn n\n'
  local send = serving(root)
  assert(counts(send({ initialize(root), open(root, "main.tl", main) })) == "0")
  assert(Fs.write(root .. "/lib/shapes.tl", 'return { sides = "three" }\n'))
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
  assert(Fs.write(root .. "/lib/shapes.tl", "return { sides = 3 }\n"))
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
  assert(only(nth(after, 3)).message:find("got integer, expected string", 1, true), messages_of(nth(after, 3)))
  assert(shown(after) == 1, table.concat(after.sent, "\n"))
  assert(after.tally.stages == 1, tostring(after.tally.stages))
end

--- A run that finds the database's schema stale makes it again
--- ([`work.open`]): the session reads the new file, not the one its
--- handle held.
local function test_a_database_made_again_is_opened_again()
  local root = project()
  assert(Fs.mkdirs(root .. "/lib"))
  assert(Fs.write(root .. "/lib/shapes.tl", "return { sides = 3 }\n"))
  local main = 'local shapes = require("lib.shapes")\nlocal n: integer = shapes.sides\nreturn n\n'
  local working = build_paths.under((assert(build_paths.directory(root)))).working
  local ran = served_between(root, { { initialize(root), open(root, "main.tl", main) },
    { change(root, "main.tl", main .. "\n") } }, function(_after: integer)
      assert(Fs.write(root .. "/lib/shapes.tl", 'return { sides = "three" }\n'))
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
    open(root, "main.tl", 'local m = require("testdata.bad")\nreturn m\n') })
  assert(counts(ran) == "0,0,0,0,1", counts(ran) .. "\n" .. messages_of(nth(ran, 5)))
  assert(only(nth(ran, 5)).message:find("testdata.bad", 1, true), messages_of(nth(ran, 5)))
end

--- Another run that derives the stubs again with another analyzer is
--- seen at the session's next check, with no stage of its own: each
--- module is then made here from its source.
local function test_stubs_another_run_derived_are_trusted_no_more()
  local root = project()
  assert(Fs.mkdirs(root .. "/lib"))
  assert(Fs.write(root .. "/lib/shapes.tl", "return { sides = 3 }\n"))
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
