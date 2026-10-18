--- Tests of [`build.syntax_derivation`]: the `requires`, `globals` and `stubs` rows of a parse, read off the tree.
local Ast = require("lang.ast")
local Derivation = require("build.syntax_derivation")
local Node = require("build.syntax_node")
local Sqlite = require("cosmic.sqlite")
local Test = require("cosmic.test")
local work = require("build.work")

Test.policy{}

local function parsed(source: string, name: string): Ast.Chunk
  local chunk, why = Node.parse(source, name)
  return (assert(chunk, why))
end

--- The first column of each row `statement` selects.
local function rows(db: Sqlite.Handle, statement: string): {string}
  local found, why = Sqlite.text_rows(db, statement)
  assert(found ~= nil, why)
  local out: {string} = {}
  for _, row in ipairs(found) do
    out[#out + 1] = row:text(1)
  end
  return out
end

local function test_a_source_that_returns_a_value_gets_its_requires_and_its_stub(tmp: string)
  local handle = assert(work.open(tmp))
  local source = table.concat({
    "local Fs = require(\"cosmic.fs\")",
    "local type T = require(\"build.types\")",
    "local record M",
    "  n: integer",
    "end",
    "function M.f(): integer return Fs.size() end",
    "return M",
    "",
  }, "\n")
  local ok, why = Derivation.insert(handle.db, "h1", "m.tl", parsed(source, "m.tl"))
  assert(ok, why)
  assert(table.concat(rows(handle.db, "SELECT ordinal || '|' || name FROM requires ORDER BY ordinal"), " ") ==
      "1|cosmic.fs 2|build.types")
  assert(#rows(handle.db, "SELECT * FROM globals") == 0)
  local stubs = rows(handle.db, "SELECT source_hash || '|' || pruned FROM stubs")
  assert(#stubs == 1 and stubs[1] == "h1|1", table.concat(stubs, " "))
  assert(rows(handle.db, "SELECT text FROM stubs")[1]:find("return Fs.size()", 1, true) == nil)
  assert(work.close(handle))
end

local function test_a_source_that_returns_nothing_has_no_stub_and_a_declaration_file_has_its_globals(tmp: string)
  local handle = assert(work.open(tmp))
  local ok, why = Derivation.insert(handle.db, "h2", "std.d.tl",
    parsed("global record Box\n  n: integer\nend\nglobal print: any\n", "std.d.tl"))
  assert(ok, why)
  assert(table.concat(rows(handle.db, "SELECT ordinal || '|' || line || '|' || column FROM globals ORDER BY ordinal"),
    " ") == "1|1|1 2|4|1")
  assert(#rows(handle.db, "SELECT * FROM stubs") == 0)
  assert(work.close(handle))
  local rows_of = Derivation.rows_of(parsed("local x = 1\n", "t.tl"))
  assert(#rows_of.requires == 0 and #rows_of.globals == 0 and rows_of.stub == nil)
end
