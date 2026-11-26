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
local Doc = require("cosmic.doc")
local Errors = require("cosmic.errors")
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
local source_run = require("cosmic.internal.source_run")
local String = require("cosmic.string")
local Clock = require("cosmic.clock")
local support = require("build.test_support_fixture")
local verbs_fixture = require("build.verbs_fixture")

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
  local rows = assert(db:rows(sql))
  local _, _ = db:close()
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
  assert(support.nth(images, 1):integer(1) == 0, "portable databases have no images table")
  local guidance = rows_of(path,
    "SELECT count(*) FROM catalog_fts WHERE catalog_fts MATCH 'coverage'")
  assert(support.nth(guidance, 1):integer(1) > 0, "the error catalog is in, and indexed")
  local text = rows_of(path,
    "SELECT text IS NULL, length(file) > 0, line > 0 FROM catalog " ..
      "WHERE symbol = 'Coverage.start'")
  assert(#text == 1 and support.nth(text, 1):integer(1) == 1 and
      support.nth(text, 1):integer(2) == 1 and support.nth(text, 1):integer(3) == 1,
    "a row with no text of its own carries none, nor the doc comment: " ..
      "it carries where it is")
  local about_build = rows_of(path,
    "SELECT count(*) FROM catalog WHERE module LIKE 'build.%'")
  assert(support.nth(about_build, 1):integer(1) == 0, "guidance about the build is not")
  local databases = Store.databases()
  local own = assert(databases[#databases], "this program has a database")
  local carried = assert(own:rows("SELECT count(*) FROM zoneinfo"))
  local zones = rows_of(path, "SELECT count(*), sum(name = 'America/New_York') FROM zoneinfo")
  assert(support.nth(zones, 1):integer(1) == support.nth(carried, 1):integer(1) and support.nth(zones, 1):integer(1) > 500 and support.nth(zones, 1):integer(2) == 1,
    "every zone the binary carries is in")
  local assets = assert(own:rows(
    "SELECT group_concat(name || ' ' || version || ' ' || sha256, ',' ORDER BY name) FROM web_assets"))
  local web = rows_of(path,
    "SELECT group_concat(name || ' ' || version || ' ' || sha256, ',' ORDER BY name) FROM web_assets")
  assert(support.nth(web, 1):text(1) ~= nil and support.nth(web, 1):text(1) == support.nth(assets, 1):text(1) and support.nth(web, 1):text(1):find("htmx.min.js", 1, true) ~= nil, -- checked: compare_disjoint
    "every web asset the binary carries is in")
  local materials = rows_of(path,
    "SELECT (SELECT count(*) FROM components WHERE name = 'lua'), " ..
      "(SELECT count(*) FROM notices WHERE component = 'lua' AND text LIKE '%Lua.org%')")
  assert(support.nth(materials, 1):integer(1) == 1 and support.nth(materials, 1):integer(2) == 1,
    "the program carries the bill of materials its cores ship under")
  local trusted = rows_of(path, "SELECT count(*) FROM ca_roots")
  assert(support.nth(trusted, 1):integer(1) > 100, "the program carries the CA roots its requests trust")
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
  assert(support.nth(projected, 1):integer(1) == 2, "the project's own projection keeps both")
  local database = assert(embed.database(support.build_dir(tmp) .. "/cosmic.db", "cmd.hello.main"))
  local path = tmp .. "/carried.db"
  assert(Fs.write(path, database))

  local modules = rows_of(path,
    "SELECT path FROM modules WHERE path IN ('greet', 'greet_test', 'greet_example')")
  assert(#modules == 1 and modules[1]:text(1) == "greet",
    "the module is in and its test and example are not")
  local imports = rows_of(path,
    "SELECT count(*) FROM imports WHERE path IN ('greet_test', 'greet_example')")
  assert(support.nth(imports, 1):integer(1) == 0, "no import edge from a test or example")
  local catalog = rows_of(path,
    "SELECT count(*) FROM catalog WHERE module IN ('greet_test', 'greet_example')")
  assert(support.nth(catalog, 1):integer(1) == 0, "no catalog row about a test or example")
end

--- A program carries what its users read of the project: the docs, uses and
--- examples of the modules any module may require, and its guides. What
--- position keeps to the project stays there: a sibling of a closed
--- directory, a module under `internal/`, the program itself, a test, and
--- test support, a guide under `doc/guides/internal/`, and a use made from any of them: a private module's rows
--- would tell the program's users of code they cannot call.
local function test_the_carried_database_holds_the_documentation_of_the_public_modules(tmp: string)
  write_project(tmp)
  assert(Fs.write(tmp .. "/greet.tl", table.concat({
    "--- Greetings.",
    "local record greet",
    "end",
    "",
    "--- Says hello to `name`, salutation included.",
    "function greet.hello(name: string): string",
    '  return "hello, " .. name',
    "end",
    "",
    "return greet",
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
  assert(Fs.mkdirs(tmp .. "/store"))
  assert(Fs.write(tmp .. "/store/init.tl", table.concat({
    "--- The store, a closed directory's entry.",
    'local greet = require("greet")',
    'local rows = require("store.rows")',
    "local record store",
    "end",
    "",
    "--- Greets the first row, with [`greet.hello`].",
    "function store.first(): string",
    "  return greet.hello(rows.first())",
    "end",
    "",
    "return store",
    "",
  }, "\n")))
  assert(Fs.write(tmp .. "/store/rows.tl", table.concat({
    "--- The rows, which only the store reads.",
    'local greet = require("greet")',
    "local record rows",
    "end",
    "",
    "--- The first row, sequestered.",
    "function rows.first(): string",
    '  return greet.hello("row")',
    "end",
    "",
    "return rows",
    "",
  }, "\n")))
  assert(Fs.write(tmp .. "/store/open.tl", table.concat({
    "--- Opening a store, for any module.",
    "--- @public",
    "local record open",
    "end",
    "",
    "--- Whether the store is open.",
    "function open.is(): boolean",
    "  return true",
    "end",
    "",
    "return open",
    "",
  }, "\n")))
  assert(Fs.mkdirs(tmp .. "/app/internal"))
  assert(Fs.write(tmp .. "/app/internal/db.tl", table.concat({
    "--- The database, internal to app/.",
    "local record db",
    "end",
    "",
    "--- Its name.",
    "function db.name(): string",
    '  return "db"',
    "end",
    "",
    "return db",
    "",
  }, "\n")))
  assert(Fs.write(tmp .. "/app/run.tl", table.concat({
    "--- Running the app.",
    'local db = require("app.internal.db")',
    "local record run",
    "end",
    "",
    "--- Names what it runs on.",
    "function run.on(): string",
    "  return db.name()",
    "end",
    "",
    "return run",
    "",
  }, "\n")))
  assert(Fs.mkdirs(tmp .. "/internal"))
  assert(Fs.write(tmp .. "/internal/keys.tl", table.concat({
    "--- The keys, internal to the project.",
    "local record keys",
    "end",
    "return keys",
    "",
  }, "\n")))
  assert(Fs.mkdirs(tmp .. "/test"))
  assert(Fs.write(tmp .. "/test/support.tl", table.concat({
    "--- Test support.",
    "local record support",
    "end",
    "return support",
    "",
  }, "\n")))
  assert(Fs.mkdirs(tmp .. "/doc/guides"))
  assert(Fs.write(tmp .. "/doc/guides/greeting.md", "# greeting\n\nHow to greet a visitor.\n"))
  assert(Fs.mkdirs(tmp .. "/doc/guides/internal"))
  assert(Fs.write(tmp .. "/doc/guides/internal/notes.md", "# notes\n\nFor those working on the project.\n"))
  assert(Fs.write(tmp .. "/cmd/hello/main.tl", table.concat({
    "--- The program, which no module requires.",
    'local Fs = require("cosmic.fs")',
    'local greet = require("greet")',
    'local open = require("store.open")',
    'local run = require("app.run")',
    'local store = require("store")',
    "",
    "return function(argv: {string}): integer",
    '  local _, _ = Fs.put(Fs.stdout, greet.hello(argv[1] or store.first()) .. run.on() .. tostring(open.is()) .. "\\n")',
    "  return 0",
    "end",
    "",
  }, "\n")))
  assert(embed.tree(tmp, true))
  local database = assert(embed.database(support.build_dir(tmp) .. "/cosmic.db", "cmd.hello.main"))
  local path = tmp .. "/carried.db"
  assert(Fs.write(path, database))

  local function listed(sql: string): string
    local out: mut {string} = {}
    for _, row in ipairs(rows_of(path, sql)) do out[#out + 1] = (row:as_text(1) or "") end
    return table.concat(out, " ")
  end
  local internal = rows_of(support.build_dir(tmp) .. "/cosmic.db",
    "SELECT kind FROM modules WHERE path = 'doc.guides.internal.notes'")
  assert(#internal == 1 and internal[1]:text(1) == "test", "the project tests its internal guide")
  local recorded = listed("SELECT path FROM public_modules ORDER BY path")
  assert(recorded == "app.run greet store store.open", "the modules any module may require, recorded as public: " .. recorded)
  local projected = rows_of(support.build_dir(tmp) .. "/cosmic.db", "SELECT group_concat(path, ' ' ORDER BY path) FROM public_modules")
  assert(support.nth(projected, 1):text(1) == recorded, "as the project's projection records them")
  local documented = listed("SELECT DISTINCT module FROM docs ORDER BY module")
  assert(documented == "app.run doc.guides.greeting greet store store.open",
    "the public modules and the guide, and no other: " .. documented)
  local found = listed("SELECT d.source_symbol FROM docs_fts JOIN docs d ON d.id = docs_fts.rowid " ..
      "WHERE docs_fts MATCH 'salutation'")
  assert(found == "greet.hello", "the docs are indexed, a word finding its row: " .. found)
  local private = listed("SELECT count(*) FROM docs_fts WHERE docs_fts MATCH 'sequestered'")
  assert(private == "0", "a private module's words are not in the index")
  local callers = listed("SELECT DISTINCT from_module FROM uses WHERE module = 'greet' ORDER BY from_module")
  assert(callers == "store", "a use is carried only from a public module: " .. callers)
  local used = listed("SELECT count(*) FROM uses WHERE module NOT IN ('app.run', 'greet', 'store', 'store.open')")
  assert(used == "0", "no use of a module the project keeps, or of the library")
  local linked = listed("SELECT from_module || ' ' || module || ' ' || symbol FROM links")
  assert(linked == "store greet hello", "a link between public modules is carried: " .. linked)
  local bound = listed("SELECT path || ' ' || name || ' ' || requires FROM bound WHERE path = 'store' ORDER BY name")
  assert(bound == "store greet greet store rows store.rows", "what a public module binds is carried: " .. bound)
  local examples = listed("SELECT module || ' ' || name FROM examples")
  assert(examples == "greet hello", examples)
  local indexed = listed("SELECT count(*) FROM examples_fts WHERE examples_fts MATCH 'Greets'")
  assert(indexed == "1", "the examples are indexed")
end

--- Each program carries what its own main requires and the documentation of
--- that alone: `spam` leaves out `eggs`'s main and the module only `eggs`
--- requires, and their docs, though `eggs.tl` is public. A module under
--- `cmd/spam/` is `spam`'s own to carry and document, as a public one is,
--- whether main requires it or not (a `pages` module is named by a string
--- alone), and none of `eggs`'s; the main itself is documented by neither,
--- nor a module under `cmd/spam/internal/`, and an example under `cmd/spam/`
--- nothing requires is not carried. A public module no main requires is in
--- neither program.
local function test_each_program_carries_only_what_its_main_requires(tmp: string)
  assert(Fs.mkdirs(tmp .. "/cmd/spam/internal"))
  assert(Fs.mkdirs(tmp .. "/cmd/eggs"))
  assert(Fs.write(tmp .. "/loose.tl", "--- No main requires it.\nlocal record loose\nend\nreturn loose\n"))
  assert(Fs.write(tmp .. "/eggs_example.tl", table.concat({
    'local _eggs = require("eggs")',
    "local record Example",
    "end",
    "--- Cracks one.",
    "function Example.crack()",
    "end",
    "return Example",
    "",
  }, "\n")))
  assert(Fs.write(tmp .. "/cmd/spam/pages.tl", table.concat({
    "--- Spam's pages, which main never requires.",
    'local _paged = require("paged")',
    "local record pages",
    "end",
    "return pages",
    "",
  }, "\n")))
  assert(Fs.write(tmp .. "/paged.tl", "--- Only spam's pages require it.\nlocal record paged\nend\nreturn paged\n"))
  assert(Fs.write(tmp .. "/cmd/spam/pages_example.tl", "local record Example\nend\nreturn Example\n"))
  assert(Fs.write(tmp .. "/cmd/spam/internal/secret.tl", "--- Spam's secret.\nlocal record secret\nend\nreturn secret\n"))
  assert(Fs.write(tmp .. "/shared.tl", "--- Shared by both.\nlocal record shared\nend\nreturn shared\n"))
  assert(Fs.write(tmp .. "/eggs.tl", "--- Only eggs requires it.\nlocal record eggs\nend\nreturn eggs\n"))
  assert(Fs.write(tmp .. "/cmd/spam/commands.tl", table.concat({
    "--- Spam's commands.",
    "local record commands",
    "end",
    "",
    "--- Fries the spam.",
    "function commands.fry(): integer",
    "  return 0",
    "end",
    "",
    "return commands",
    "",
  }, "\n")))
  assert(Fs.write(tmp .. "/cmd/eggs/commands.tl", "--- Eggs's commands.\nlocal record commands\nend\nreturn commands\n"))
  assert(Fs.write(tmp .. "/cmd/spam/main.tl", table.concat({
    "--- Spam.",
    'local _shared = require("shared")',
    'local commands = require("cmd.spam.commands")',
    "return function(): integer return commands.fry() end",
    "",
  }, "\n")))
  assert(Fs.write(tmp .. "/cmd/eggs/main.tl", table.concat({
    "--- Eggs.",
    'local _shared = require("shared")',
    'local _eggs = require("eggs")',
    'local _commands = require("cmd.eggs.commands")',
    "return function(): integer return 0 end",
    "",
  }, "\n")))
  assert(embed.tree(tmp, true))
  local database = assert(embed.database(support.build_dir(tmp) .. "/cosmic.db", "cmd.spam.main"))
  local path = tmp .. "/carried.db"
  assert(Fs.write(path, database))
  local function listed(sql: string): string
    local out: mut {string} = {}
    for _, row in ipairs(rows_of(path, sql)) do out[#out + 1] = (row:as_text(1) or "") end
    return table.concat(out, " ")
  end
  local modules = listed("SELECT path FROM modules WHERE path NOT LIKE 'cosmic.%' ORDER BY path")
  assert(modules == "cmd.spam.commands cmd.spam.internal.secret cmd.spam.main cmd.spam.pages paged shared",
    "spam's main, what it requires and its own modules: " .. modules)
  local imports = listed("SELECT DISTINCT path FROM imports WHERE path NOT LIKE 'cosmic.%' ORDER BY path")
  assert(imports == "cmd.spam.main cmd.spam.pages", "the edges of what it carries alone: " .. imports)
  local recorded = listed("SELECT path FROM public_modules ORDER BY path")
  assert(recorded == "cmd.spam.commands cmd.spam.pages paged shared",
    "its own modules and the public one it carries: " .. recorded)
  local documented = listed("SELECT DISTINCT module FROM docs ORDER BY module")
  assert(documented == "cmd.spam.commands cmd.spam.pages paged shared", "the docs of those alone: " .. documented)
  local examples = listed("SELECT count(*) FROM examples")
  assert(examples == "0", "no example of a module it does not carry: " .. examples)
end

--- A module a carried one names by a string literal as its `pages`, which no `require` reaches, is carried with
--- what it requires and documented, wherever it sits (here in a closed directory, whose module is no public one),
--- so the commands it documents keep their pages: named in a table handed to [`Flags.dispatch`] by name, as in the
--- call itself. Another program's module, and a name the project holds no module of, is no module to carry.
local function test_a_pages_module_no_module_requires_is_carried(tmp: string)
  assert(Fs.mkdirs(tmp .. "/cmd/spam"))
  assert(Fs.mkdirs(tmp .. "/cmd/eggs"))
  assert(Fs.mkdirs(tmp .. "/store"))
  assert(Fs.write(tmp .. "/cmd/spam/main.tl", table.concat({
    'local Flags = require("cosmic.flags")',
    "return function(argv: {string}): integer",
    "  local commands: {string:Flags.Command} = { fry = { about = \"fry it\", run = function(_: Flags.Parsed): integer return 0 end } }",
    '  local documented: Flags.Documented = { pages = "store.pages" }',
    "  local ran, _ = Flags.dispatch(argv, 1, commands, \"spam\", documented)",
    '  local _, _ = Flags.dispatch(argv, 1, commands, "spam", { pages = "nowhere" })',
    '  local _, _ = Flags.dispatch(argv, 1, commands, "spam", { pages = "cmd.eggs.theirs" })',
    "  if ran == nil then return 2 end",
    "  if ran.help ~= \"\" then print(ran.help) end",
    "  return ran.code",
    "end",
    "",
  }, "\n")))
  assert(Fs.write(tmp .. "/cmd/eggs/main.tl", "return function(): integer return 0 end\n"))
  assert(Fs.write(tmp .. "/cmd/eggs/theirs.tl", "--- Eggs's own.\nlocal record theirs\nend\nreturn theirs\n"))
  assert(Fs.write(tmp .. "/store/init.tl", "--- The store.\nlocal record store\nend\nreturn store\n"))
  assert(Fs.write(tmp .. "/store/pages.tl", table.concat({
    "--- Spam's pages, which no module requires.",
    'local helper = require("store.helper")',
    "local record pages",
    "  --- Fries the spam, " .. "golden.",
    "  fry: integer",
    "end",
    "local p: pages = { fry = helper.n }",
    "return p",
    "",
  }, "\n")))
  assert(Fs.write(tmp .. "/store/helper.tl", "local record helper\n  n: integer\nend\nlocal h: helper = { n = 1 }\nreturn h\n"))
  assert(embed.tree(tmp, true))
  local database = assert(embed.database(support.build_dir(tmp) .. "/cosmic.db", "cmd.spam.main"))
  local path = tmp .. "/carried.db"
  assert(Fs.write(path, database))
  local modules: mut {string} = {}
  for _, row in ipairs(rows_of(path, "SELECT path FROM modules WHERE path NOT LIKE 'cosmic.%' ORDER BY path")) do
    modules[#modules + 1] = row:text(1)
  end
  assert(table.concat(modules, " ") == "cmd.spam.main store.helper store.pages", table.concat(modules, " "))
  local documented = rows_of(path, "SELECT count(*) FROM docs WHERE module = 'store.pages' AND symbol = 'pages.fry'")
  assert(support.nth(documented, 1):integer(1) == 1, "the pages module's field is documented")
  -- Run from its source, it says so too.
  local help = verbs_fixture.run(tmp, { "cmd/spam/main.tl", "help", "fry" })
  assert(help.code == 0 and help.stdout:find("Fries the spam, golden.", 1, true) ~= nil, help.stdout .. help.stderr)
end

--- A pages module named by a local bound to its name, constant or not, is carried and documented as one written
--- in the table is: the build reads the string the file binds. One a call makes names none.
local function test_a_pages_module_named_by_a_local_is_carried(tmp: string)
  assert(Fs.mkdirs(tmp .. "/cmd/spam"))
  assert(Fs.write(tmp .. "/cmd/spam/main.tl", table.concat({
    'local Flags = require("cosmic.flags")',
    'local PAGES <const> = "by_constant"',
    "return function(argv: {string}): integer",
    "  local commands: {string:Flags.Command} = { fry = { about = \"fry it\", run = function(_: Flags.Parsed): integer return 0 end } }",
    "  local documented: Flags.Documented = { pages = PAGES }",
    "  local ran, _ = Flags.dispatch(argv, 1, commands, \"spam\", documented)",
    '  local named = "by_local"',
    "  local _, _ = Flags.dispatch(argv, 1, commands, \"spam\", { pages = named })",
    '  local made = tostring("by_call")',
    "  local _, _ = Flags.dispatch(argv, 1, commands, \"spam\", { pages = made })",
    "  if ran == nil then return 2 end",
    "  return ran.code",
    "end",
    "",
  }, "\n")))
  for _, name in ipairs({ "by_constant", "by_local", "by_call" }) do
    assert(Fs.write(tmp .. "/" .. name .. ".tl", "--- Named " .. name .. ".\nlocal record m\n  --- Fries.\n  fry: integer\nend\n" ..
        "local v: m = { fry = 1 }\nreturn v\n"))
  end
  assert(embed.tree(tmp, true))
  local database = assert(embed.database(support.build_dir(tmp) .. "/cosmic.db", "cmd.spam.main"))
  local path = tmp .. "/carried.db"
  assert(Fs.write(path, database))
  local modules: mut {string} = {}
  for _, row in ipairs(rows_of(path, "SELECT path FROM modules WHERE path NOT LIKE 'cosmic.%' ORDER BY path")) do
    modules[#modules + 1] = row:text(1)
  end
  assert(table.concat(modules, " ") == "by_constant by_local cmd.spam.main", table.concat(modules, " "))
  local documented = rows_of(path, "SELECT count(DISTINCT module) FROM docs WHERE module IN ('by_constant', 'by_local')")
  assert(support.nth(documented, 1):integer(1) == 2, "both are documented")
end

--- A pages module named by a field of another module the program requires (`{ pages = Names.docs_module }`) is
--- carried and documented: the build reads the string that module binds the field to.
local function test_a_pages_module_named_by_another_modules_field_is_carried(tmp: string)
  assert(Fs.mkdirs(tmp .. "/cmd/spam"))
  assert(Fs.write(tmp .. "/cmd/spam/main.tl", table.concat({
    'local Flags = require("cosmic.flags")',
    'local Names = require("names")',
    "return function(argv: {string}): integer",
    "  local commands: {string:Flags.Command} = { fry = { about = \"fry it\", run = function(_: Flags.Parsed): integer return 0 end } }",
    "  local ran, _ = Flags.dispatch(argv, 1, commands, \"spam\", { pages = Names.docs_module })",
    "  if ran == nil then return 2 end",
    "  return ran.code",
    "end",
    "",
  }, "\n")))
  assert(Fs.write(tmp .. "/names.tl", table.concat({
    "--- The names the program reads.",
    "local record names",
    "  docs_module: string",
    "end",
    'local n: names = { docs_module = "by_module" }',
    "return n",
    "",
  }, "\n")))
  assert(Fs.write(tmp .. "/by_module.tl", "--- Named by another module.\nlocal record m\n  --- Fries.\n  fry: integer\nend\n" ..
      "local v: m = { fry = 1 }\nreturn v\n"))
  assert(embed.tree(tmp, true))
  local database = assert(embed.database(support.build_dir(tmp) .. "/cosmic.db", "cmd.spam.main"))
  local path = tmp .. "/carried.db"
  assert(Fs.write(path, database))
  local modules: mut {string} = {}
  for _, row in ipairs(rows_of(path, "SELECT path FROM modules WHERE path NOT LIKE 'cosmic.%' ORDER BY path")) do
    modules[#modules + 1] = row:text(1)
  end
  assert(table.concat(modules, " ") == "by_module cmd.spam.main names", table.concat(modules, " "))
  local documented = rows_of(path, "SELECT count(*) FROM docs WHERE module = 'by_module' AND symbol = 'm.fry'")
  assert(support.nth(documented, 1):integer(1) == 1, "it is documented")
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
  assert(support.nth(imports, 1):integer(1) == 1, "the edge between them is carried")
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
  assert(assert(imports[1]):integer(1) == 1, "the edge to it is carried")
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

--- A [`cosmic.failure`] that nothing catches is reported by the text its
--- `__tostring` returns, `path: message`, as a person reads it.
local function test_an_uncaught_failure_is_reported_by_its_text(tmp: string)
  assert(Fs.mkdirs(tmp .. "/cmd/boom"))
  assert(Fs.write(tmp .. "/cmd/boom/main.tl", [[
local Failure = require("cosmic.failure")
return function(): integer
  error(Failure.new("no settings here", "/etc/boom.conf"))
end
]]))
  local names, trouble = embed.tree(tmp, true)
  assert(names ~= nil and names[1] == "boom", trouble)
  local r = run_program(support.build_dir(tmp) .. "/bin/boom")
  assert(r.code == 1, "exit " .. tostring(r.code))
  local err = assert(r.stderr)
  assert(err:find("cosmic: /etc/boom.conf: no settings here\n", 1, true) == 1, err)
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
    { timeout_ns = Child.FOREVER, policy = { database = { path = argv[1] or "", sha256 = nil } } })
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
local StaticFiles = require("cosmic.web.static")
local Store = require("cosmic.store")
local Web = require("cosmic.web")

return function(): integer
  for _, handle in ipairs(Store.databases()) do
    local rows, _ = handle:rows(
      "SELECT path, type, length(data), gzip IS NOT NULL, zstd IS NOT NULL FROM payload ORDER BY path")
    if rows ~= nil and #rows > 0 then
      for _, row in ipairs(rows) do print("payload", table.concat(row:as_texts(), "\t")) end
      break
    end
  end
  local source = Assets.default()
  local css = assert(source:get("css/app.css"))
  local logo = assert(source:get("logo.png"))
  print(source:dynamic(), #source:paths(), css.size, css.type, css.gzip ~= nil, css.zstd ~= nil, logo.size, logo.gzip, logo.zstd)
  local client = Web.test_client(Web.app{ routes = { StaticFiles.mount("/static", { source = source }) } })
  local served = client:get("/static/logo.png", { headers = { ["Accept-Encoding"] = "zstd, gzip" } })
  print("served", served.status, served.headers["content-encoding"], #served.body)
  return 0
end
]]

--- The files under `static/` go into the program's database whole, with
--- the type, hash, gzip and zstd they are served by, and a built program serves
--- them from there, not from a directory beside it: run from a directory
--- with a decoy `static/`, it serves the embedded bytes. A file not worth
--- compressing has no variants on a warm build (an edited module, the
--- compressed cache kept) as on a cold one, so the static handler serves
--- its bytes and no empty zstd body. A cold and a warm build run the same
--- checks, as a build is the slow part.
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
  local function check(build: string)
    local r = assert(Child.run({ support.build_dir(tmp) .. "/bin/site" }, {
      cwd = elsewhere, stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(30) }))
    assert(r.ok, build .. ": exit " .. tostring(r.code) .. ": " .. tostring(r.stderr))
    local out = assert(r.stdout)
    assert(out:find("payload\tcss/app.css\ttext/css; charset=utf-8\t" .. tostring(#css) .. "\t1\t1\n" ..
        "payload\tlogo.png\timage/png\t6\t0\t0\n", 1, true), build .. ": " .. out)
    assert(out:find("false\t2\t" .. tostring(#css) .. "\ttext/css; charset=utf-8\ttrue\ttrue\t6\tnil\tnil\n", 1, true),
      build .. ": " .. out)
    assert(out:find("served\t200\tnil\t6\n", 1, true), build .. ": " .. out)
  end
  check("cold")
  assert(Fs.write(tmp .. "/cmd/site/main.tl", static_main .. "-- edited\n"))
  local again, again_trouble = embed.tree(tmp, true)
  assert(again ~= nil and again[1] == "site", again_trouble)
  check("warm")
end

--- A program run from its source serves its own `cmd/<name>/static/` laid
--- over `static/` from disk, as its built executable carries them: the run
--- records which program it is.
local function test_a_program_run_from_its_source_lays_its_own_static_files_over_the_shared_ones(tmp: string)
  assert(Fs.mkdirs(tmp .. "/cmd/spam/static"))
  assert(Fs.mkdirs(tmp .. "/static"))
  assert(Fs.write(tmp .. "/static/app.css", "shared"))
  assert(Fs.write(tmp .. "/static/logo.png", "logo"))
  assert(Fs.write(tmp .. "/cmd/spam/static/app.css", "spam's"))
  assert(Fs.write(tmp .. "/cmd/spam/main.tl", table.concat({
    'local Assets = require("cosmic.web.assets")',
    "return function(): integer",
    "  local source = Assets.default({ log = function(_: string) end })",
    '  print(assert(source:get("app.css")).data, assert(source:get("logo.png")).data)',
    "  return 0",
    "end",
    "",
  }, "\n")))
  local ran = verbs_fixture.run(tmp, { "cmd/spam/main.tl" })
  assert(ran.code == 0 and ran.stdout == "spam's\tlogo\n", ran.stdout .. ran.stderr)
end

--- A program carries the files under its own `cmd/<name>/static/` laid over
--- `static/`: its own at the path of a shared one in its place, and the
--- other shared ones beside it. Another program carries the shared ones
--- alone, none of the first's own.
local function test_a_programs_own_static_files_are_laid_over_the_shared_ones(tmp: string)
  assert(Fs.mkdirs(tmp .. "/cmd/spam/static/css"))
  assert(Fs.mkdirs(tmp .. "/cmd/eggs"))
  assert(Fs.mkdirs(tmp .. "/static/css"))
  assert(Fs.write(tmp .. "/cmd/spam/main.tl", "return function(): integer return 0 end\n"))
  assert(Fs.write(tmp .. "/cmd/eggs/main.tl", "return function(): integer return 0 end\n"))
  assert(Fs.write(tmp .. "/static/css/app.css", "shared"))
  assert(Fs.write(tmp .. "/static/logo.png", "logo"))
  assert(Fs.write(tmp .. "/cmd/spam/static/css/app.css", "spam's"))
  assert(Fs.write(tmp .. "/cmd/spam/static/only.txt", "spam alone"))
  assert(embed.tree(tmp, true))
  local function payload(main: string): string
    local database = assert(embed.database(support.build_dir(tmp) .. "/cosmic.db", main))
    local path = tmp .. "/" .. main .. ".db"
    assert(Fs.write(path, database))
    local out: mut {string} = {}
    for _, row in ipairs(rows_of(path, "SELECT program, path, data FROM payload ORDER BY path")) do
      out[#out + 1] = "[" .. row:text(1) .. "] " .. row:text(2) .. "=" .. row:bytes(3)
    end
    return table.concat(out, ", ")
  end
  local spam = payload("cmd.spam.main")
  assert(spam == "[] css/app.css=spam's, [] logo.png=logo, [] only.txt=spam alone", spam)
  local eggs = payload("cmd.eggs.main")
  assert(eggs == "[] css/app.css=shared, [] logo.png=logo", eggs)
end

--- A program carries its own `cmd/<name>/doc/guides/<guide>.md` as the
--- guide `<guide>`, in place of the project's of that name, beside the
--- project's others; another program carries the project's alone. Each own
--- guide is a test of the project's as any guide is.
local function test_a_programs_own_guides_stand_in_for_the_projects(tmp: string)
  assert(Fs.mkdirs(tmp .. "/cmd/spam/doc/guides"))
  assert(Fs.mkdirs(tmp .. "/cmd/eggs"))
  assert(Fs.mkdirs(tmp .. "/doc/guides"))
  assert(Fs.write(tmp .. "/cmd/spam/main.tl", "return function(): integer return 0 end\n"))
  assert(Fs.write(tmp .. "/cmd/eggs/main.tl", "return function(): integer return 0 end\n"))
  assert(Fs.write(tmp .. "/doc/guides/start.md", "# start\n\nThe project's start.\n"))
  assert(Fs.write(tmp .. "/doc/guides/later.md", "# later\n\nThe project's later.\n"))
  assert(Fs.write(tmp .. "/cmd/spam/doc/guides/start.md", "# start\n\nSpam's start.\n"))
  assert(Fs.write(tmp .. "/cmd/spam/doc/guides/frying.md", "# frying\n\nSpam alone fries.\n"))
  assert(embed.tree(tmp, true))
  local kinds = rows_of(support.build_dir(tmp) .. "/cosmic.db",
    "SELECT kind FROM modules WHERE path = 'cmd.spam.doc.guides.frying'")
  assert(#kinds == 1 and support.nth(kinds, 1):text(1) == "test", "an own guide is a test of the project's")
  local function guides(main: string): string
    local database = assert(embed.database(support.build_dir(tmp) .. "/cosmic.db", main))
    local path = tmp .. "/" .. main .. ".db"
    assert(Fs.write(path, database))
    local out: mut {string} = {}
    for _, row in ipairs(rows_of(path, "SELECT module, text FROM docs WHERE symbol = '' ORDER BY module")) do
      out[#out + 1] = row:text(1) .. "=" .. ((row:text(2):match("\n\n([^\n]*)")) or row:text(2))
    end
    return table.concat(out, ", ")
  end
  local spam = guides("cmd.spam.main")
  assert(spam == "doc.guides.frying=Spam alone fries., doc.guides.later=The project's later., " ..
      "doc.guides.start=Spam's start.", spam)
  local eggs = guides("cmd.eggs.main")
  assert(eggs == "doc.guides.later=The project's later., doc.guides.start=The project's start.", eggs)
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
  assert(trouble:find("pinned", 1, true) == nil and trouble:find("add a marker", 1, true) == nil, trouble)
end

--- A program that says which roots its requests trust by default
--- ([`Http.default_roots`], or why it cannot tell), then whether a server
--- presenting a root the binary carries but the minimal roots leave out is
--- trusted, as far as a canned first flight takes a handshake.
local roots_source <const> = [[
local Http = require("cosmic.http")
local Store = require("cosmic.store")

local function message(kind: integer, body: string): string
  return string.char(kind) .. string.pack(">I3", #body) .. body
end

return function(): integer
  local databases = Store.databases()
  local found = assert(assert(databases[#databases]):rows(
    "SELECT der FROM ca_roots WHERE label = 'Telia RSA TLS Root CA v3'"))
  local der = assert(found[1]):blob(1)
  local hello = message(2, "\3\3" .. string.rep("B", 32) .. "\0" .. "\192\47" .. "\0")
  local certificate = message(11, string.pack(">I3", #der + 3) .. string.pack(">I3", #der) .. der)
  local records = hello .. certificate
  local flight = "\22\3\3" .. string.pack(">I2", #records) .. records
  local roots, why = Http.default_roots()
  print(roots or tostring(why))
  local _, refused = Http.open("https://cosmic.test/", { timeout_ns = 60000000000, script = { flight } })
  print((tostring(refused):gsub("\n", " ")))
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

--- A module the checker refuses exits 4, the status of a tree that did not compile, where a failure to write a program
--- exits 1; the program that does not need it is built all the same. A tree that cannot be ordered at all (an import
--- cycle) builds no program, and removes the one an earlier build left.
local function test_build_of_a_tree_that_does_not_compile_exits_4(tmp: string)
  write_project(tmp)
  local env = { COSMIC_BUILD_CACHE = "0", COSMIC_BUILD_HOME = assert(Env.get("COSMIC_BUILD_HOME")) }
  assert(Fs.write(tmp .. "/bad.tl", 'local n: integer = "x"\nreturn n\n'))
  local built = invoke.run({ "build", "--host" }, { cwd = tmp, env = env })
  local hello = support.build_dir(tmp) .. "/bin/hello"
  assert(built.code == 4 and built.stdout == hello .. "\n" and built.stderr:find("bad.tl", 1, true) ~= nil,
    tostring(built.code) .. built.stdout .. built.stderr)
  assert(assert(Fs.status(hello)).exists)
  assert(Fs.remove(tmp .. "/bad.tl"))
  assert(Fs.write(tmp .. "/ping.tl", 'local pong = require("pong")\nreturn pong\n'))
  assert(Fs.write(tmp .. "/pong.tl", 'local ping = require("ping")\nreturn ping\n'))
  local cycle = invoke.run({ "build", "--host" }, { cwd = tmp, env = env })
  assert(cycle.code == 4 and cycle.stdout == "", tostring(cycle.code) .. cycle.stdout .. cycle.stderr)
  assert(not assert(Fs.status(hello)).exists, "the earlier executable stood after a tree that cannot be ordered")
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
  local relaunch, _ = Proc.relaunch()
  if relaunch == nil then
    Test.skip("a native start has no cached core to read")
    return
  end
  local core = assert(artifact.trusted_core())
  assert(Hash.sha256(core.bytes) == core.digest, "the bytes are the ones the digest names")
  assert(core.bytes == assert(Fs.read(assert(relaunch.argv[1]))), "and the core this start runs")
end

--- A scratch project of two programs, `one` and `two`, `two` requiring the module `shared` and `one` requiring
--- nothing, and a test file beside `shared`.
local function write_two_programs(root: string)
  assert(Fs.mkdirs(root .. "/cmd/one"))
  assert(Fs.mkdirs(root .. "/cmd/two"))
  assert(Fs.write(root .. "/cmd/one/main.tl", "return function(): integer return 1 end\n"))
  assert(Fs.write(root .. "/cmd/two/main.tl",
    'local shared = require("shared")\nreturn function(): integer return shared.value() end\n'))
  assert(Fs.write(root .. "/shared.tl",
    "local record shared\nend\n\nfunction shared.value(): integer\n  return 2\nend\n\nreturn shared\n"))
  assert(Fs.write(root .. "/shared_test.tl",
    'local shared = require("shared")\n\nlocal function test_value()\n  assert(shared.value() == 2)\nend\n'))
end

local function build_env(): {string:string}
  return { COSMIC_BUILD_CACHE = "0", COSMIC_BUILD_HOME = assert(Env.get("COSMIC_BUILD_HOME")) }
end

--- A test file the checker refuses does not keep the programs from being built: both are written, the build says which
--- file was refused, and it still exits 4.
local function test_a_broken_test_file_leaves_the_programs_built_and_exits_4(tmp: string)
  write_two_programs(tmp)
  assert(Fs.write(tmp .. "/shared_test.tl", 'local n: integer = "x"\nreturn n\n'))
  local built = invoke.run({ "build", "--host" }, { cwd = tmp, env = build_env() })
  local bin = support.build_dir(tmp) .. "/bin"
  assert(built.code == 4, tostring(built.code) .. built.stdout .. built.stderr)
  assert(built.stdout == bin .. "/one\n" .. bin .. "/two\n", built.stdout)
  assert(built.stderr:find("shared_test.tl", 1, true) ~= nil, built.stderr)
  assert(assert(Fs.status(bin .. "/one")).exists and assert(Fs.status(bin .. "/two")).exists, "a program was not written")
end

--- A program the checker refuses is not written, and the executable an earlier build left for it is removed, in the build
--- directory and in `--out`, saying so; the other program is built.
local function test_a_broken_program_is_removed_and_the_other_built(tmp: string)
  write_two_programs(tmp)
  local out = tmp .. "/dist"
  local first = invoke.run({ "build", "--host", "--out", out }, { cwd = tmp, env = build_env() })
  assert(first.code == 0, first.stdout .. first.stderr)
  local bin = support.build_dir(tmp) .. "/bin"
  assert(assert(Fs.status(bin .. "/two")).exists and assert(Fs.status(out .. "/two")).exists)
  assert(Fs.write(tmp .. "/cmd/two/main.tl", 'local n: integer = "x"\nreturn function(): integer return n end\n'))
  local built = invoke.run({ "build", "--host", "--out", out }, { cwd = tmp, env = build_env() })
  assert(built.code == 4, tostring(built.code) .. built.stdout .. built.stderr)
  assert(built.stdout == bin .. "/one\n", built.stdout)
  assert(assert(Fs.status(bin .. "/one")).exists and assert(Fs.status(out .. "/one")).exists, "the other program was not built")
  assert(not assert(Fs.status(bin .. "/two")).exists, "the old executable was left in the build directory")
  assert(not assert(Fs.status(out .. "/two")).exists, "the old executable was left in --out")
  assert(built.stderr:find("cmd/two/main.tl", 1, true) ~= nil, built.stderr)
  assert(built.stderr:find("removed", 1, true) ~= nil and built.stderr:find(bin .. "/two", 1, true) ~= nil, built.stderr)
end

--- A module a program requires that does not compile refuses that program alone, and the program that does not need it is
--- built.
local function test_a_broken_module_refuses_only_the_programs_that_need_it(tmp: string)
  write_two_programs(tmp)
  assert(Fs.write(tmp .. "/shared.tl", 'local n: integer = "x"\nreturn n\n'))
  local built = invoke.run({ "build", "--host" }, { cwd = tmp, env = build_env() })
  local bin = support.build_dir(tmp) .. "/bin"
  assert(built.code == 4, tostring(built.code) .. built.stdout .. built.stderr)
  assert(built.stdout == bin .. "/one\n", built.stdout)
  assert(not assert(Fs.status(bin .. "/two")).exists)
  assert(built.stderr:find("shared.tl", 1, true) ~= nil and built.stderr:find("two", 1, true) ~= nil, built.stderr)
end

--- `--out <dir>` writes each executable into the directory under its program name, which is made where it is not there;
--- a clean build exits 0.
local function test_out_copies_each_executable_under_its_name(tmp: string)
  write_two_programs(tmp)
  local out = tmp .. "/dist/nested"
  local built = invoke.run({ "build", "--host", "--out", out }, { cwd = tmp, env = build_env() })
  assert(built.code == 0, built.stdout .. built.stderr)
  local bin = support.build_dir(tmp) .. "/bin"
  for _, name in ipairs({ "one", "two" }) do
    local copy = assert(Fs.read(out .. "/" .. name))
    assert(copy == assert(Fs.read(bin .. "/" .. name)), name .. " differs from the built one")
    assert(assert(Fs.stat(out .. "/" .. name)).mode & 0x49 == 0x49, name .. " is not executable")
  end
  local ran = run_program(out .. "/one")
  assert(ran.code == 1, tostring(ran.code))
end

--- An `--out` that is a file, or cannot be made, is refused before anything is built.
local function test_out_that_is_no_directory_is_refused(tmp: string)
  write_two_programs(tmp)
  assert(Fs.write(tmp .. "/afile", "x"))
  local built = invoke.run({ "build", "--host", "--out", tmp .. "/afile" }, { cwd = tmp, env = build_env() })
  assert(built.code == 2, tostring(built.code) .. built.stdout .. built.stderr)
  assert(built.stderr:find("--out", 1, true) ~= nil and built.stderr:find("not a directory", 1, true) ~= nil,
    built.stderr)
  assert(built.stdout == "", built.stdout)
  local under = invoke.run({ "build", "--host", "--out", tmp .. "/afile/sub" }, { cwd = tmp, env = build_env() })
  assert(under.code == 2 and under.stderr:find("--out", 1, true) ~= nil, tostring(under.code) .. under.stderr)
  assert(not assert(Fs.status(support.build_dir(tmp) .. "/bin/one")).exists, "a program was built for a refused --out")
end

--- A test that requires a module private to a directory breaks a position rule, and that refuses the test alone: both
--- programs are built, the test is named, the status is 4 and no executable is removed.
local function test_a_position_violation_refuses_only_the_module_that_breaks_it(tmp: string)
  write_two_programs(tmp)
  assert(Fs.mkdirs(tmp .. "/lib"))
  assert(Fs.write(tmp .. "/lib/init.tl", "local record lib\nend\nreturn lib\n"))
  assert(Fs.write(tmp .. "/lib/hidden.tl", "local record hidden\nend\nreturn hidden\n"))
  assert(Fs.write(tmp .. "/lib_hidden_test.tl",
    'local hidden = require("lib.hidden")\n\nlocal function test_hidden()\n  assert(hidden ~= nil)\nend\n'))
  local built = invoke.run({ "build", "--host" }, { cwd = tmp, env = build_env() })
  local bin = support.build_dir(tmp) .. "/bin"
  assert(built.code == 4, tostring(built.code) .. built.stdout .. built.stderr)
  assert(built.stdout == bin .. "/one\n" .. bin .. "/two\n", built.stdout)
  assert(built.stderr:find("lib_hidden_test.tl", 1, true) ~= nil and built.stderr:find("private", 1, true) ~= nil,
    built.stderr)
  -- A program that requires the private module is the one refused.
  assert(Fs.write(tmp .. "/cmd/two/main.tl",
    'local hidden = require("lib.hidden")\nreturn function(): integer return hidden == nil and 1 or 0 end\n'))
  local refused = invoke.run({ "build", "--host" }, { cwd = tmp, env = build_env() })
  assert(refused.code == 4 and refused.stdout == bin .. "/one\n", tostring(refused.code) .. refused.stdout .. refused.stderr)
  assert(not assert(Fs.status(bin .. "/two")).exists, "the refused program's earlier executable stood")
end

--- A `global` in a module refuses that module alone.
local function test_a_global_refuses_only_the_module_that_declares_it(tmp: string)
  write_two_programs(tmp)
  assert(Fs.write(tmp .. "/shared_test.tl", "global leaked: integer\n"))
  local built = invoke.run({ "build", "--host" }, { cwd = tmp, env = build_env() })
  local bin = support.build_dir(tmp) .. "/bin"
  assert(built.code == 4 and built.stdout == bin .. "/one\n" .. bin .. "/two\n",
    tostring(built.code) .. built.stdout .. built.stderr)
  assert(built.stderr:find("shared_test.tl", 1, true) ~= nil, built.stderr)
end

--- A refusal and a failure to write meet: the failure is the status (1, a failure to write is not a tree that did not
--- compile), and the refused file is named all the same.
local function test_a_failure_to_write_outranks_a_refusal_and_names_it(tmp: string)
  write_two_programs(tmp)
  assert(Fs.write(tmp .. "/shared_test.tl", 'local n: integer = "x"\nreturn n\n'))
  assert(Fs.write(support.build_dir(tmp) .. "/bin", "a file where the directory of executables goes"))
  local built = invoke.run({ "build", "--host" }, { cwd = tmp, env = build_env() })
  assert(built.code == 1, tostring(built.code) .. built.stdout .. built.stderr)
  assert(built.stderr:find("shared_test.tl", 1, true) ~= nil, "the refusal was not named: " .. built.stderr)
  assert(built.stderr:find("/bin", 1, true) ~= nil, built.stderr)
end

--- `--out` removes only a copy this build wrote: a file of the user's under a program's name stays, and a directory
--- that nothing was written to is not made.
local function test_out_removes_only_what_the_build_wrote_and_makes_no_empty_directory(tmp: string)
  write_two_programs(tmp)
  assert(Fs.mkdirs(tmp .. "/dist"))
  assert(Fs.write(tmp .. "/dist/two", "the user's own file"))
  assert(Fs.write(tmp .. "/cmd/two/main.tl", 'local n: integer = "x"\nreturn function(): integer return n end\n'))
  local built = invoke.run({ "build", "--host", "--out", "dist" }, { cwd = tmp, env = build_env() })
  assert(built.code == 4, tostring(built.code) .. built.stderr)
  assert(assert(Fs.read(tmp .. "/dist/two")) == "the user's own file", "a file cosmic did not write was removed")
  assert(built.stderr:find("not a file this build wrote", 1, true) ~= nil, built.stderr)
  assert(assert(Fs.status(tmp .. "/dist/one")).exists)
  -- Nothing built, nothing made.
  assert(Fs.write(tmp .. "/cmd/one/main.tl", 'local n: integer = "x"\nreturn function(): integer return n end\n'))
  local none = invoke.run({ "build", "--host", "--out", "fresh/sub" }, { cwd = tmp, env = build_env() })
  assert(none.code == 4, tostring(none.code) .. none.stderr)
  assert(not assert(Fs.status(tmp .. "/fresh")).exists, "--out was made for a build that wrote nothing")
end

--- A partial projection a build that stopped left behind is removed by the next build.
local function test_a_stale_partial_projection_is_removed(tmp: string)
  write_two_programs(tmp)
  local stale = support.build_dir(tmp) .. "/cosmic.db.partial"
  assert(Fs.write(stale, "left by a crash"))
  local built = invoke.run({ "build", "--host" }, { cwd = tmp, env = build_env() })
  assert(built.code == 0, built.stderr)
  assert(not assert(Fs.status(stale)).exists, "the stale partial projection stood")
end

--- What the `build` verb asks of the tool, supplied for a tool that carries the host's core alone, whatever this one
--- carries, and whose boot of every core returns `boot.answer` (nil: it does not boot) and records the command line
--- it was to re-enter, a line each, in `boot.asked`.
local function host_only_tool(boot: mut {string:string}): embed.Portable
  return {
    prefix = function(): string?, string return artifact.placeholder("aarch64-linux-musl"), "" end,
    every_core = function(argv: {string}): string?
      boot["asked"] = (boot["asked"] or "") .. table.concat(argv, " ") .. "\n"
      return boot["answer"]
    end,
  }
end

--- `words` run as a command line in `tmp` on a tool `portable` stands in for.
local function build_on(portable: embed.Portable, tmp: string, words: {string}): invoke.Result
  local own = embed.portable
  embed.portable = portable
  local results: mut {invoke.Result} = {}
  local ran, trouble = pcall(function()
    results[1] = invoke.run(words, { cwd = tmp, env = build_env() })
  end)
  embed.portable = own
  assert(ran, tostring(trouble))
  return (assert(results[1]))
end

--- A tool that cannot make a portable program (it carries the host's core alone, and does not boot every core) says so
--- and removes nothing: the executables of an earlier build stand, and `--out` is not made.
local function test_an_environment_failure_removes_no_executable(tmp: string)
  write_two_programs(tmp)
  local first = invoke.run({ "build", "--host" }, { cwd = tmp, env = build_env() })
  assert(first.code == 0, first.stderr)
  local bin = support.build_dir(tmp) .. "/bin"
  local again = build_on(host_only_tool({}), tmp, { "build", "--out", "dist" })
  assert(again.code == 1 and again.stderr:find("-Dboot-cores=all", 1, true) ~= nil,
    tostring(again.code) .. again.stderr)
  assert(assert(Fs.status(bin .. "/one")).exists and assert(Fs.status(bin .. "/two")).exists, "an environment failure removed a program")
  assert(not assert(Fs.status(tmp .. "/dist")).exists, "--out was made for a build that wrote nothing")
end

--- A portable program asked of a tool that carries the host's core alone has the tool boot every core and run the
--- command line again, once its programs compiled. A boot that fails is said and exits 3; where the tool does not
--- boot, the build refuses and names the boot. `--host`, which needs no other core, asks for none.
local function test_a_portable_build_on_a_host_only_tool_boots_every_core(tmp: string)
  write_two_programs(tmp)
  local boot: mut {string:string} = { answer = "bin/zig build boot -Dboot-cores=all failed" }
  local failed = build_on(host_only_tool(boot), tmp, { "build", "cmd/one" })
  assert(boot["asked"] == "build cmd/one\n", tostring(boot["asked"]))
  assert(failed.code == 3, tostring(failed.code) .. failed.stderr)
  assert(failed.stderr:find("bin/zig build boot -Dboot-cores=all failed", 1, true) ~= nil, failed.stderr)
  assert(failed.stdout == "", failed.stdout)

  local refusing: mut {string:string} = {}
  local refused = build_on(host_only_tool(refusing), tmp, { "build", "cmd/one" })
  assert(refusing["asked"] == "build cmd/one\n", tostring(refusing["asked"]))
  assert(refused.code == 1 and refused.stderr:find("carries the host's core alone", 1, true) ~= nil,
    tostring(refused.code) .. refused.stderr)

  local host: mut {string:string} = { answer = "booted for a --host build" }
  local built = build_on(host_only_tool(host), tmp, { "build", "--host", "cmd/one" })
  assert(built.code == 0 and host["asked"] == nil, tostring(built.code) .. tostring(host["asked"]) .. built.stderr)
end

--- A build that stops for another reason boots nothing: a program that does not compile is the tree's to mend.
local function test_a_build_that_does_not_compile_boots_no_core(tmp: string)
  write_two_programs(tmp)
  assert(Fs.write(tmp .. "/cmd/one/main.tl", 'local n: integer = "x"\nreturn function(): integer return n end\n'))
  local boot: mut {string:string} = { answer = "booted for a program that does not compile" }
  local built = build_on(host_only_tool(boot), tmp, { "build", "cmd/one" })
  assert(built.code == 4 and boot["asked"] == nil, tostring(built.code) .. tostring(boot["asked"]) .. built.stderr)
end

-- TODO: cover `--out` of a portable program, as [`build/embed_portable_tool_test.tl`] covers `bin/`, once a run of
-- the suite carries every core (`bin/zig build boot -Dboot-cores=all`): a host-only tool makes only `--host` programs.

--- A module that breaks a position rule holds out every module resting on it, and the program at the end of the chain
--- (prog -> mid -> a), while the program that rests on none of them is built and the held-out program's earlier
--- executable is removed.
local function test_a_position_breach_holds_out_the_program_resting_on_it(tmp: string)
  write_two_programs(tmp)
  local first = invoke.run({ "build", "--host" }, { cwd = tmp, env = build_env() })
  assert(first.code == 0, first.stderr)
  assert(Fs.mkdirs(tmp .. "/lib"))
  assert(Fs.write(tmp .. "/lib/init.tl", "local record lib\nend\nreturn lib\n"))
  assert(Fs.write(tmp .. "/lib/hidden.tl", "local record hidden\nend\nreturn hidden\n"))
  assert(Fs.write(tmp .. "/a.tl", 'local hidden = require("lib.hidden")\nlocal record a\nend\nreturn a\n'))
  assert(Fs.write(tmp .. "/mid.tl", 'local a = require("a")\nlocal record mid\nend\nreturn mid\n'))
  assert(Fs.write(tmp .. "/cmd/two/main.tl",
    'local mid = require("mid")\nreturn function(): integer return mid == nil and 1 or 0 end\n'))
  local built = invoke.run({ "build", "--host" }, { cwd = tmp, env = build_env() })
  local bin = support.build_dir(tmp) .. "/bin"
  assert(built.code == 4 and built.stdout == bin .. "/one\n", tostring(built.code) .. built.stdout .. built.stderr)
  assert(built.stderr:find("a.tl: lib.hidden is private to lib/", 1, true) ~= nil, built.stderr)
  -- `a` is held out for its position, not refused by the checker: the line says only that it did not build.
  assert(built.stderr:find("mid.tl: not compiled: it requires a, which did not build", 1, true) ~= nil, built.stderr)
  assert(built.stderr:find("two (cmd/two/main.tl) was not built", 1, true) ~= nil, built.stderr)
  assert(not assert(Fs.status(bin .. "/two")).exists, "the held-out program's earlier executable stood")
end

--- A `global` in a declaration file belongs to no module: it stops the whole tree, writes no program and removes the
--- executables an earlier build made.
local function test_a_global_of_a_declaration_file_stops_the_whole_tree(tmp: string)
  write_two_programs(tmp)
  local first = invoke.run({ "build", "--host" }, { cwd = tmp, env = build_env() })
  assert(first.code == 0, first.stderr)
  assert(Fs.write(tmp .. "/types.d.tl", "--- @kind binding\nglobal leaked: integer\n"))
  local built = invoke.run({ "build", "--host" }, { cwd = tmp, env = build_env() })
  assert(built.code == 4 and built.stdout == "", tostring(built.code) .. built.stdout .. built.stderr)
  assert(built.stderr:find("types.d.tl", 1, true) ~= nil, built.stderr)
  local bin = support.build_dir(tmp) .. "/bin"
  assert(not assert(Fs.status(bin .. "/one")).exists and not assert(Fs.status(bin .. "/two")).exists, "an executable stood")
end

--- A build without `--out` leaves the copy an earlier `--out` build wrote, and a copy the user removed is forgotten,
--- so a later build does not say it is not cosmic's.
local function test_the_manifest_forgets_a_copy_that_is_gone(tmp: string)
  write_two_programs(tmp)
  local first = invoke.run({ "build", "--host", "--out", "dist" }, { cwd = tmp, env = build_env() })
  assert(first.code == 0, first.stderr)
  local plain = invoke.run({ "build", "--host" }, { cwd = tmp, env = build_env() })
  assert(plain.code == 0 and assert(Fs.status(tmp .. "/dist/one")).exists, plain.stderr)
  assert(Fs.remove(tmp .. "/dist/two"))
  assert(Fs.write(tmp .. "/dist/two", "the user's own file, put where the copy was"))
  assert(Fs.write(tmp .. "/cmd/two/main.tl", 'local n: integer = "x"\nreturn function(): integer return n end\n'))
  local again = invoke.run({ "build", "--host", "--out", "dist" }, { cwd = tmp, env = build_env() })
  assert(again.code == 4, again.stderr)
  assert(assert(Fs.read(tmp .. "/dist/two")) == "the user's own file, put where the copy was")
end

local till_commands = [[
--- What the till does, a command a field.

local Flags = require("cosmic.flags")

--- The till's commands, each documented by the comment on its field.
local record Commands
  --- Rings up a sale and writes it to the day's journal. The amount is in
  --- cents, so no sale is ever rounded; [`Commands.journal`] prints it back.
  ring: Flags.Command
  --- Prints the day's journal, the newest sale last.
  journal: Flags.Command
  --- Takes back the last sale.
  void: Flags.Command
end

local commands: Commands = {
  ring = {
    about = "ring up a sale", usage = "[options] <item>", group = "Sales", see = { "docs" },
    spec = { ["--cents"] = { value = "n", about = "what it cost" } },
    examples = { { line = "--cents 250 espresso", about = "ring up a coffee" } },
    run = function(_: Flags.Parsed): integer return 0 end,
  },
  void = {
    about = "strike the receipt out", group = "Sales",
    run = function(_: Flags.Parsed): integer return 0 end,
  },
  journal = {
    about = "print the day's sales", group = "Reports",
    run = function(_: Flags.Parsed): integer return 0 end,
  },
}

return commands
]]

local till_module = [[
local Commands = require("commands")
local Flags = require("cosmic.flags")

local record Till
end

--- Runs the till with `argv`, its commands documented by the record that holds them.
function Till.run(argv: {string}): Flags.Dispatched?, string
  return Flags.dispatch(argv, 1, { ring = Commands.ring, journal = Commands.journal, void = Commands.void }, "till",
    { pages = "commands", groups = { "Sales", "Reports" },
      topics = { closing = { guide = "closing", about = "how the day ends", see = { "journal" } } } })
end

return Till
]]

local till_main = [[
local Fs = require("cosmic.fs")
local Till = require("till")

return function(argv: {string}): integer
  local ran, why = Till.run(argv)
  if ran == nil then
    local _, _ = Fs.put(Fs.stderr, "till: " .. why .. "\n")
    return 2
  end
  if ran.help ~= "" then
    local _, _ = Fs.put(Fs.stdout, ran.help .. "\n")
  end
  return ran.code
end
]]

--- A test of the till's help, which reads the documentation its store is given of the modules it requires.
local till_test = [[
local Commands = require("commands")
local Doc = require("cosmic.doc")
local Flags = require("cosmic.flags")
local Store = require("cosmic.store")
local Test = require("cosmic.test")
local Till = require("till")

Test.policy { store_text = true }

local function test_a_topic_s_page_is_its_guide()
  local ran = assert(Till.run({ "help", "closing" }))
  assert(ran.help == "closing: how the day ends\n\nAt the end of the day, reconcile the journal against the drawer." ..
    "\n\nsee also: journal", ran.help)
  local missing, why = Flags.dispatch({ "help", "opening" }, 1, { ring = Commands.ring }, "till",
    { pages = "commands", topics = { opening = { guide = "opening" } } })
  assert(missing == nil and why == "help: the topic opening's guide, doc/guides/opening.md, is not in the documentation",
    why)
end

local function test_the_project_s_guides_answer_in_its_store()
  local view = assert(Doc.program(Store.databases(), "till"))
  local found = assert(Doc.lookup(view, "doc.guides.closing"))
  assert(#found == 1 and found.exact, tostring(#found))
  local text, _ = Doc.guide(view, "closing")
  assert(text == "At the end of the day, reconcile the journal against the drawer.")
end

local function test_docs_finds_a_command_by_its_example_and_its_about()
  local example = assert(Till.run({ "docs", "espresso" }))
  assert(example.help:find("Commands.ring", 1, true) ~= nil and
    example.help:find("\n  examples:\n    till ring --cents 250 espresso  ring up a coffee", 1, true) ~= nil, example.help)
  local about = assert(Till.run({ "docs", "strike" }))
  assert(about.help:find("Commands.void", 1, true) ~= nil and
    about.help:find("\n  usage: till void\n  strike the receipt out", 1, true) ~= nil, about.help)
end

local function test_the_help_of_a_command_ends_with_its_page()
  local ran = assert(Till.run({ "help", "journal" }))
  assert(ran.help == "usage: till journal\n\nprint the day's sales\n\nPrints the day's journal, the newest sale last.",
    ran.help)
end

local function test_docs_finds_a_command_by_a_word_of_its_page()
  local ran = assert(Till.run({ "docs", "newest" }))
  assert(ran.help:find("Commands.journal", 1, true) ~= nil, ran.help)
end
]]

--- What the built till prints for `words`, and its exit status.
local function till(tmp: string, words: {string}): Child.Result
  local argv: mut {string} = { support.build_dir(tmp) .. "/bin/till" }
  for _, word in ipairs(words) do argv[#argv + 1] = word end
  return (assert(Child.run(argv, { stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(30) })))
end

--- Writes the till's project under `tmp`: a program, the module that holds and documents its commands, a guide
--- and a test of its help.
local function write_till(tmp: string)
  assert(Fs.mkdirs(tmp .. "/cmd/till"))
  assert(Fs.mkdirs(tmp .. "/doc/guides"))
  assert(Fs.write(tmp .. "/cmd/till/main.tl", till_main))
  assert(Fs.write(tmp .. "/commands.tl", till_commands))
  assert(Fs.write(tmp .. "/till.tl", till_module))
  assert(Fs.write(tmp .. "/commands_test.tl", till_test))
  assert(Fs.write(tmp .. "/doc/guides/closing.md",
    "# Closing the till\n\nAt the end of the day, reconcile the journal against the drawer.\n"))
end

--- A program that names the module documenting its commands serves its users from its own documentation, with
--- nothing but itself: a command's help ends with the field's doc comment, `docs` looks a name up, searches the
--- comments and guides, puts a misspelling right, and knows nothing of the standard library's.
local function test_a_built_program_answers_help_and_docs_from_the_documentation_it_carries(tmp: string)
  write_till(tmp)
  local names, trouble = embed.tree(tmp, true)
  assert(names ~= nil and names[1] == "till", trouble)
  local help = till(tmp, { "help", "ring" })
  assert(help.ok and help.stdout == table.concat({
    "usage: till ring [options] <item>",
    "",
    "ring up a sale",
    "",
    "options:",
    "  --cents <n>  what it cost",
    "",
    "examples:",
    "  till ring --cents 250 espresso  ring up a coffee",
    "",
    "see also: docs",
    "",
    "Rings up a sale and writes it to the day's journal. The amount is in",
    "cents, so no sale is ever rounded; `Commands.journal` prints it back.",
    "",
  }, "\n"), tostring(help.stdout) .. tostring(help.stderr))
  -- `--help` after the command is the same page.
  assert(till(tmp, { "ring", "--help" }).stdout == help.stdout)
  -- The program's help orders its sections as it was told, and says how to search.
  local index = assert(till(tmp, { "help" }).stdout)
  local sales, reports = index:find("\nSales:\n", 1, true), index:find("\nReports:\n", 1, true)
  assert(sales ~= nil and reports ~= nil and sales < reports, index)
  assert(index:find("Run `till docs <words>` to search the documentation, `till docs` to list it.", 1, true) ~= nil,
    index)
  -- `docs` is a command with a help of its own, by either spelling, and is named to one who mistypes it.
  local docs_help = assert(till(tmp, { "help", "docs" }).stdout)
  assert(docs_help:find("usage: till docs [words...]", 1, true) == 1 and
      docs_help == till(tmp, { "docs", "--help" }).stdout, docs_help)
  assert(till(tmp, { "docz" }).stderr == "till: no such command: docz; did you mean docs?\n")
  assert(till(tmp, { "help", "docz" }).stderr == "till: no such command or topic: docz; did you mean docs?\n")
  -- It takes words, and refuses an option it does not have.
  local optioned = till(tmp, { "docs", "--json", "journal" })
  assert(optioned.code == 2 and assert(optioned.stderr):find("docs: no such option: --json", 1, true) ~= nil,
    tostring(optioned.stderr))
  -- `docs` lists what is documented, and its hints name the program.
  local listed = assert(till(tmp, { "docs" }).stdout)
  assert(listed:find("commands            What the till does, a command a field.", 1, true) ~= nil and
      listed:find("doc.guides.closing  At the end of the day", 1, true) ~= nil and
      listed:find("`till docs <module>` shows one", 1, true) ~= nil and not listed:find("cosmic", 1, true), listed)
  -- A command's field is found by name, with the command's options under it and no count of its uses, which
  -- the program has no command to list.
  local named = assert(till(tmp, { "docs", "Commands.ring" }).stdout)
  assert(named:find("Rings up a sale", 1, true) ~= nil and named:find("\n  options:\n    --cents <n>  what it cost", 1, true) ~= nil,
    named)
  local module = assert(till(tmp, { "docs", "commands" }).stdout)
  assert(not named:find("cosmic", 1, true) and not module:find("cosmic uses", 1, true) and
      not module:find(" use)", 1, true) and not module:find("used in", 1, true), named .. module)
  -- A topic's page is the guide it names, and the index lists it.
  local topic = till(tmp, { "help", "closing" })
  assert(topic.code == 0 and topic.stdout ==
      "closing: how the day ends\n\nAt the end of the day, reconcile the journal against the drawer.\n\n" ..
      "see also: journal\n", tostring(topic.stdout) .. tostring(topic.stderr))
  assert(index:find("\ntopics:\n  closing  how the day ends\n", 1, true) ~= nil, index)
  -- A word of a command's example or of its about finds the command, its page showing them.
  local by_example = assert(till(tmp, { "docs", "espresso" }).stdout)
  assert(by_example:find("Commands.ring", 1, true) ~= nil and
      by_example:find("\n  examples:\n    till ring --cents 250 espresso  ring up a coffee", 1, true) ~= nil, by_example)
  local by_about = assert(till(tmp, { "docs", "strike" }).stdout)
  assert(by_about:find("Commands.void", 1, true) ~= nil and by_about:find("strike the receipt out", 1, true) ~= nil,
    by_about)
  -- Words are searched for in the comments and the guides, and a misspelled one is put right.
  local searched = assert(till(tmp, { "docs", "reconcile", "drawer" }).stdout)
  assert(searched:find("doc.guides.closing (doc/guides/closing.md)", 1, true) ~= nil, searched)
  local respelled = assert(till(tmp, { "docs", "roundd" }).stdout)
  assert(respelled:find("Nothing named or documented as 'roundd'; showing 'rounded':", 1, true) == 1 and
      respelled:find("Commands.ring", 1, true) ~= nil, respelled)
  -- The standard library is not the program's to document, `cosmic` is a word like any other, and a miss is a
  -- refusal.
  for _, query in ipairs({ "Fs.read", "cosmic.flags", "cosmic", "zzqqxx" }) do
    local missed = till(tmp, { "docs", query })
    assert(missed.code == 2 and missed.stdout == "" and
        missed.stderr == "till: docs: nothing named or documented as '" .. query .. "'\n", tostring(missed.stderr))
  end
end

--- Run from its source by the tool, the program serves from the project's own build and from none of the
--- tool's documentation, which the same store holds: a command's help ends with its page, and the tool's guides
--- and the standard library are not the program's to show.
local function test_a_program_run_from_its_source_answers_from_the_projects_documentation_alone(tmp: string)
  write_till(tmp)
  local help = verbs_fixture.run(tmp, { "cmd/till/main.tl", "help", "journal" })
  assert(help.code == 0 and help.stdout ==
      "usage: till journal\n\nprint the day's sales\n\nPrints the day's journal, the newest sale last.\n",
    help.stdout .. help.stderr)
  local topic = verbs_fixture.run(tmp, { "cmd/till/main.tl", "help", "closing" })
  assert(topic.code == 0 and topic.stdout:find("\n\nAt the end of the day, reconcile", 1, true) ~= nil,
    topic.stdout .. topic.stderr)
  for _, query in ipairs({ "quickstart", "Fs.read", "cosmic.flags" }) do
    local missed = verbs_fixture.run(tmp, { "cmd/till/main.tl", "docs", query })
    assert(missed.code == 2 and missed.stdout == "" and
        missed.stderr:find("till: docs: nothing named or documented as '" .. query .. "'", 1, true) ~= nil,
      missed.stdout .. missed.stderr)
  end
  local listed = verbs_fixture.run(tmp, { "cmd/till/main.tl", "docs" })
  assert(listed.stdout:find("doc.guides.closing  ", 1, true) ~= nil and listed.stdout:find("\ntill", 1, true) ~= nil and
      not listed.stdout:find("doc.guides.quickstart", 1, true) and not listed.stdout:find("cosmic", 1, true),
    listed.stdout .. listed.stderr)
end

--- Run from its source beside another program, a program behaves as it would built: neither the other's
--- module nor its guide, which stands in for the project's of that name in that one alone, and its own guides
--- under the guide's name, one in place of the project's of the same name.
local function test_a_program_run_from_its_source_answers_for_itself_alone(tmp: string)
  write_till(tmp)
  assert(Fs.mkdirs(tmp .. "/cmd/eggs/doc/guides"))
  assert(Fs.mkdirs(tmp .. "/cmd/till/doc/guides"))
  assert(Fs.write(tmp .. "/eggs.tl", "--- Scrambling, which only eggs requires; it flouts the rules.\nlocal record eggs\nend\nreturn eggs\n"))
  assert(Fs.write(tmp .. "/cmd/eggs/main.tl",
    'local _eggs = require("eggs")\nreturn function(): integer return 0 end\n'))
  assert(Fs.write(tmp .. "/cmd/eggs/doc/guides/closing.md", "# Closing the coop\n\nShut the hens in.\n"))
  assert(Fs.write(tmp .. "/cmd/till/doc/guides/opening.md", "# Opening the till\n\nCount the float first.\n"))
  assert(Fs.write(tmp .. "/cmd/till/doc/guides/closing.md", "# Closing this till\n\nCount the drawer twice.\n"))
  local listed = verbs_fixture.run(tmp, { "cmd/till/main.tl", "docs" })
  assert(listed.code == 0 and listed.stdout:find("doc.guides.closing  ", 1, true) ~= nil and
      listed.stdout:find("doc.guides.opening  ", 1, true) ~= nil and not listed.stdout:find("eggs", 1, true) and
      not listed.stdout:find("cmd.till.doc", 1, true), listed.stdout .. listed.stderr)
  local closing = verbs_fixture.run(tmp, { "cmd/till/main.tl", "help", "closing" })
  assert(closing.code == 0 and closing.stdout:find("Count the drawer twice.", 1, true) ~= nil and
      not closing.stdout:find("reconcile the journal", 1, true) and not closing.stdout:find("hens", 1, true),
    closing.stdout .. closing.stderr)
  local opening = verbs_fixture.run(tmp, { "cmd/till/main.tl", "docs", "float" })
  assert(opening.code == 0 and opening.stdout:find("doc.guides.opening", 1, true) ~= nil,
    opening.stdout .. opening.stderr)
  -- Nor a code of the checker, which the tool documents and no built program carries.
  for _, query in ipairs({ "Scrambling", "hens", "eggs", "not_assignable" }) do
    local missed = verbs_fixture.run(tmp, { "cmd/till/main.tl", "docs", query })
    assert(missed.code == 2 and missed.stdout == "" and
        missed.stderr:find("nothing named or documented as '" .. query .. "'", 1, true) ~= nil,
      query .. ": " .. missed.stdout .. missed.stderr)
  end
  -- A word only another program's documentation uses is no word of its own: it is put right to one of its own.
  local respelled = verbs_fixture.run(tmp, { "cmd/till/main.tl", "docs", "flout" })
  assert(respelled.code == 0 and respelled.stdout:find("showing 'float'", 1, true) ~= nil and
      respelled.stdout:find("doc.guides.opening", 1, true) ~= nil, respelled.stdout .. respelled.stderr)
end

--- Run from its source, a program's view searches and ranks the examples of what it documents alone, and the
--- catalog of what it carries: its connection to the project's last build holds those rows, and an index of them, in
--- place of every program's. An error's guidance is matched against the catalog of what it carries alone too.
local function test_a_program_run_from_its_source_holds_the_examples_of_what_it_documents(tmp: string)
  assert(Fs.mkdirs(tmp .. "/cmd/spam"))
  assert(Fs.mkdirs(tmp .. "/cmd/eggs"))
  assert(Fs.write(tmp .. "/cmd/spam/main.tl", 'local _shared = require("shared")\nreturn function(): integer return 0 end\n'))
  assert(Fs.write(tmp .. "/cmd/eggs/main.tl", 'local _eggs = require("eggs")\nreturn function(): integer return 0 end\n'))
  for _, name in ipairs({ "shared", "eggs" }) do
    assert(Fs.write(tmp .. "/" .. name .. ".tl", table.concat({
      "--- " .. name .. ".",
      "local record m",
      "  --- A field.",
      "  n: integer",
      "end",
      "local v: m = { n = 1 }",
      "--- Fails, as " .. name .. " does.",
      "function m.fail(): string?, string",
      '  return nil, "' .. (if name == "eggs" then "the hens refused their coop" else "the drawer jammed shut" end) .. '"',
      "end",
      "return v",
      "",
    }, "\n")))
    assert(Fs.write(tmp .. "/" .. name .. "_example.tl", table.concat({
      'local m = require("' .. name .. '")',
      "local record Example",
      "end",
      "--- Reads the field of " .. name .. ".",
      "function Example.read()",
      "  assert(m.n == 1)",
      "end",
      "return Example",
      "",
    }, "\n")))
  end
  assert(Fs.write(tmp .. "/paged.tl", table.concat({
    "--- The pages, which no module requires.",
    "local record paged",
    "end",
    "--- Fails, as the pages do.",
    "function paged.fail(): string?, string",
    '  return nil, "the till ran out of receipts"',
    "end",
    "return paged",
    "",
  }, "\n")))
  assert(embed.tree(tmp, true))
  local projection = support.build_dir(tmp) .. "/cosmic.db"
  local main, built, pages = source_run.main, source_run.projection, source_run.pages
  local ok, err = pcall(function()
    source_run.main = "cmd.spam.main"
    source_run.projection = projection
    local db = assert(Sqlite.open(projection))
    local view = assert(Doc.program({ db }, "spam"))
    local scoped = assert(view.databases[1])
    local modules = assert(scoped:rows("SELECT group_concat(DISTINCT module) FROM examples"))
    assert(support.nth(modules, 1):text(1) == "shared", "the examples of what it documents alone")
    local indexed = assert(scoped:rows(
      "SELECT count(*) FROM examples_fts WHERE examples_fts MATCH 'eggs'"))
    assert(support.nth(indexed, 1):integer(1) == 0, "the index holds no other program's example")
    local cataloged = assert(scoped:rows(
      "SELECT count(*) FROM catalog_fts JOIN catalog c ON c.id = catalog_fts.rowid WHERE catalog_fts MATCH 'hens' " ..
        "AND c.module = 'eggs'"))
    assert(support.nth(cataloged, 1):integer(1) == 0, "the catalog holds no other program's row")
    assert(Errors.guidance_in(db, "the hens refused their coop") == nil, "no other program's guidance answers")
    assert(Errors.guidance_in(db, "the drawer jammed shut") ~= nil, "its own does")
    assert(Errors.guidance_in(db, "the till ran out of receipts") == nil, "a module it does not carry answers none")
    source_run.pages = "paged"
    assert(Errors.guidance_in(db, "the till ran out of receipts") ~= nil, "the module it names as its pages does")
    source_run.main = nil
    assert(Errors.guidance_in(db, "the hens refused their coop") ~= nil, "every program's answers another run")
    local _, _ = db:close()
  end)
  source_run.main, source_run.projection, source_run.pages = main, built, pages
  assert(ok, tostring(err))
end

--- A test of the project that asks its program for help reads the documentation of the modules it requires.
local function test_a_projects_test_of_its_help_reads_the_documentation_it_declares(tmp: string)
  write_till(tmp)
  local ran = verbs_fixture.run(tmp, { "test" })
  assert(ran.code == 0 and ran.stdout:find("5 tests passed", 1, true) ~= nil, ran.stdout .. ran.stderr)
end
