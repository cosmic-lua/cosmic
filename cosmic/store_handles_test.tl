--- The cases of cosmic/store_test.tl that read the store beyond their
--- module's closure, through `Store.databases()`: the handles it hands
--- out, the binary's own database among them, and the binary's alone
--- inside `Store.alone` (cosmic/store_tool_test.tl starts this program).

local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local Test = require("cosmic.test")

--- `store`: `Store.databases()` hands handles to every module's rows.
Test.needs{ store = true }

--- A path is a filename, never a URI: one whose `vfs=` would pick a
--- VFS no capture observes names no file, and nothing is attached.
local function test_attaching_a_uri_is_refused(tmp: string)
  local path = tmp .. "/real.db"
  local db = assert(Sqlite.open(path, true))
  assert(db:exec("CREATE TABLE t (v TEXT)"))
  assert(db:close())
  local before = #Store.databases()
  assert(Store.attach(path))
  assert(#Store.databases() == before + 1)
  local ok, trouble = Store.attach("file:" .. path .. "?vfs=unix")
  assert(not ok, "attached a URI")
  assert(trouble ~= "")
  assert(#Store.databases() == before + 1)
end

--- The binary's own connection knows the functions every handle does,
--- so a query reads a module's deflated source back the way
--- `Store.source` does.
local function test_the_binary_s_database_inflates_its_source()
  local databases = Store.databases()
  local binary = databases[#databases]
  local rows = assert(Sqlite.text_rows(binary,
    "SELECT CAST(inflate(source) AS TEXT) FROM modules WHERE path = 'cosmic.store'"))
  assert(#rows == 1 and rows[1][1] == assert(Store.source("cosmic.store")),
    "the query and Store.source read the same text")
end

--- Asserts a call failed as a store handle's refusal does: nil or false,
--- and why.
local function refused(value: any, message: any)
  assert(value == nil or value == false, "not refused: " .. tostring(value))
  assert(message is string and message ~= "", "a refusal says why")
end

--- A borrowed handle on a store database reads, and nothing else: a
--- read-only open still leaves a connection a writable temp schema and
--- ATTACH, and a temp `modules` stands in front of the rows `require`
--- loads: a planted row would replace `cosmic.compress` for every later
--- require, and a temp view of that name would end the process at the
--- next one. Each is refused, and require is unaffected.
local function test_a_store_database_handle_only_reads()
  local databases = Store.databases()
  assert(#databases >= 1, "the store searches the binary's own database")
  for _, db in ipairs(databases) do
    refused(db:exec("CREATE TEMP TABLE modules (path TEXT, bytecode BLOB, kind TEXT)"))
    refused(db:exec("CREATE TEMP VIEW modules AS SELECT 1 AS path"))
    refused(db:exec("CREATE TEMP TRIGGER t AFTER INSERT ON meta BEGIN SELECT 1; END"))
    refused(db:exec("ATTACH DATABASE ':memory:' AS other"))
    refused(db:exec("INSERT INTO meta (key, value) VALUES ('planted', 'x')"))
    refused(db:exec("PRAGMA query_only = 0"))
    refused(db:exec("BEGIN"))
    local statement = assert(db:prepare("SELECT count(*) FROM modules"))
    assert(statement:step() == "row")
    statement:finalize()
  end
  local Compress = require("cosmic.compress")
  local packed = assert(Compress.deflate("zlib", "unaffected"))
  assert(Compress.inflate("zlib", packed, 10) == "unaffected")
  assert(Store.bytecode("cosmic.compress"))
end

--- Inside `alone` only the binary's own database is searched, nothing
--- can be attached or set aside again, and every database is back
--- after it, whether the function returned or raised.
local function test_alone_searches_only_the_binarys_own_database()
  local before = #Store.databases()
  assert(before >= 2, "a test's tree is attached ahead of the binary's")
  local inside = 0
  local attached, nested = true, true
  Store.alone(function()
    inside = #Store.databases()
    attached = pcall(Store.attach, "/nonexistent/cosmic.db")
    nested = pcall(Store.alone, function() end)
  end)
  assert(inside == 1, tostring(inside))
  assert(not attached and not nested)
  assert(#Store.databases() == before)
  local ok, trouble = pcall(function(): string
    Store.alone(function() error("boom", 0) end)
    return ""
  end)
  assert(not ok and trouble == "boom", tostring(trouble))
  assert(#Store.databases() == before)
  -- More results than a C function has free slots are dropped, not kept.
  local many = assert(load("local t = {} for i = 1, 100 do t[i] = i end " ..
    "return table.unpack(t)"))
  Store.alone(many)
  assert(#Store.databases() == before)
  assert(Store.meta("compiler") ~= nil)
end
