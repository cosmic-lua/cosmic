--- Tests of [`build.syntax_derivation`]: the rows of a parse, read off the tree, that [`build.work`]'s tables hold.
local Ast = require("lang.ast")
local Derivation = require("build.syntax_derivation")
local Fs = require("cosmic.fs")
local Node = require("build.syntax_node")
local Sqlite = require("cosmic.sqlite")
local Test = require("cosmic.test")
local analysis_schema = require("build.analysis_schema")
local work = require("build.work")

--- The element of `list` at `index`, which the case knows is there.
local function nth<T>(list: {T}, index: integer): T
  local found = list[index]
  assert(found ~= nil, "the list has an element at " .. tostring(index))
  return found
end

Test.policy{}

local function parsed(source: string, name: string): Ast.Chunk
  local chunk, why = Node.parse(source, name)
  return (assert(chunk, why))
end

--- The first column of each row `statement` selects.
local function rows(db: Sqlite.Handle, statement: string): {string}
  local found, why = Sqlite.text_rows(db, statement)
  assert(found ~= nil, why)
  local out: mut {string} = {}
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
  local ok, why = Derivation.insert(handle.db, "h1", "m.tl", source, parsed(source, "m.tl"), false)
  assert(ok, why)
  assert(table.concat(rows(handle.db, "SELECT ordinal || '|' || name FROM requires ORDER BY ordinal"), " ") ==
      "1|cosmic.fs 2|build.types")
  assert(#rows(handle.db, "SELECT * FROM globals") == 0)
  local stubs = rows(handle.db, "SELECT source_hash || '|' || pruned FROM stubs")
  assert(#stubs == 1 and stubs[1] == "h1|1", table.concat(stubs, " "))
  assert(nth(rows(handle.db, "SELECT text FROM stubs"), 1):find("return Fs.size()", 1, true) == nil)
  assert(table.concat(rows(handle.db, "SELECT has_return || '|' || export FROM parsed"), " ") == "1|M")
  assert(work.close(handle))
end

local function test_a_source_that_returns_nothing_has_no_stub_and_a_declaration_file_has_its_globals(tmp: string)
  local handle = assert(work.open(tmp))
  local source = "global record Box\n  n: integer\nend\nglobal print: any\n"
  local ok, why = Derivation.insert(handle.db, "h2", "std.d.tl", source, parsed(source, "std.d.tl"), false)
  assert(ok, why)
  assert(table.concat(rows(handle.db, "SELECT ordinal || '|' || line || '|' || column FROM globals ORDER BY ordinal"),
    " ") == "1|1|1 2|4|1")
  assert(#rows(handle.db, "SELECT * FROM stubs") == 0)
  assert(work.close(handle))
  local quiet = "local x = 1\n"
  local found = assert(Derivation.rows_of(parsed(quiet, "t.tl"), quiet, "t.tl", false))
  assert(#found.requires == 0 and #found.globals == 0 and found.stub == nil and not found.analysis.has_top_level_return)
end

--- A module the tree writes in either grammar: documented functions, a record and an enum, catalog messages, a link to
--- a name it declares and to one it requires.
local MODULE <const> = table.concat({
  "--- A module of things.",
  "---",
  "--- See [`Things.open`] and [`Fs.read`].",
  'local Fs = require("cosmic.fs")',
  'local type Json = require("cosmic.json")',
  "",
  "--- A thing and its parts.",
  "local record Things",
  "  --- The size.",
  "  size: integer",
  "  --- What a thing is.",
  "  enum Kind",
  "    --- A plain one.",
  '    "plain"',
  '    "other"',
  "  end",
  "end",
  "",
  "--- Opens a thing: `Things.Kind` is how it reads.",
  "function Things.open(path: string, kind?: Things.Kind): Things, string",
  "  if path == \"\" then",
  "    return nil, \"path is empty: \" .. path",
  "  end",
  "  local text = Fs.read(path)",
  "  if text == nil then",
  "    return false, \"no such thing as that\"",
  "  end",
  "  return { size = #text }, \"\"",
  "end",
  "",
  "local function decode(text: string): Json.Value",
  "  return Json.decode(text)",
  "end",
  "",
  "--- Worked.",
  "function Example.open()",
  "  local thing = Things.open(\"x\")",
  "  assert(thing ~= nil)",
  "end",
  "",
  "return Things",
  "",
}, "\n")

--- A test module with a policy.
local TEST <const> = table.concat({
  'local Test = require("cosmic.test")',
  "",
  'Test.policy{ grants = { { path = "testdata", letters = "r" }, { path = "/cache/zig", letters = "rwxc" } },',
  '  loopback = { "127.0.0.1" }, env = { "HOME" }, promises = { "nest" } }',
  "",
  "local function test_it_works()",
  "  assert(true)",
  "end",
  "",
  "local function helper() end",
  "",
  "local function test_it_also_works()",
  "  helper()",
  "end",
  "",
}, "\n")

--- The text of every row of the analysis tables the database holds, one string for each table.
local function tables_of(db: Sqlite.Handle): {string: string}
  local out: mut {string: string} = {}
  for _, name in ipairs(analysis_schema.tables) do
    local found, why = Sqlite.rows(db, "SELECT * FROM " .. name .. " ORDER BY 1, 2")
    assert(found ~= nil, why)
    local lines: mut {string} = {}
    for _, row in ipairs(found) do
      local cells: mut {string} = {}
      for index = 2, row:count() do
        local kind = row:kind(index)
        local cell = "null"
        if kind == "integer" then
          cell = tostring(row:integer(index))
        elseif kind == "text" then
          cell = row:text(index)
        end
        cells[#cells + 1] = cell
      end
      lines[#lines + 1] = table.concat(cells, "\1")
    end
    out[name] = table.concat(lines, "\n")
  end
  return out
end

local function test_every_table_a_source_fills_gets_its_rows(tmp: string)
  for _, case in ipairs({ { "module.tl", MODULE, "m" }, { "t_test.tl", TEST, "t" } }) do
    local file, source = nth(case, 1), nth(case, 2)
    assert(Fs.mkdirs(tmp .. "/" .. nth(case, 3) .. "-port"))
    local port = assert(work.open(tmp .. "/" .. nth(case, 3) .. "-port"))
    local ok, why = Derivation.insert(port.db, "h", file, source, parsed(source, file), false)
    assert(ok, why)
    local new = tables_of(port.db)
    -- Each table the source fills is held, so that no table is empty where the source has rows for it.
    local filled: {string} = { "parsed", "tests", "test_inputs" }
    if case[3] == "m" then
      filled = { "parsed", "requires", "catalog", "docs", "refs", "bound", "examples", "links", "stubs", "places" }
    end
    for _, name in ipairs(filled) do
      local held = assert(new[name], file .. ": no table " .. name)
      assert(#held > 0, file .. ": nothing is written to " .. name)
    end
    assert(work.close(port))
  end
end

local function test_a_source_whose_policy_the_build_cannot_read_is_refused(tmp: string)
  local file = "t_test.tl"
  assert(Fs.mkdirs(tmp .. "/port"))
  local source = 'local Test = require("cosmic.test")\nTest.policy{ profiles = { "nobody" } }\n'
  local ok, why = Derivation.insert((assert(work.open(tmp .. "/port"))).db, "h", file, source, parsed(source, file),
    false)
  assert(not ok and why:find("profiles: no profile nobody", 1, true) ~= nil, why)
end

local function test_a_derived_source_keeps_its_symbols_at_the_lines_of_the_file_it_came_from_and_no_links()
  local source = table.concat({
    "-- line open 41",
    "--- Opens. See [`open`].",
    "local function open() end",
    "return open",
    "",
  }, "\n")
  local found = assert(Derivation.rows_of(parsed(source, "gen.tl"), source, "gen.tl", true))
  assert(#found.links == 0)
  assert(#found.analysis.docs == 1 and found.analysis.docs[1].line == 41, tostring(nth(found.analysis.docs, 1).line))
  local staged = assert(Derivation.rows_of(parsed(source, "gen.tl"), source, "gen.tl", false))
  assert(#staged.links == 1 and staged.links[1].link.target == "open")
  assert(nth(staged.analysis.docs, 1).line == 3)
end

local function test_the_types_and_members_a_source_declares_have_their_places_and_a_derived_source_has_none(tmp: string)
  local source = "local record Things\n  size: integer\nend\nfunction Things.open(): Things return { size = 0 } end\nreturn Things\n"
  local handle = assert(work.open(tmp))
  local ok, why = Derivation.insert(handle.db, "h1", "m.tl", source, parsed(source, "m.tl"), false)
  assert(ok, why)
  assert(table.concat(rows(handle.db,
    "SELECT ordinal || '|' || symbol || '|' || kind || '|' || line || '|' || column || '|' || length FROM places " ..
      "ORDER BY ordinal"), " ") == "1|Things|type|1|14|6 2|Things.size|field|2|3|4 3|Things.open|function|4|17|4")
  -- A source generated from another file is at that file's lines, which the places do not know.
  ok, why = Derivation.insert(handle.db, "h2", "gen.tl", source, parsed(source, "gen.tl"), true)
  assert(ok, why)
  assert(#rows(handle.db, "SELECT * FROM places WHERE source_hash = 'h2'") == 0)
  assert(#rows(handle.db, "SELECT * FROM parsed WHERE source_hash = 'h2'") == 1)
  assert(work.close(handle))
end
