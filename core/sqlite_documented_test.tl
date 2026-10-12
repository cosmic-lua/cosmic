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

--- The names the guide documents: each list item that opens with a name
--- in backticks, the name ending at `(` or the closing backtick. Case is
--- folded, as SQLite folds it.
local function documented(): {string:boolean}
  local text = assert(Fs.read(GUIDE))
  local names: {string:boolean} = {}
  for name in text:gmatch("\n%- `([^`(]+)") do names[name:lower()] = true end
  return names
end

--- The names a fresh handle answers. `json_each` and `json_tree`, like
--- the PRAGMA tables, are registered when first used, so each is used
--- before the modules are listed.
local function answered(): {string:boolean}
  local handle = assert(Sqlite.memory())
  for _, sql in ipairs({ "SELECT * FROM json_each('[]')", "SELECT * FROM json_tree('[]')" }) do
    assert(Sqlite.text_rows(handle, sql))
  end
  local names: {string:boolean} = {}
  for _, sql in ipairs({ "SELECT name FROM pragma_function_list",
      "SELECT name FROM pragma_module_list", "SELECT name FROM pragma_collation_list" }) do
    local rows = assert(Sqlite.text_rows(handle, sql))
    for _, row in ipairs(rows) do
      local name = row[1]:lower()
      names[name:find("^pragma_") and PRAGMAS or name] = true
    end
  end
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
  for _, name in ipairs({ "abs", "->>", "json_each", "binary", "decimal", PRAGMAS }) do
    assert(names[name], "the guide's entries do not include " .. name)
  end
  assert(not names["sqlite"], "prose in backticks outside an entry is not one")
end
