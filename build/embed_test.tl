--- Proves `cosmic build` writes an executable for a project: the tree
--- is a fixture under a fresh temp directory, shaped as a binary is --
--- `cmd/<name>/main.tl` and a module beside it -- and the database the
--- executable carries is read back and checked for what a program
--- needs at run time and nothing it does not.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local artifact = require("build.artifact")
local embed = require("build.embed")
local observations = require("build.filesystem_observations")

-- What these tests start is this very program.
observations.confine({ reads = observations.itself() })

local main_source = [[
local Fs = require("cosmic.fs")
local greet = require("greet")

return function(argv: {string}): integer
  Fs.put(Fs.stdout, greet.hello(argv[1] or "world") .. "\n")
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

local function rows_of(path: string, sql: string): {{string}}
  local db = assert(Sqlite.open(path))
  local rows = assert(Sqlite.text_rows(db, sql))
  db:close()
  return rows
end

local function test_a_project_becomes_an_executable(tmp: string)
  write_project(tmp)
  local names, trouble = embed.tree(tmp)
  assert(names ~= nil, trouble)
  assert(#names == 1 and names[1] == "hello")

  local out = tmp .. "/o/bin/hello"
  local st = assert(Fs.stat(out))
  assert(st.mode & 0x49 == 0x49, "the executable bit is set for everyone")
  local bytes = assert(Fs.read(out))
  local prefix = assert(artifact.trusted_prefix())
  assert(bytes:sub(1, 10) == "#!/bin/sh\n",
    "the portable file has its script entry")
  assert(bytes:sub(1, #prefix) == prefix,
    "the portable file reuses the exact retained prefix")
end

local function test_the_carried_database_holds_what_a_program_needs(tmp: string)
  write_project(tmp)
  assert(embed.tree(tmp))
  local database = assert(embed.database(tmp .. "/o/cosmic.db", "cmd.hello.main"))
  local path = tmp .. "/carried.db"
  assert(Fs.write(path, database))

  local meta: {string:string} = {}
  for _, row in ipairs(rows_of(path, "SELECT key, value FROM meta")) do
    meta[row[1]] = row[2]
  end
  assert(meta["main"] == "cmd.hello.main", "main names the module to run")
  assert(meta["host"] == nil, "a portable database carries no host")
  assert(meta["runtime"] == nil, "a portable database carries no runtime")
  assert(meta["runtime_basis"] ~= nil and meta["runtime_basis"] ~= "",
    "a portable database carries the runtime basis")

  local modules: {string:string} = {}
  for _, row in ipairs(rows_of(path, "SELECT path, kind FROM modules")) do
    modules[row[1]] = row[2]
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
  assert(images[1][1] == "0", "portable databases have no images table")
  local guidance = rows_of(path,
    "SELECT count(*) FROM catalog_fts WHERE catalog_fts MATCH 'coverage'")
  assert(tonumber(guidance[1][1]) > 0, "the error catalog is in, and indexed")
  local text = rows_of(path,
    "SELECT coalesce(length(text), 0) FROM catalog WHERE symbol = 'Coverage.start'")
  assert(#text == 1 and tonumber(text[1][1]) > 0,
    "a row carries its guidance, though the docs it comes from are not")
  local about_build = rows_of(path,
    "SELECT count(*) FROM catalog WHERE module LIKE 'build.%'")
  assert(about_build[1][1] == "0", "guidance about the build is not")
end

local function test_a_tree_without_a_main_builds_and_writes_nothing(tmp: string)
  assert(Fs.write(tmp .. "/greet.tl", greet_source))
  local names, trouble = embed.tree(tmp)
  assert(names ~= nil, trouble)
  assert(#names == 0, "a library tree has no executable to write")
  local database_exists, exists_trouble = Fs.exists(tmp .. "/o/cosmic.db")
  assert(database_exists ~= nil, exists_trouble)
  assert(database_exists, "but it was built")
  assert(Fs.exists(tmp .. "/o/bin") == false)
end

local function test_cosmic_s_own_tree_is_refused(tmp: string)
  assert(Fs.mkdirs(tmp .. "/core"))
  assert(Fs.mkdirs(tmp .. "/build"))
  assert(Fs.write(tmp .. "/build/importer.tl", "return {}\n"))
  local names, trouble = embed.tree(tmp)
  assert(names == nil)
  assert(trouble:find("bin/zig build boot", 1, true) ~= nil, trouble)
end

local identity_source = [[
local Proc = require("cosmic.proc")
local Store = require("cosmic.store")

return function(): integer
  print(Store.meta("runtime_context"), Store.meta("host_image"),
    Store.meta("runtime"), (Proc.executable()))
  return 0
end
]]

local function run_program(path: string): Child.Result
  return (assert(Child.run({ path }, { stdout = "capture", stderr = "capture",
    timeout_ms = 30000 })))
end

--- `--host` writes this core itself with the program inside: the kernel
--- runs it directly, and it names the same runtime identity as the core
--- that built it, so a verdict holds across the two.
local function test_a_host_program_is_the_core_itself(tmp: string)
  assert(Fs.mkdirs(tmp .. "/cmd/who"))
  assert(Fs.write(tmp .. "/cmd/who/main.tl", identity_source))
  local names, trouble = embed.tree(tmp, true)
  assert(names ~= nil and names[1] == "who", trouble)
  local out = tmp .. "/o/bin/who"
  local bytes = assert(Fs.read(out))
  local core = assert(artifact.trusted_core())
  assert(bytes:sub(1, #core.bytes) == core.bytes, "the file starts with the running core")
  assert(bytes:sub(-48, -41) == "CosmicH1", "its trailer says host")
  local r = run_program(out)
  assert(r.ok, tostring(r.stderr))
  -- The path is the executable's own, resolved: on macOS a temporary
  -- directory under /var is reported under /private/var.
  local expected = table.concat({ "host-v1", assert(Store.meta("host_image")),
    assert(Store.meta("runtime")) }, "\t") .. "\t"
  local printed = assert(r.stdout)
  assert(printed:sub(1, #expected) == expected, printed .. " ~= " .. expected)
  assert(printed:sub(-#"/o/bin/who\n") == "/o/bin/who\n", printed)
end

--- A host program runs without checking its own core's digest, but the
--- identity it would report is checked first, and one whose manifest names
--- another digest reports none.
local function test_a_host_program_names_no_identity_it_cannot_prove(tmp: string)
  assert(Fs.mkdirs(tmp .. "/cmd/who"))
  assert(Fs.write(tmp .. "/cmd/who/main.tl", identity_source))
  assert(embed.tree(tmp, true))
  local out = tmp .. "/o/bin/who"
  local bytes = assert(Fs.read(out))
  local core = assert(artifact.trusted_core())
  local at = bytes:find(core.digest, #core.bytes + 1, true)
  assert(at ~= nil, "the manifest names the core's digest")
  local lied = bytes:sub(1, at - 1) .. string.rep("\0", 32) .. bytes:sub(at + 32)
  assert(Fs.write(out, lied, 0x1ed))
  local r = run_program(out)
  assert(r.ok, tostring(r.stderr))
  assert(assert(r.stdout):sub(1, 12) == "host-v1\tnil\t", tostring(r.stdout))
end

--- An error a program's main module does not catch ends it through the
--- core's own report: the message, then the guidance the carried error
--- catalog holds for the one it matches -- its symbol's doc comment,
--- carried with the row since the docs themselves are not.
local function test_an_uncaught_error_is_reported_with_its_guidance(tmp: string)
  assert(Fs.mkdirs(tmp .. "/cmd/boom"))
  assert(Fs.write(tmp .. "/cmd/boom/main.tl", [[
return function(): integer
  error("coverage collection is already active", 0)
end
]]))
  local names, trouble = embed.tree(tmp)
  assert(names ~= nil and names[1] == "boom", trouble)
  local r = run_program(tmp .. "/o/bin/boom")
  assert(r.code == 1, "exit " .. tostring(r.code))
  local err = assert(r.stderr)
  assert(err:find("cosmic: coverage collection is already active", 1, true),
    "the message is reported: " .. err)
  assert(err:find("Coverage.start (cosmic/coverage.tl:", 1, true),
    "and the guidance that matches it: " .. err)
end

--- A core started on its own, with no program inside and no tree to
--- boot, says so and exits rather than running anything.
local function test_a_bare_core_refuses_to_run(tmp: string)
  local core = assert(artifact.trusted_core())
  local path = tmp .. "/cosmic-core"
  assert(Fs.write(path, core.bytes, 0x1ed))
  local r = run_program(path)
  assert(r.code == 2, "exit " .. tostring(r.code))
  assert((assert(r.stderr)):find("no database attached", 1, true), tostring(r.stderr))
end
