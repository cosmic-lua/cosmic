--- A tree with several binaries writes one database per binary, each
--- the tree's own with that binary's main named, and the tree's own
--- database names none.
local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local importer = require("build.importer")
local teal = require("build.teal")
local writer = require("build.writer")

local built, load_trouble = teal.load()
if built == nil then
  error("could not load the compiler: " .. tostring(load_trouble))
end

local main_source = "local function main(_argv: {integer:string}): integer\n" ..
  "  return 0\nend\nreturn main\n"

--- A project at `root` with a binary for every name in `names`.
local function write_project(root: string, names: {string})
  for _, name in ipairs(names) do
    local made, trouble = Fs.mkdirs(root .. "/cmd/" .. name)
    assert(made, tostring(trouble))
    local ok, failure = Fs.write(root .. "/cmd/" .. name .. "/main.tl", main_source)
    assert(ok, tostring(failure))
  end
end

local function compile(root: string): importer.Result
  local env, env_trouble = teal.environment_for(built, root)
  assert(env ~= nil, tostring(env_trouble))
  local result, trouble = importer.compile(root, built, env, "writer-test")
  assert(result ~= nil, "compile failed: " .. tostring(trouble))
  return result
end

--- One `SELECT` whose single row and column is text.
local function one(path: string, sql: string): string
  local handle, trouble = Sqlite.open(path, false)
  assert(handle ~= nil, path .. ": " .. tostring(trouble))
  local rows, rows_trouble = Sqlite.rows(handle, sql)
  handle:close()
  assert(rows ~= nil, path .. ": " .. tostring(rows_trouble))
  assert(#rows == 1, path .. ": expected one row, got " .. #rows)
  return rows[1][1]
end

local function main_of(path: string): string
  return one(path, "SELECT value FROM meta WHERE key = 'main'")
end

local function test_each_binary_database_names_its_own_main(tmp: string)
  write_project(tmp, { "serve", "admin" })
  local result = compile(tmp)
  local out = tmp .. "/o"
  local made, trouble = Fs.mkdirs(out)
  assert(made, tostring(trouble))
  local ok, failure = writer.write_result(out .. "/cosmic.db", result, {}, nil, {
    [out .. "/admin.db"] = "cmd.admin.main",
    [out .. "/serve.db"] = "cmd.serve.main",
  })
  assert(ok, tostring(failure))

  assert(main_of(out .. "/cosmic.db") == "",
    "the tree's database should name no main")
  assert(main_of(out .. "/admin.db") == "cmd.admin.main")
  assert(main_of(out .. "/serve.db") == "cmd.serve.main")

  -- Every binary carries the whole tree: the other binary's main too.
  local count = "SELECT count(*) FROM modules WHERE kind = 'main'"
  for _, name in ipairs({ "cosmic", "admin", "serve" }) do
    local path = out .. "/" .. name .. ".db"
    assert(one(path, count) == "2", path .. ": expected both mains")
  end
end

--- Writing the same result twice stores the vendored compiler once
--- each time: the write does not add its row to the caller's result.
local function test_a_result_can_be_written_twice(tmp: string)
  write_project(tmp, { "only" })
  local result = compile(tmp)
  local modules = #result.modules
  local teal_source = "return {}\n"
  for _, name in ipairs({ "first.db", "second.db" }) do
    local ok, failure =
      writer.write_result(tmp .. "/" .. name, result, {}, teal_source)
    assert(ok, tostring(failure))
  end
  assert(#result.modules == modules,
    "the write changed the result's modules: " .. #result.modules)
  local first = Fs.read(tmp .. "/first.db")
  local second = Fs.read(tmp .. "/second.db")
  assert(first ~= nil and first == second,
    "one result should write one file, byte for byte")
end
