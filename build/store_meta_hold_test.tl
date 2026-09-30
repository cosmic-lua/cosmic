--- A test worker holds [`Store.meta`] to the rows its test's key holds
--- ([`build.test_worker`]'s `held_meta`, core/store.c's `meta_reach`):
--- the runtime's and those a closure store keeps answer, while a row of
--- the running tool's own or of the whole projection -- `projected`,
--- which moves with every edit to a module -- raises, naming `store`,
--- which this module does not declare. Nor does its closure hold a
--- module that reads the compiler's identity, so that is held too.
--- Without the hold such a read answers from a database no key of this
--- module's tests holds, and a verdict could stand on it after the row
--- changed.

local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")

--- Asserts `lookup` of `key` raised, saying why and naming `fix`.
local function held(key: string, fix: string, lookup?: function(string): string | nil)
  local ok, why = pcall(lookup or Store.meta, key)
  local text = tostring(why)
  assert(not ok, "read meta " .. key .. " past the hold: " .. text)
  assert(text:find("Store.meta of \"" .. key .. "\" is held", 1, true), text)
  assert(text:find("build.store_meta_hold_test's verdict is keyed", 1, true), text)
  assert(text:find(fix, 1, true), text)
  assert(text:find("declare store = true", 1, true) or text:find("Declare store = true", 1, true),
    text)
end

local function test_a_row_no_key_holds_is_held()
  for _, key in ipairs({ "projected", "writer", "written_by", "no such key" }) do
    held(key, "neither holds that row")
  end
end

local function test_the_compiler_is_held_from_a_closure_that_reads_none()
  for _, key in ipairs({ "compiler", "compiled_by" }) do
    held(key, "`compiler_readers`")
  end
end

--- What the runtime identity names, and what a closure store keeps, are
--- read as ever.
local function test_the_runtime_and_the_closure_rows_are_read()
  for _, key in ipairs({ "runtime_basis", "runtime", "host", "host_image",
                          "runtime_context", "artifact", "image_hash", "main", "boot_hash" }) do
    local ok, why = pcall(Store.meta, key)
    assert(ok, "meta " .. key .. " is held: " .. tostring(why))
  end
  assert(Store.meta("runtime_basis") ~= nil, "the program carries its runtime basis")
end

--- A database the test attached itself, keyed by what it declares it
--- reads, answers a row the hold covers the others' of; a row it does
--- not hold is held as ever.
local function test_a_database_the_test_attached_answers_a_held_row(tmp: string)
  local path = tmp .. "/own.db"
  local db = assert(Sqlite.open(path, true))
  assert(db:exec("CREATE TABLE meta (key TEXT, value TEXT); " ..
    "INSERT INTO meta VALUES ('projected', 'mine')"))
  assert(db:close())
  assert(Store.attach(path))
  assert(Store.meta("projected") == "mine", "the test's own database answers")
  held("writer", "neither holds that row")
end

local type Searcher = function(string): any, any

--- Reached past [`cosmic.store`], the raw table's lookup is held as the
--- wrapper's is.
local function test_the_raw_table_is_held_too()
  for _, searcher in ipairs(package.searchers as {Searcher}) do
    local loader, extra = searcher("cosmic.store")
    if loader is function(string, any): any and extra is {string:any} then
      held("projected", "neither holds that row", extra.meta as function(string): string | nil)
      return
    end
  end
  error("cosmic.store is handed no raw table")
end
