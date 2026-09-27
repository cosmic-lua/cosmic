--- Every module of the tree that reads the compiler's identity through
--- `Store.meta` is one `build.declared_key`'s `compiler_readers` names:
--- a closure store carries no such row (`build.writer`), so a worker's
--- read of it is answered by the running tool, and only a test whose
--- closure holds a named reader is keyed by the tool's identity. A
--- reader the list misses would leave a verdict standing that turned on
--- a compiler no key held.

local Sqlite = require("cosmic.sqlite")
local Test = require("cosmic.test")
local declared_key = require("build.declared_key")

--- A whole-tree question, asked of the projection itself.
Test.needs{ store = true }

--- Whether `line` reads the compiler's identity, or a `meta` row by a
--- name no reader can see: `Store.meta` called with anything but a
--- string.
local function reads(line: string): boolean
  for _, name in ipairs({ "compiler", "compiled_by" }) do
    for _, quote in ipairs({ '"', "'" }) do
      if line:find("meta%(%s*" .. quote .. name .. quote .. "%s*%)") ~= nil then return true end
    end
  end
  return line:find("Store%.meta%(%s*[^\"'%s]") ~= nil and line:find("^%s*function ") == nil
end

--- Each module of the projection `db` a line of whose source `reads`.
local function readers(db: Sqlite.Handle): {string:boolean}
  local rows = assert(Sqlite.text_rows(db,
    "SELECT path, CAST(inflate(source) AS TEXT) FROM modules ORDER BY path"))
  local found: {string:boolean} = {}
  for _, row in ipairs(rows) do
    for line in (row[2] .. "\n"):gmatch("([^\n]*)\n") do
      if reads(line) then
        found[row[1]] = true
        break
      end
    end
  end
  return found
end

--- Spelled apart, so this module's own source reads nothing.
local function test_a_read_of_the_compiler_is_seen()
  local call = "Store.meta"
  assert(reads("  local tool = " .. call .. '("compiler") or ""'))
  assert(reads("local by = " .. call .. "( 'compiled_by' )"))
  assert(reads("local value = " .. call .. "(key)"))
  assert(not reads("function " .. call .. "(key: string): string | nil"))
  assert(not reads("local runtime = " .. call .. '("runtime")'))
end

--- The tree's own readers, read from the projection the build wrote
--- before any test ran: every one is named, and every name still reads.
local function test_every_reader_of_the_compiler_is_named()
  local db = assert(Sqlite.open("o/cosmic.db", false))
  local found = readers(db)
  assert(db:close())
  local named: {string:boolean} = {}
  for _, name in ipairs(declared_key.compiler_readers) do named[name] = true end
  local missing, stale: {string}, {string} = {}, {}
  for name in pairs(found) do
    if not named[name] then missing[#missing + 1] = name end
  end
  for name in pairs(named) do
    if not found[name] then stale[#stale + 1] = name end
  end
  table.sort(missing)
  table.sort(stale)
  assert(#missing == 0, "read the compiler's identity, but build/declared_key.tl's " ..
    "`compiler_readers` does not name them, so no key of a test that runs them holds it: " ..
    table.concat(missing, ", "))
  assert(#stale == 0, "named in build/declared_key.tl's `compiler_readers`, but no " ..
    "longer read the compiler's identity -- remove them: " .. table.concat(stale, ", "))
end
