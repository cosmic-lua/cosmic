--- Proves `cosmic build` writes an executable for a project: the tree
--- is a fixture under a fresh temp directory, shaped as a binary is --
--- `cmd/<name>/main.tl` and a module beside it -- and the database the
--- executable carries is read back and checked for what a program
--- needs at run time and nothing it does not. These need `tool`: an
--- executable's database is joined from this program's own
--- ([`embed.database`] reads [`Store.databases()`], every `cosmic.*`
--- module's rows), which the store a worker without it is given does not
--- hold. What writes no executable is in `embed_test.tl`.

local Child = require("cosmic.child")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Proc = require("cosmic.proc")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local artifact = require("build.artifact")
local embed = require("build.embed")
local invoke = require("build.invoke")
local Test = require("cosmic.test")
local String = require("cosmic.string")
local Clock = require("cosmic.clock")
local support = require("build.test_support_fixture")

--- The number `text` reads as, which the case knows is one.
local function count_of(text: string): number
  local count = tonumber(text)
  assert(count ~= nil, "a number: " .. text)
  return count
end

--- This program's database, which every executable's is joined from.
--- The programs these tests run are built `--host`, so no launcher --
--- and no `sh` -- runs them.
--- `store`: [`embed.database`] reads every `cosmic.*` module's rows.
Test.policy{
  profiles = { "cosmic" },
  grants = { { path = "o/bin", letters = "rx" }, { path = "o/cosmic.db", letters = "r" },
    { path = "testdata/projects", letters = "r" } },
}

local main_source = [[
local Fs = require("cosmic.fs")
local greet = require("greet")

return function(argv: {string}): integer
  local _, _ = Fs.put(Fs.stdout, greet.hello(argv[1] or "world") .. "\n")
  return #argv
end
]]

local greet_source = [[
local record greet
end

function greet.hello(name: string): string
  return "hello, " .. name
end

return greet
]]

--- Writes the fixture project under `root`.
local function write_project(root: string)
  assert(Fs.mkdirs(root .. "/cmd/hello"))
  assert(Fs.write(root .. "/cmd/hello/main.tl", main_source))
  assert(Fs.write(root .. "/greet.tl", greet_source))
end

local function rows_of(path: string, sql: string): Sqlite.Rows
  local db = assert(Sqlite.open(path))
  local rows = assert(Sqlite.text_rows(db, sql))
  db:close()
  return rows
end

--- `cosmic build` prints each program it wrote, its bare path on a line of
--- its own, for a caller to run.
local function test_build_prints_the_path_of_each_program(tmp: string)
  write_project(tmp)
  assert(Fs.mkdirs(tmp .. "/cmd/bye"))
  assert(Fs.write(tmp .. "/cmd/bye/main.tl", "return function(): integer return 0 end\n"))
  local built = invoke.run({ "build", "--host" }, { cwd = tmp,
    env = { COSMIC_BUILD_CACHE = "0", COSMIC_BUILD_HOME = assert(Env.get("COSMIC_BUILD_HOME")) } })
  assert(built.code == 0, built.stdout .. built.stderr)
  local bin = support.build_dir(tmp) .. "/bin"
  local lines: mut {string} = {}
  for line in built.stdout:gmatch("[^\n]+") do
    lines[#lines + 1] = line
  end
  assert(lines[1] == bin .. "/bye" and lines[2] == bin .. "/hello", built.stdout)
end

local function test_the_carried_database_holds_what_a_program_needs(tmp: string)
  write_project(tmp)
  assert(embed.tree(tmp, true))
  local database = assert(embed.database(support.build_dir(tmp) .. "/cosmic.db", "cmd.hello.main"))
  local path = tmp .. "/carried.db"
  assert(Fs.write(path, database))

  local meta: mut {string:string} = {}
  for _, row in ipairs(rows_of(path, "SELECT key, value FROM meta")) do
    meta[row:text(1)] = row:text(2)
  end
  assert(meta["main"] == "cmd.hello.main", "main names the module to run")
  assert(meta["host"] == nil, "a portable database carries no host")
  assert(meta["runtime"] == nil, "a portable database carries no runtime")
  assert(meta["runtime_basis"] ~= nil and meta["runtime_basis"] ~= "",
    "a portable database carries the runtime basis")

  local modules: mut {string:string} = {}
  for _, row in ipairs(rows_of(path, "SELECT path, kind FROM modules")) do
    modules[row:text(1)] = row:text(2)
  end
  assert(modules["cmd.hello.main"] == "main", "the project's main is in")
  assert(modules["greet"] == "module", "the project's own module is in")
  assert(modules["cosmic.fs"] == "module", "the standard library is in")
  assert(modules["cosmic.sqlite"] == "module")
  assert(modules["cosmic.coverage_test"] == nil, "a stdlib test is not")
  assert(modules["build.importer"] == nil, "the build is not")
  assert(modules["vendor.tl"] == nil, "the compiler is not")

  local decls = rows_of(path, "SELECT path FROM decls WHERE path = 'cosmic.sys'")
  assert(#decls == 1, "the syscall declaration is in")
  local images = rows_of(path,
    "SELECT count(*) FROM sqlite_schema WHERE name = 'images'")
  assert(support.nth(images, 1):text(1) == "0", "portable databases have no images table")
  local guidance = rows_of(path,
    "SELECT count(*) FROM catalog_fts WHERE catalog_fts MATCH 'coverage'")
  assert(count_of(support.nth(guidance, 1):text(1)) > 0, "the error catalog is in, and indexed")
  local text = rows_of(path,
    "SELECT text IS NULL, length(file) > 0, line > 0 FROM catalog " ..
      "WHERE symbol = 'Coverage.start'")
  assert(#text == 1 and support.nth(text, 1):text(1) == "1" and
      support.nth(text, 1):text(2) == "1" and support.nth(text, 1):text(3) == "1",
    "a row with no text of its own carries none, nor the doc comment: " ..
      "it carries where it is")
  local about_build = rows_of(path,
    "SELECT count(*) FROM catalog WHERE module LIKE 'build.%'")
  assert(support.nth(about_build, 1):text(1) == "0", "guidance about the build is not")
  local databases = Store.databases()
  local own = assert(databases[#databases], "this program has a database")
  local carried = assert(Sqlite.text_rows(own, "SELECT count(*) FROM zoneinfo"))
  local zones = rows_of(path, "SELECT count(*), sum(name = 'America/New_York') FROM zoneinfo")
  assert(support.nth(zones, 1):text(1) == support.nth(carried, 1):text(1) and count_of(support.nth(zones, 1):text(1)) > 500 and support.nth(zones, 1):text(2) == "1",
    "every zone the binary carries is in")
  local assets = assert(Sqlite.text_rows(own,
    "SELECT group_concat(name || ' ' || version || ' ' || sha256, ',' ORDER BY name) FROM web_assets"))
  local web = rows_of(path,
    "SELECT group_concat(name || ' ' || version || ' ' || sha256, ',' ORDER BY name) FROM web_assets")
  assert(support.nth(web, 1):text(1) ~= nil and support.nth(web, 1):text(1) == support.nth(assets, 1):text(1) and support.nth(web, 1):text(1):find("htmx.min.js", 1, true) ~= nil,
    "every web asset the binary carries is in")
  local materials = rows_of(path,
    "SELECT (SELECT count(*) FROM components WHERE name = 'lua'), " ..
      "(SELECT count(*) FROM notices WHERE component = 'lua' AND text LIKE '%Lua.org%')")
  assert(support.nth(materials, 1):text(1) == "1" and support.nth(materials, 1):text(2) == "1",
    "the program carries the bill of materials its cores ship under")
  local trusted = rows_of(path, "SELECT count(*) FROM ca_roots")
  assert(count_of(support.nth(trusted, 1):text(1)) > 100, "the program carries the CA roots its requests trust")
end

--- A project's tests and examples stay with the project: the program
--- never runs them, so its executable carries neither, nor an import
--- edge or a catalog row about one. The test's `checked` returns a
--- literal failure, which is what puts a row about it in the catalog.
local function test_the_carried_database_leaves_tests_and_examples_out(tmp: string)
  write_project(tmp)
  assert(Fs.write(tmp .. "/greet_test.tl", table.concat({
    'local greet = require("greet")',
    "local function checked(name: string): (string?, string)",
    '  if greet.hello(name) ~= "hello, " .. name then',
    '    return nil, "greet_test: hello said something else"',
    "  end",
    '  return name, ""',
    "end",
    "local function test_hello()",
    '  assert(checked("x"))',
    "end",
    "",
  }, "\n")))
  assert(Fs.write(tmp .. "/greet_example.tl", table.concat({
    'local greet = require("greet")',
    "local record Example",
    "end",
    "--- Greets.",
    "function Example.hello()",
    '  assert(greet.hello("x") == "hello, x")',
    "end",
    "return Example",
    "",
  }, "\n")))
  assert(embed.tree(tmp, true))
  local projected = rows_of(support.build_dir(tmp) .. "/cosmic.db",
    "SELECT count(*) FROM modules WHERE path IN ('greet_test', 'greet_example')")
  assert(support.nth(projected, 1):text(1) == "2", "the project's own projection keeps both")
  local database = assert(embed.database(support.build_dir(tmp) .. "/cosmic.db", "cmd.hello.main"))
  local path = tmp .. "/carried.db"
  assert(Fs.write(path, database))

  local modules = rows_of(path,
    "SELECT path FROM modules WHERE path IN ('greet', 'greet_test', 'greet_example')")
  assert(#modules == 1 and modules[1]:text(1) == "greet",
    "the module is in and its test and example are not")
  local imports = rows_of(path,
    "SELECT count(*) FROM imports WHERE path IN ('greet_test', 'greet_example')")
  assert(support.nth(imports, 1):text(1) == "0", "no import edge from a test or example")
  local catalog = rows_of(path,
    "SELECT count(*) FROM catalog WHERE module IN ('greet_test', 'greet_example')")
  assert(support.nth(catalog, 1):text(1) == "0", "no catalog row about a test or example")
end

--- A test or example file is only a kind by its name: one the program
--- itself requires, directly or through another module, is carried,
--- or the executable would build and then fail to load it.
local function test_a_test_or_example_the_program_requires_is_carried(tmp: string)
  assert(Fs.mkdirs(tmp .. "/cmd/hello"))
  assert(Fs.write(tmp .. "/cmd/hello/main.tl", table.concat({
    'local shared = require("shared_example")',
    "return function(): integer",
    "  print(shared.hi())",
    "  return 0",
    "end",
    "",
  }, "\n")))
  assert(Fs.write(tmp .. "/shared_example.tl", table.concat({
    'local fixture = require("fixture_test")',
    "local record shared",
    "end",
    "function shared.hi(): string",
    "  return fixture.greeting",
    "end",
    "return shared",
    "",
  }, "\n")))
  assert(Fs.write(tmp .. "/fixture_test.tl", table.concat({
    "local record fixture",
    "  greeting: string",
    "end",
    'local f: fixture = { greeting = "hi" }',
    "return f",
    "",
  }, "\n")))
  assert(embed.tree(tmp, true))
  local database = assert(embed.database(support.build_dir(tmp) .. "/cosmic.db", "cmd.hello.main"))
  local path = tmp .. "/carried.db"
  assert(Fs.write(path, database))

  local modules = rows_of(path,
    "SELECT path FROM modules WHERE path IN ('shared_example', 'fixture_test') " ..
      "ORDER BY path")
  assert(#modules == 2, "a required example and test are carried, and " ..
      "only " .. tostring(#modules) .. " were")
  local imports = rows_of(path,
    "SELECT count(*) FROM imports WHERE path = 'shared_example' " ..
      "AND requires = 'fixture_test'")
  assert(support.nth(imports, 1):text(1) == "1", "the edge between them is carried")
end

--- A `pcall(require, "<name>")` is an edge as a `require` is: the module it probes is carried with its edge, so the
--- executable does not build and then probe a module it left out.
local function test_a_module_a_program_probes_with_pcall_is_carried(tmp: string)
  assert(Fs.mkdirs(tmp .. "/cmd/hello"))
  assert(Fs.write(tmp .. "/cmd/hello/main.tl", table.concat({
    "return function(): integer",
    '  local found, _ = pcall(require, "probed")',
    "  if found then return 0 end",
    "  return 1",
    "end",
    "",
  }, "\n")))
  assert(Fs.write(tmp .. "/probed.tl", "local record probed\nend\nreturn probed\n"))
  assert(embed.tree(tmp, true))
  local database = assert(embed.database(support.build_dir(tmp) .. "/cosmic.db", "cmd.hello.main"))
  local path = tmp .. "/carried.db"
  assert(Fs.write(path, database))
  local modules = rows_of(path, "SELECT path FROM modules WHERE path = 'probed'")
  assert(#modules == 1, "a module probed with pcall(require, ...) is carried")
  local imports = rows_of(path,
    "SELECT count(*) FROM imports WHERE path = 'cmd.hello.main' AND requires = 'probed'")
  assert(assert(imports[1]):text(1) == "1", "the edge to it is carried")
end

--- A program that requires a module by a name it computes is not built: the build cannot tell which module it carries.
local function test_a_program_requiring_a_computed_name_is_not_built(tmp: string)
  assert(Fs.mkdirs(tmp .. "/cmd/hello"))
  assert(Fs.write(tmp .. "/cmd/hello/main.tl", table.concat({
    'local name = "probed"',
    "return function(): integer",
    "  local found, _ = pcall(require, name)",
    "  if found then return 0 end",
    "  return 1",
    "end",
    "",
  }, "\n")))
  assert(Fs.write(tmp .. "/probed.tl", "local record probed\nend\nreturn probed\n"))
  local names, trouble = embed.tree(tmp, true)
  assert(names == nil, "built a program that requires a computed name")
  assert(trouble:find("main.tl:3:35: `pcall(require, name)` names its module by an expression", 1, true) ~= nil, trouble)
  assert(trouble:find("(computed_require): write the module's name as a string", 1, true) ~= nil, trouble)
end

local identity_source = [[
local Proc = require("cosmic.proc")
local Store = require("cosmic.store")

return function(): integer
  local executable, _ = Proc.executable()
  print(Store.meta("runtime_context"), Store.meta("host_image"),
    Store.meta("runtime"), executable)
  return 0
end
]]

local function run_program(path: string): Child.Result
  return (assert(Child.run({ path }, {
    stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(30) })))
end

--- `--host` writes this core itself with the program inside: the kernel
--- runs it directly, and it names the same runtime identity as the core
--- that built it, so a verdict holds across the two.
local function test_a_host_program_is_the_core_itself(tmp: string)
  assert(Fs.mkdirs(tmp .. "/cmd/who"))
  assert(Fs.write(tmp .. "/cmd/who/main.tl", identity_source))
  local names, trouble = embed.tree(tmp, true)
  assert(names ~= nil and names[1] == "who", trouble)
  local out = support.build_dir(tmp) .. "/bin/who"
  local bytes = assert(Fs.read(out))
  local core = assert(artifact.trusted_core())
  assert(String.starts_with(bytes, core.bytes), "the file starts with the running core")
  assert(bytes:sub(-48, -41) == "CosmicH1", "its trailer says host")
  local r = run_program(out)
  assert(r.ok, tostring(r.stderr))
  -- The path is the executable's own, resolved: on macOS a temporary
  -- directory under /var is reported under /private/var.
  local expected = table.concat({ "host-v1", assert(Store.meta("host_image")),
    assert(Store.meta("runtime")) }, "\t") .. "\t"
  local printed = assert(r.stdout)
  assert(String.starts_with(printed, expected), printed .. " ~= " .. expected)
  assert(String.ends_with(printed, "/bin/who\n"), printed)
end

--- A host program's arguments are its own, a first one that reads as the
--- core's `--artifact=<path>` included: without the private startup
--- contract, the core takes no artifact from its command line.
local function test_a_host_program_is_handed_a_joined_artifact_argument(tmp: string)
  assert(Fs.mkdirs(tmp .. "/cmd/echo"))
  assert(Fs.write(tmp .. "/cmd/echo/main.tl", [[
return function(argv: {string}): integer
  print(table.concat(argv, "|"))
  return 0
end
]]))
  local names, trouble = embed.tree(tmp, true)
  assert(names ~= nil and names[1] == "echo", trouble)
  local r = assert(Child.run({ support.build_dir(tmp) .. "/bin/echo", "--artifact=x", "y" }, {
    stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(30) }))
  assert(r.ok, "exit " .. tostring(r.code) .. ": " .. tostring(r.stderr))
  assert(r.stdout == "--artifact=x|y\n", tostring(r.stdout))
end

--- A host program runs without checking its own core's digest, but the
--- identity it would report is checked first, and one whose manifest names
--- another digest reports none.
local function test_a_host_program_names_no_identity_it_cannot_prove(tmp: string)
  assert(Fs.mkdirs(tmp .. "/cmd/who"))
  assert(Fs.write(tmp .. "/cmd/who/main.tl", identity_source))
  assert(embed.tree(tmp, true))
  local out = support.build_dir(tmp) .. "/bin/who"
  local bytes = assert(Fs.read(out))
  local core = assert(artifact.trusted_core())
  -- A raw entry names the digest twice, as stored and as the core's.
  local at = bytes:find(core.digest, #core.bytes + 1, true)
  assert(at ~= nil, "the manifest names the core's digest")
  local again = bytes:find(core.digest, at + 32, true)
  assert(again ~= nil, "and again as the core's own")
  local lied = bytes:sub(1, at - 1) .. string.rep("\0", 32) .. bytes:sub(at + 32, again - 1) ..
    string.rep("\0", 32) .. bytes:sub(again + 32)
  assert(Fs.write(out, lied, 0x1ed))
  local r = run_program(out)
  assert(r.ok, tostring(r.stderr))
  assert(assert(r.stdout):sub(1, 12) == "host-v1\tnil\t", tostring(r.stdout))
end

--- An error a program's main module does not catch ends it through the
--- core's own report: the message, then the guidance the carried error
--- catalog holds for the one it matches -- a line naming its function and
--- `cosmic docs`, since the docs themselves are not carried. Before it
--- fails, the program reads a time zone from the copy it carries.
local function test_an_uncaught_error_is_reported_with_its_guidance(tmp: string)
  assert(Fs.mkdirs(tmp .. "/cmd/boom"))
  assert(Fs.write(tmp .. "/cmd/boom/main.tl", [[
local Time = require("cosmic.time")

return function(): integer
  -- The zones the program carries: the only ones any program reads.
  local zone = assert(Time.zone("Asia/Kolkata"))
  print(Time.format_rfc3339(0, zone, { zone_name = true }))
  error("coverage collection is already active", 0)
end
]]))
  local names, trouble = embed.tree(tmp, true)
  assert(names ~= nil and names[1] == "boom", trouble)
  local r = run_program(support.build_dir(tmp) .. "/bin/boom")
  assert(r.code == 1, "exit " .. tostring(r.code))
  assert(r.stdout == "1970-01-01T05:30:00+05:30[Asia/Kolkata]\n",
    "a program reads the zones it carries: " .. tostring(r.stdout))
  local err = assert(r.stderr)
  assert(err:find("cosmic: coverage collection is already active", 1, true),
    "the message is reported: " .. err)
  assert(err:find("Coverage.start (cosmic/coverage.tl:", 1, true),
    "and the guidance that matches it: " .. err)
end

--- An error that is not a string is reported as a failure with nothing
--- beneath it: no line to name, and no message to find guidance for.
local function test_an_uncaught_error_that_is_no_string_says_it_failed(tmp: string)
  assert(Fs.mkdirs(tmp .. "/cmd/boom"))
  assert(Fs.write(tmp .. "/cmd/boom/main.tl", [[
return function(): integer
  local failure: mut {string: string} = {}
  error(failure)
end
]]))
  local names, trouble = embed.tree(tmp, true)
  assert(names ~= nil and names[1] == "boom", trouble)
  local r = run_program(support.build_dir(tmp) .. "/bin/boom")
  assert(r.code == 1, "exit " .. tostring(r.code))
  -- Its report is one line and nothing beneath it.
  local reported: mut {string} = {}
  for line in assert(r.stderr):gmatch("[^\n]+") do
    if line:sub(1, 8) == "cosmic: " then
      reported[#reported + 1] = line
    end
  end
  assert(#reported == 1 and reported[1] == "cosmic: failed", tostring(r.stderr))
end

--- An uncaught error names the Teal line it was raised on, read out of
--- the module's source, which the executable stores deflated.
local function test_an_uncaught_error_names_its_line_of_source(tmp: string)
  assert(Fs.mkdirs(tmp .. "/cmd/boom"))
  assert(Fs.write(tmp .. "/cmd/boom/main.tl", [[
local lib = require("lib")
return function(): integer
  lib.explode()
  return 0
end
]]))
  assert(Fs.write(tmp .. "/lib.tl", [[
local record lib
end
function lib.explode()
  error("kaboom from lib")
end
return lib
]]))
  local names, trouble = embed.tree(tmp, true)
  assert(names ~= nil and names[1] == "boom", trouble)
  local r = run_program(support.build_dir(tmp) .. "/bin/boom")
  assert(r.code == 1, "exit " .. tostring(r.code))
  local err = assert(r.stderr)
  assert(err:find('cosmic: at lib.tl:4: error("kaboom from lib")', 1, true),
    "the line is read back: " .. err)
end

--- Joining the standard library and project in their fixed batches
--- assigns the same rowids and writes the same bytes on every build.
local function test_the_embedded_database_is_reproducible(tmp: string)
  write_project(tmp)
  assert(embed.tree(tmp, true))
  local one = assert(embed.database(support.build_dir(tmp) .. "/cosmic.db", "cmd.hello.main"))
  local two = assert(embed.database(support.build_dir(tmp) .. "/cosmic.db", "cmd.hello.main"))
  assert(one == two, "repeating the embed changed its database")
end

--- A host program is no core: a policy that runs a program on a database
--- is refused one, saying so, before anything starts.
local function test_a_host_program_runs_no_program_on_a_database(tmp: string)
  assert(Fs.mkdirs(tmp .. "/cmd/refuse"))
  assert(Fs.write(tmp .. "/cmd/refuse/main.tl", [[
local Child = require("cosmic.child")
local Proc = require("cosmic.proc")

return function(argv: {string}): integer
  local executable = assert(Proc.executable())
  local started, why = Child.start({ executable, "x" },
    { policy = { database = { path = argv[1] or "", sha256 = nil } } })
  print(started == nil, why)
  return 0
end
]]))
  local names, trouble = embed.tree(tmp, true)
  assert(names ~= nil and names[1] == "refuse", trouble)
  assert(Fs.write(tmp .. "/some.db", "a file, which is all the policy's check asks"))
  local r = assert(Child.run({ support.build_dir(tmp) .. "/bin/refuse", tmp .. "/some.db" }, {
    stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(30) }))
  assert(r.ok, "exit " .. tostring(r.code) .. ": " .. tostring(r.stderr))
  local printed = assert(r.stdout)
  -- Linux refuses a host program; macOS's policy refuses a database it has no
  -- prepared core for. Either way no program starts on the database.
  assert(String.starts_with(printed, "true\t") and (printed:find("host program", 1, true) or
    printed:find("database needs a prepared core", 1, true)) ~= nil, printed)
end

local static_main = [[
local Assets = require("cosmic.web.assets")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")

return function(): integer
  for _, handle in ipairs(Store.databases()) do
    local rows, _ = Sqlite.text_rows(handle,
      "SELECT path, type, length(data), gzip IS NOT NULL, zstd IS NOT NULL FROM payload ORDER BY path")
    if rows ~= nil and #rows > 0 then
      for _, row in ipairs(rows) do print("payload", table.concat(row:texts(), "\t")) end
      break
    end
  end
  local source = Assets.default()
  local css = assert(source:get("css/app.css"))
  local logo = assert(source:get("logo.png"))
  print(source:dynamic(), #source:paths(), css.size, css.type, css.gzip ~= nil, css.zstd ~= nil, logo.size, logo.gzip, logo.zstd)
  return 0
end
]]

--- The files under `static/` go into the program's database whole, with
--- the type, hash, gzip and zstd they are served by, and a built program serves
--- them from there, not from a directory beside it: run from a directory
--- with a decoy `static/`, it answers the embedded bytes. One build
--- serves both checks, as it is the slow part.
local function test_a_program_serves_the_static_files_it_carries(tmp: string)
  assert(Fs.mkdirs(tmp .. "/cmd/site"))
  assert(Fs.write(tmp .. "/cmd/site/main.tl", static_main))
  assert(Fs.mkdirs(tmp .. "/static/css"))
  local css = ("a { color: red }\n"):rep(200)
  assert(Fs.write(tmp .. "/static/css/app.css", css))
  assert(Fs.write(tmp .. "/static/logo.png", "\137PNG\0\1"))
  local names, trouble = embed.tree(tmp, true)
  assert(names ~= nil and names[1] == "site", trouble)
  local elsewhere = tmp .. "/elsewhere"
  assert(Fs.mkdirs(elsewhere .. "/static/css"))
  assert(Fs.write(elsewhere .. "/static/css/app.css", "DECOY"))
  local r = assert(Child.run({ support.build_dir(tmp) .. "/bin/site" }, {
    cwd = elsewhere, stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(30) }))
  assert(r.ok, "exit " .. tostring(r.code) .. ": " .. tostring(r.stderr))
  local out = assert(r.stdout)
  assert(out:find("payload\tcss/app.css\ttext/css; charset=utf-8\t" .. tostring(#css) .. "\t1\t1\n" ..
      "payload\tlogo.png\timage/png\t6\t0\t0\n", 1, true), out)
  assert(out:find("false\t2\t" .. tostring(#css) .. "\ttext/css; charset=utf-8\ttrue\ttrue\t6\tnil\tnil\n", 1, true), out)
end

--- A project written in the new grammar (`mut`, a class, `T?`) builds, and the program it makes runs.
local function test_a_project_in_the_new_grammar_becomes_an_executable_with_the_new_checker(tmp: string)
  local root = tmp .. "/new"
  assert(Fs.copy_tree("testdata/projects/new_grammar", root))
  local names, trouble = embed.tree(root, true)
  assert(names ~= nil and #names == 1 and names[1] == "tally", trouble)
  local r = assert(Child.run({ support.build_dir(root) .. "/bin/tally", "b", "a", "c" }, {
    stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(30) }))
  assert(r.code == 3 and r.stdout == "b,a,c\n", tostring(r.code) .. ": " .. tostring(r.stdout) .. tostring(r.stderr))
end

--- A project written in forms only the fork reads is refused in the new checker's words, and the words speak of no pin: a
--- project has none to raise. The fork builds it.
local function test_a_project_the_new_checker_refuses_is_not_built(tmp: string)
  local root = tmp .. "/fork_only"
  assert(Fs.copy_tree("testdata/projects/fork_only", root))
  assert(Fs.mkdirs(root .. "/cmd/x"))
  assert(Fs.write(root .. "/cmd/x/main.tl", "return function(): integer return 0 end\n"))
  local names, trouble = embed.tree(root, true)
  assert(names == nil, "built a project the new checker refuses")
  assert(trouble:find("lookup.tl:10:12: nil is given as return value 1, where `Entry` is wanted (nil_not_allowed): give a value, " ..
      "or declare what takes it `Entry?`", 1, true) ~= nil, tostring(trouble))
  assert(trouble:find("pinned", 1, true) == nil and trouble:find("ceilings.txt", 1, true) == nil, trouble)
end

--- A program that says which roots its requests trust by default
--- ([`Http.default_roots`], or why it cannot tell), then whether a server
--- presenting a root the binary carries but the minimal roots leave out is
--- trusted, as far as a canned first flight takes a handshake.
local roots_source <const> = [[
local Http = require("cosmic.http")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")

local function message(kind: integer, body: string): string
  return string.char(kind) .. string.pack(">I3", #body) .. body
end

return function(): integer
  local databases = Store.databases()
  local found = assert(Sqlite.rows(assert(databases[#databases]),
    "SELECT der FROM ca_roots WHERE label = 'Telia RSA TLS Root CA v3'"))
  local der = assert(found[1]):blob(1)
  local hello = message(2, "\3\3" .. string.rep("B", 32) .. "\0" .. "\192\47" .. "\0")
  local certificate = message(11, string.pack(">I3", #der + 3) .. string.pack(">I3", #der) .. der)
  local records = hello .. certificate
  local flight = "\22\3\3" .. string.pack(">I2", #records) .. records
  local roots, why = Http.default_roots()
  print(roots or why)
  local _, refused = Http.open("https://cosmic.test/", { script = { flight } })
  print((refused:gsub("\n", " ")))
  return 0
end
]]

--- What the program `roots_source` printed: its first line, and then "trusted" where it was refused for the name it
--- presents and not for who signed it, else "refused".
local function trust_of(printed: string): string
  local first, second = printed:match("^([^\n]*)\n([^\n]*)\n$")
  assert(first ~= nil and second ~= nil, printed)
  if second:find("Common Name", 1, true) ~= nil and second:find("not correctly signed", 1, true) == nil then
    return first .. "\ntrusted\n"
  end
  return first .. "\nrefused\n"
end

--- What the program at `path` printed, run with `env`.
local function run_with(path: string, env: {string:string}): string
  local r = assert(Child.run({ path }, { env = env,
    stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(30) }))
  assert(r.ok, tostring(r.stderr))
  return trust_of(assert(r.stdout))
end

--- An executable carries every root and trusts the minimal ones by
--- default; COSMIC_CA_ROOTS=mozilla trusts them all, and `cosmic build
--- --roots mozilla` makes that its default, which COSMIC_CA_ROOTS still
--- overrides. A value that names neither fails its requests, saying so.
local function test_an_executable_trusts_the_minimal_roots_unless_told(tmp: string)
  assert(Fs.mkdirs(tmp .. "/cmd/roots"))
  assert(Fs.write(tmp .. "/cmd/roots/main.tl", roots_source))
  assert(embed.tree(tmp, true))
  local out = support.build_dir(tmp) .. "/bin/roots"
  assert(run_with(out, {}) == "minimal\nrefused\n")
  assert(run_with(out, { COSMIC_CA_ROOTS = "mozilla" }) == "mozilla\ntrusted\n")
  local bad = run_with(out, { COSMIC_CA_ROOTS = "everything" })
  assert(bad:find('COSMIC_CA_ROOTS names "everything", not minimal or mozilla', 1, true) ~= nil, bad)
  assert(bad:find("refused", 1, true) ~= nil, bad)

  assert(embed.tree(tmp, true, nil, "mozilla"))
  assert(run_with(out, {}) == "mozilla\ntrusted\n")
  assert(run_with(out, { COSMIC_CA_ROOTS = "minimal" }) == "minimal\nrefused\n")
end

--- A tree the checker refuses builds no program and exits 4, the status of a tree that did not compile, where a failure to
--- write one exits 1.
local function test_build_of_a_tree_that_does_not_compile_exits_4(tmp: string)
  write_project(tmp)
  local env = { COSMIC_BUILD_CACHE = "0", COSMIC_BUILD_HOME = assert(Env.get("COSMIC_BUILD_HOME")) }
  assert(Fs.write(tmp .. "/bad.tl", 'local n: integer = "x"\nreturn n\n'))
  local built = invoke.run({ "build", "--host" }, { cwd = tmp, env = env })
  assert(built.code == 4 and built.stdout == "" and built.stderr:find("bad.tl", 1, true) ~= nil,
    tostring(built.code) .. built.stdout .. built.stderr)
  assert(Fs.remove(tmp .. "/bad.tl"))
  assert(Fs.write(tmp .. "/ping.tl", 'local pong = require("pong")\nreturn pong\n'))
  assert(Fs.write(tmp .. "/pong.tl", 'local ping = require("ping")\nreturn ping\n'))
  local cycle = invoke.run({ "build", "--host" }, { cwd = tmp, env = env })
  assert(cycle.code == 4 and cycle.stdout == "", tostring(cycle.code) .. cycle.stdout .. cycle.stderr)
end

--- `cosmic build --roots` takes minimal or mozilla, and refuses anything
--- else before it builds.
local function test_build_refuses_roots_it_does_not_know(tmp: string)
  write_project(tmp)
  local built = invoke.run({ "build", "--host", "--roots", "everything" }, { cwd = tmp,
    env = { COSMIC_BUILD_CACHE = "0" } })
  assert(built.code == 2 and built.stderr:find("--roots takes minimal or mozilla", 1, true) ~= nil,
    built.stdout .. built.stderr)
end

--- The running core's bytes for a host program, from a portable start whose
--- artifact holds only its compressed frame: the cached raw core the start
--- runs from, checked against the manifest's digest.
local function test_trusted_core_is_the_cached_raw_core_of_a_compressed_start()
  local relaunch = Proc.relaunch()
  if relaunch == nil then
    Test.skip("a native start has no cached core to read")
    return
  end
  local core = assert(artifact.trusted_core())
  assert(Hash.sha256(core.bytes) == core.digest, "the bytes are the ones the digest names")
  assert(core.bytes == assert(Fs.read(assert(relaunch.argv[1]))), "and the core this start runs")
end
