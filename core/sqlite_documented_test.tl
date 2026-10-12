--- doc/guides/sql.md lists every SQL function, table-valued function,
--- virtual table and collation a handle answers, and nothing a handle
--- does not: a flag, an extension or a function of cosmic's own that
--- reaches SQL fails here until the guide names it.

local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local Test = require("cosmic.test")

Test.policy{
  profiles = { "cosmic" },
  grants = { { path = "doc/guides/sql.md", letters = "r" } },
}

local GUIDE <const> = "doc/guides/sql.md"

--- Every PRAGMA that answers rows is a table-valued function of its own
--- name, registered when first used: the guide names them as one entry.
local PRAGMAS <const> = "pragma_*"

--- A collation's name stands apart from a function's: `decimal` is
--- both, and each needs its own entry.
local function collation(name: string): string return "collation " .. name end

--- The names the guide documents: each list item that opens with a name
--- in backticks, the name ending at `(` or the closing backtick, and
--- those under its collations heading as collations. Case is folded, as
--- SQLite folds it.
local function documented(): {string:boolean}
  local text = "\n" .. assert(Fs.read(GUIDE))
  local names: {string:boolean} = {}
  local from, to = 0, #text + 1
  for heading_at, heading in text:gmatch("()\n## ([^\n]*)") do
    if from > 0 and to > #text then to = heading_at as integer end
    if heading == "collations" then from = heading_at as integer end
  end
  assert(from > 0, GUIDE .. " has no collations heading")
  for where, name in text:gmatch("\n%- `()([^`(]+)") do
    local in_collations = (where as integer) > from and (where as integer) < to
    names[in_collations and collation(name:lower()) or name:lower()] = true
  end
  return names
end

--- The table-valued functions SQLite registers when first used
--- (sqlite3JsonVtabRegister and sqlite3CarrayRegister in its source),
--- like the PRAGMA tables: each is used before the modules are listed.
local LAZY_TABLES <const> = { "json_each", "json_tree", "jsonb_each", "jsonb_tree", "carray" }

--- The names a fresh handle answers.
local function answered(): {string:boolean}
  local handle = assert(Sqlite.memory())
  for _, name in ipairs(LAZY_TABLES) do
    assert(Sqlite.text_rows(handle, "SELECT * FROM " .. name .. "('[]')"))
  end
  local names: {string:boolean} = {}
  for _, sql in ipairs({ "SELECT name FROM pragma_function_list",
      "SELECT name FROM pragma_module_list" }) do
    local rows = assert(Sqlite.text_rows(handle, sql))
    for _, row in ipairs(rows) do
      local name = row[1]:lower()
      names[name:find("^pragma_") and PRAGMAS or name] = true
    end
  end
  local rows = assert(Sqlite.text_rows(handle, "SELECT name FROM pragma_collation_list"))
  for _, row in ipairs(rows) do names[collation(row[1]:lower())] = true end
  handle:close()
  return names
end

--- The names in `want` that `have` lacks, sorted, one to a line.
local function missing(want: {string:boolean}, have: {string:boolean}): string
  local out: {string} = {}
  for name in pairs(want) do
    if not have[name] then out[#out + 1] = name end
  end
  table.sort(out)
  return table.concat(out, "\n  ")
end

local function test_every_name_a_handle_answers_is_documented()
  local gap = missing(answered(), documented())
  assert(gap == "", GUIDE .. " does not list what a handle answers:\n  " .. gap)
end

local function test_every_documented_name_is_answered()
  local gap = missing(documented(), answered())
  assert(gap == "", GUIDE .. " lists what no handle answers:\n  " .. gap)
end

local function test_the_guide_is_read_as_its_entries()
  local names = documented()
  for _, name in ipairs({ "abs", "->>", "jsonb_each", "decimal", collation("binary"),
      collation("decimal"), PRAGMAS }) do
    assert(names[name], "the guide's entries do not include " .. name)
  end
  assert(not names["binary"], "a collation is read as a collation")
  assert(not names["sqlite"], "prose in backticks outside an entry is not one")
end
