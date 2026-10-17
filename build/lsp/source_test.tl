--- What a `require` reads in a `cosmic lsp` session ([`build.lsp.source`]):
--- the working database the build stages, as it was staged, with an open
--- document standing in for its file; a package's `init.tl`, a
--- declaration, a template; and the stage made again when the editor says
--- a file changed on disk, and only then.

local Fs = require("cosmic.fs")
local Json = require("cosmic.json")
local Sqlite = require("cosmic.sqlite")
local build_paths = require("build.paths")
local session_fixture = require("build.lsp.session_fixture")

local change, changed_on_disk, close = session_fixture.change, session_fixture.changed_on_disk,
  session_fixture.close
local counts, initialize, messages_of = session_fixture.counts, session_fixture.initialize,
  session_fixture.messages_of
local nth, only, open = session_fixture.nth, session_fixture.only, session_fixture.open
local publications, published = session_fixture.publications, session_fixture.published
local requests, save, served = session_fixture.requests, session_fixture.save, session_fixture.served
local serving = session_fixture.serving

local function test_a_require_reads_an_open_document_before_the_disk()
  local root = assert(Fs.mkdtemp("cosmic-lsp-"))
  assert(Fs.mkdirs(root .. "/lib"))
  assert(Fs.write(root .. "/lib/shapes.tl", "return { sides = 3 }\n"))
  local main = 'local shapes = require("lib.shapes")\nlocal n: integer = shapes.sides\nreturn n\n'
  local runs = published(served(root, {
    initialize(root),
    open(root, "main.tl", main),
    open(root, "lib/shapes.tl", 'return { sides = "three" }\n'),
    change(root, "main.tl", main),
    change(root, "lib/shapes.tl", "return { sides = 4 }\n"),
    change(root, "main.tl", main),
  }))
  assert(#runs == 5)
  assert(#runs[1] == 0, "the file on disk types")
  assert(#runs[3] == 1, "the open document's string is what main reads")
  assert(#runs[5] == 0, "the document's change is read again")
end

local function test_a_package_module_is_its_init()
  local root = assert(Fs.mkdtemp("cosmic-lsp-"))
  assert(Fs.mkdirs(root .. "/lib/shapes"))
  assert(Fs.write(root .. "/lib/shapes/init.tl", "return { sides = 3 }\n"))
  assert(Fs.write(root .. "/lib/decl.d.tl", "local record decl\n  sides: integer\nend\nreturn decl\n"))
  assert(Fs.write(root .. "/lib/decl.tl", 'return { sides = "three" }\n'))
  local main = 'local shapes = require("lib.shapes")\nlocal decl = require("lib.decl")\n' ..
    "local n: integer = shapes.sides + decl.sides\nreturn n\n"
  local diagnostics = published(served(root, { initialize(root), open(root, "main.tl", main) }))[1]
  assert(#diagnostics == 0, messages_of(diagnostics))
end

local function test_a_closed_document_no_longer_shadows_the_file()
  local root = assert(Fs.mkdtemp("cosmic-lsp-"))
  assert(Fs.mkdirs(root .. "/lib"))
  assert(Fs.write(root .. "/lib/shapes.tl", "return { sides = 3 }\n"))
  local main = 'local shapes = require("lib.shapes")\nlocal n: integer = shapes.sides\nreturn n\n'
  local runs = published(served(root, {
    initialize(root),
    open(root, "lib/shapes.tl", 'return { sides = "three" }\n'),
    open(root, "main.tl", main),
    close(root, "lib/shapes.tl"),
    change(root, "main.tl", main),
  }))
  assert(#runs == 4)
  assert(#runs[2] == 1, "the open document is what main reads")
  assert(#runs[4] == 0, "the file is, once the document closes: " .. messages_of(assert(runs[4])))
end

local function test_a_save_stages_again_and_publishes_what_changed()
  local root = assert(Fs.mkdtemp("cosmic-lsp-"))
  assert(Fs.mkdirs(root .. "/lib"))
  assert(Fs.write(root .. "/lib/shapes.tl", "return { sides = 3 }\n"))
  local main = 'local shapes = require("lib.shapes")\nlocal n: integer = shapes.sides\nreturn n\n'
  local send = serving(root)
  send({ initialize(root), open(root, "main.tl", main), open(root, "other.tl", "return 2\n") })
  assert(Fs.write(root .. "/lib/shapes.tl", 'return { sides = "three" }\n'))
  local sent = publications(send({ save(root, "lib/shapes.tl") }))
  assert(#sent == 3, "only main changed: " .. tostring(#sent))
  assert(sent[3].uri == "file://" .. root .. "/main.tl" and #sent[3].diagnostics == 1, sent[3].uri)
end

local function test_the_same_text_checks_the_same_each_time()
  local root = assert(Fs.mkdtemp("cosmic-lsp-"))
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
    assert(found.message:find("expected integer", 1, true) ~= nil, params .. ": " .. found.message)
  end
end

local function test_a_template_is_a_module_and_testdata_is_none()
  local root = assert(Fs.mkdtemp("cosmic-lsp-"))
  assert(Fs.mkdirs(root .. "/testdata"))
  assert(Fs.write(root .. "/data.tl", "local record data\n  record Page\n    title: string\n  end\nend\nreturn data\n"))
  assert(Fs.write(root .. "/page.tmpl", "{{type Page from data}}{{mode text}}one {{.title}}"))
  assert(Fs.write(root .. "/testdata/m.tl", "return { n = 1 }\n"))
  local main = 'local page = require("page")\nlocal data = require("data")\n' ..
    'local p: data.Page = { title = "t" }\nlocal n: integer = page.render(p)\nreturn n\n'
  local rendered = only(nth(served(root, { initialize(root), open(root, "main.tl", main) }), 1))
  assert(rendered.message:find("expected integer", 1, true) ~= nil, "the template renders a string: " ..
      rendered.message)
  local fixture = 'local m = require("testdata.m")\nreturn m\n'
  local unfound = only(nth(served(root, { initialize(root), open(root, "main.tl", fixture) }), 1))
  assert(unfound.message:find("testdata.m", 1, true) ~= nil, unfound.message)
end

local function test_the_disk_is_read_only_when_the_editor_says_it_changed()
  local root = assert(Fs.mkdtemp("cosmic-lsp-"))
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
  assert(table.concat(first.sent, "\n"):find('"globPattern":"**/*.tl"', 1, true) ~= nil)
  assert(#requests(served(root, { initialize(root), initialized })) == 0,
    "no registration where the editor takes none")
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
  assert(messages_of(nth(ran, 3)):find("lib.more", 1, true) ~= nil, messages_of(nth(ran, 3)))
  assert(messages_of(nth(ran, 4)):find("got string", 1, true) ~= nil, messages_of(nth(ran, 4)))
end

local function test_a_busy_database_is_answered_from_as_last_staged()
  local root = assert(Fs.mkdtemp("cosmic-lsp-"))
  assert(Fs.mkdirs(root .. "/lib"))
  assert(Fs.write(root .. "/lib/shapes.tl", "return { sides = 3 }\n"))
  local main = 'local shapes = require("lib.shapes")\nlocal n: integer = shapes.sides\nreturn n\n'
  local send = serving(root)
  send({ initialize(root), open(root, "main.tl", main) })
  assert(Fs.write(root .. "/lib/shapes.tl", 'return { sides = "three" }\n'))
  -- Another run holds the database's write lock, as a build's does.
  local held = assert(Sqlite.open(build_paths.under((assert(build_paths.directory(root)))).working,
    { writable = true }))
  assert(held:exec("BEGIN IMMEDIATE"))
  local busy = send({ save(root, "lib/shapes.tl") })
  assert(busy.err:find("another cosmic run holds", 1, true) ~= nil, busy.err)
  assert(counts(busy) == "0", "nothing changed as last staged: " .. counts(busy))
  assert(held:exec("ROLLBACK"))
  assert(held:close())
  local ran = send({ change(root, "main.tl", main .. "\n") })
  assert(counts(ran) == "0,1", "staged once the lock is free: " .. counts(ran))
end
