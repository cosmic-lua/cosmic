--- Proves `cosmic embed` writes an executable for a project: the tree
--- is a fixture under a fresh temp directory, shaped as a binary is --
--- `cmd/<name>/main.tl` and a module beside it -- and the database the
--- executable carries is read back and checked for what a program
--- needs at run time and nothing it does not.

local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local embed = require("build.embed")

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
  local rows = assert(Sqlite.rows(db, sql))
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
  local head = assert(Fs.read(out)):sub(1, 4)
  assert(head == "\127ELF" or head == "\207\250\237\254",
    "the file opens as the host's own image")
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
  assert(meta["host"] ~= nil and meta["host"] ~= "", "the host is named")

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
  local images = rows_of(path, "SELECT count(*) FROM images")
  assert(images[1][1] == "0", "no core image: a program is not a builder")
  local guidance = rows_of(path,
    "SELECT count(*) FROM catalog_fts WHERE catalog_fts MATCH 'file'")
  assert(tonumber(guidance[1][1]) > 0, "the error catalog is in, and indexed")
end

local function test_a_tree_without_a_main_is_refused(tmp: string)
  assert(Fs.write(tmp .. "/greet.tl", greet_source))
  local names, trouble = embed.tree(tmp)
  assert(names == nil)
  assert(trouble:find("cmd/<name>/main.tl", 1, true) ~= nil, trouble)
end

local function test_cosmic_s_own_tree_is_refused(tmp: string)
  assert(Fs.mkdirs(tmp .. "/core"))
  assert(Fs.mkdirs(tmp .. "/build"))
  assert(Fs.write(tmp .. "/build/importer.tl", "return {}\n"))
  local names, trouble = embed.tree(tmp)
  assert(names == nil)
  assert(trouble:find("bin/zig build boot", 1, true) ~= nil, trouble)
end
