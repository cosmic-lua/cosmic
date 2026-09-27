--- End to end: a parse one checkout of a project made stands in another
--- checkout of the same content, through the cache `COSMIC_BUILD_CACHE`
--- names, and lands there as the parse would have, a doc's lines mapped
--- or not as the source's origin says; an edit parses only what it
--- edited; a damaged row is parsed again and replaced; and a boot, whose
--- analyzer is named by the tree it has yet to parse, takes the parses
--- of the analyzer the tree names and of no other.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local observations = require("build.filesystem_observations")
local importer = require("build.importer")
local shared_compiles = require("build.shared_compiles")
local teal = require("build.teal")
local Test = require("cosmic.test")
local work = require("build.work")

--- The program itself, which its tests start.
Test.needs{ tool = true }

local built, load_trouble = teal.load()
if built == nil then
  error("could not load the compiler: " .. tostring(load_trouble))
end

--- The tables a parse fills (`build.importer`'s `analysis_tables`).
local parse_tables: {string} = {
  "parsed", "requires", "tests", "catalog", "docs", "refs", "examples", "test_inputs",
}

--- The project every case builds: `a` requires `b`, which requires
--- `c`; `c` documents a record and its field, `b` reads that field, and
--- the guide is extracted to a test module whose example's line is the
--- guide's own (`build.importer`'s `origin_lines`).
local project: {string:string} = {
  ["c.tl"] = [[
--- Boxes.
local record c
  --- A box.
  record Box
    --- What it holds.
    value: integer
  end
end

--- A box of `value`.
function c.new(value: integer): c.Box
  return { value = value }
end

return c
]],
  ["b.tl"] = [[
local c = require("c")

local record b end

--- Twice `value`, by way of a box.
function b.twice(value: integer): integer
  local box = c.new(value)
  return box.value * 2
end

return b
]],
  ["a.tl"] = [[
local b = require("b")

local record a end

function a.four(): integer
  return b.twice(2)
end

return a
]],
  ["doc/guides/guide.md"] = [[
# guide

An example the build compiles and never runs, having no output.

```teal
print(42)
```
]],
}

--- A checkout of the project at `root`, with `changed` written over it
--- (a file to "" is left out).
local function checkout(root: string, changed?: {string:string})
  local files: {string:string} = {}
  for name, source in pairs(project) do files[name] = source end
  for name, source in pairs(changed or {}) do files[name] = source end
  for name, source in pairs(files) do
    if source ~= "" then
      assert(Fs.mkdirs(Fs.dirname(root .. "/" .. name)))
      assert(Fs.write(root .. "/" .. name, source))
    end
  end
end

--- Builds the checkout at `root` (`cosmic test`, which has nothing to
--- run), answering what it printed.
local function build(root: string, env: {string:string}): string
  local output = root .. ".out"
  local fd = assert(Fs.open_write(output))
  local started = observations.program({ "test" }, {
    cwd = root, env = env, stdout = fd, stderr = fd,
    process_group = true, timeout_ms = 60000,
  })
  local result, trouble = Child.run(started.argv, started.options)
  assert(Fs.close(fd))
  local text = assert(Fs.read(output))
  assert(result ~= nil and result.ok, tostring(trouble) .. text)
  return text
end

--- The environment the builds of a case run in, sharing through a
--- cache in `tmp`, and where that cache is.
local function environment(tmp: string): {string:string}, string
  local env = observations.environment()
  local path = tmp .. "/cache/cache.db"
  env.COSMIC_BUILD_CACHE = path
  env.COSMIC_TEST_ALL = nil
  env.COSMIC_SANDBOX = nil
  return env, path
end

--- Builds `root` and checks its build line says `wanted`.
local function built_as(root: string, env: {string:string}, wanted: string): string
  local text = build(root, env)
  assert(text:find(wanted, 1, true), wanted .. "\n" .. text)
  return text
end

--- Every row `sql` answers of the database at `path`, a line each.
local function dump(path: string, sql: string): string
  local db = assert(Sqlite.open(path, false))
  local rows = assert(Sqlite.text_rows(db, sql))
  assert(db:close())
  local lines: {string} = {}
  for _, row in ipairs(rows) do lines[#lines + 1] = table.concat(row, "\t") end
  return table.concat(lines, "\n")
end

--- Every row of every parse table of the working database `db`.
local function parse_rows(db: Sqlite.Handle): string
  local out: {string} = {}
  for _, name in ipairs(parse_tables) do
    local rows = assert(Sqlite.text_rows(db, "SELECT * FROM " .. name .. " ORDER BY 1, 2"))
    out[#out + 1] = name .. " " .. #rows
    for _, row in ipairs(rows) do out[#out + 1] = table.concat(row, "\t") end
  end
  return table.concat(out, "\n")
end

--- `parse_rows` of the checkout at `root`.
local function parse_rows_of(root: string): string
  local db = assert(Sqlite.open(root .. "/o/build.db", false))
  local out = parse_rows(db)
  assert(db:close())
  return out
end

--- The line `cosmic docs` gives `symbol` of the checkout at `root`.
local function doc_line(root: string, symbol: string): string
  return dump(root .. "/o/build.db", "SELECT d.line FROM docs d JOIN inputs i " ..
    "ON i.source_hash = d.source_hash WHERE d.symbol = '" .. symbol .. "'")
end

local function test_a_second_checkout_parses_nothing_the_first_parsed(tmp: string)
  tmp = assert(Fs.absolute(tmp))
  local env = environment(tmp)
  checkout(tmp .. "/first")
  built_as(tmp .. "/first", env, "(4 compiled, 0 cached; 4 sources parsed;")
  checkout(tmp .. "/second")
  built_as(tmp .. "/second", env, "(0 compiled, 4 cached, 4 of them taken from another " ..
    "checkout; 0 sources parsed, 4 taken from another checkout;")
  -- What each checkout keeps of a parse, and what its projection makes
  -- of it -- docs, uses, the catalog, examples, tests -- are the same.
  local first, second = parse_rows_of(tmp .. "/first"), parse_rows_of(tmp .. "/second")
  assert(first:find("docs 0", 1, true) == nil and first == second, first .. "\n--\n" .. second)
  local projection: {string} = {
    "SELECT path, file, kind, hex(source_hash), hex(key), tests FROM modules ORDER BY path",
    "SELECT * FROM docs ORDER BY 1, 2, 3",
    "SELECT * FROM uses ORDER BY 1, 2, 3, 4, 5",
    "SELECT * FROM catalog ORDER BY 1, 2, 3",
    "SELECT * FROM examples ORDER BY 1, 2, 3",
    "SELECT * FROM imports ORDER BY 1, 2",
  }
  for _, query in ipairs(projection) do
    local one = dump(tmp .. "/first/o/cosmic.db", query)
    local other = dump(tmp .. "/second/o/cosmic.db", query)
    assert(one == other, query .. "\n" .. one .. "\n--\n" .. other)
  end
  assert(dump(tmp .. "/second/o/cosmic.db", "SELECT count(*) FROM docs") ~= "0")
  -- The guide's example is at its line in the guide.
  assert(doc_line(tmp .. "/second", "example_1") == "5", doc_line(tmp .. "/second", "example_1"))
  -- Its own now: a build again takes nothing, and parses nothing.
  local again = built_as(tmp .. "/second", env, "(0 compiled, 4 cached;")
  assert(not again:find("another checkout", 1, true) and not again:find("parsed", 1, true), again)
end

local function test_an_edit_parses_only_what_it_edited(tmp: string)
  tmp = assert(Fs.absolute(tmp))
  local env = environment(tmp)
  checkout(tmp .. "/first")
  built_as(tmp .. "/first", env, "4 sources parsed;")
  checkout(tmp .. "/edited", { ["c.tl"] = project["c.tl"] .. "-- edited\n" })
  built_as(tmp .. "/edited", env, "; 1 sources parsed, 3 taken from another checkout;")
end

--- The same source parsed from a doc and from the tree is two parses:
--- a doc's lines are mapped to the doc, a tree file's are its own.
local function test_a_mapped_parse_stands_only_for_a_mapped_one(tmp: string)
  tmp = assert(Fs.absolute(tmp))
  local env, path = environment(tmp)
  checkout(tmp .. "/doc")
  built_as(tmp .. "/doc", env, "4 sources parsed;")
  local generated = dump(tmp .. "/doc/o/build.db",
    "SELECT source FROM derived WHERE file = 'doc/guides/guide.md'")
  local own_line = 0
  local number = 0
  for line in (generated .. "\n"):gmatch("([^\n]*)\n") do
    number = number + 1
    if line:find("^local function example_1") then own_line = number end
  end
  assert(own_line > 0 and own_line ~= 5, generated)
  -- The generated source as a file of the tree, the guide gone: the
  -- same source, parsed again, as its own lines stand; the rest taken.
  local plain = { ["doc/guides/guide.md"] = "", ["guide_test.tl"] = generated }
  checkout(tmp .. "/plain", plain)
  built_as(tmp .. "/plain", env, "; 1 sources parsed, 3 taken from another checkout;")
  assert(doc_line(tmp .. "/plain", "example_1") == tostring(own_line),
    doc_line(tmp .. "/plain", "example_1") .. " " .. own_line)
  local rows = dump(path, "SELECT mapped, count(*) FROM parsed_v1 GROUP BY mapped ORDER BY mapped")
  assert(rows == "0\t4\n1\t1", rows)
  -- Each stands for its own.
  checkout(tmp .. "/plain_again", plain)
  built_as(tmp .. "/plain_again", env, "; 0 sources parsed, 4 taken from another checkout;")
  assert(doc_line(tmp .. "/plain_again", "example_1") == tostring(own_line))
  checkout(tmp .. "/doc_again")
  built_as(tmp .. "/doc_again", env, "; 0 sources parsed, 4 taken from another checkout;")
  assert(doc_line(tmp .. "/doc_again", "example_1") == "5")
end

--- A row that does not decode to what its digest says is a miss: the
--- source is parsed, the rest are still taken, and the row is replaced.
local function test_a_damaged_parse_is_parsed_again_and_replaced(tmp: string)
  tmp = assert(Fs.absolute(tmp))
  local env, path = environment(tmp)
  checkout(tmp .. "/first")
  built_as(tmp .. "/first", env, "4 sources parsed;")
  local c_hash = dump(tmp .. "/first/o/build.db", "SELECT source_hash FROM inputs WHERE path = 'c'")
  local b_hash = dump(tmp .. "/first/o/build.db", "SELECT source_hash FROM inputs WHERE path = 'b'")
  local cache = assert(Sqlite.open(path, true))
  -- `b`'s rows another source's, `c`'s no stream at all.
  assert(Sqlite.run(cache, "UPDATE parsed_v1 SET rows = (SELECT rows FROM parsed_v1 " ..
    "WHERE source_hash = ?2) WHERE source_hash = ?1", { { text = b_hash }, { text = c_hash } }))
  assert(Sqlite.run(cache, "UPDATE parsed_v1 SET rows = x'deadbeef' WHERE source_hash = ?1",
    { { text = c_hash } }))
  assert(cache:close())
  checkout(tmp .. "/second")
  local second = built_as(tmp .. "/second", env, "; 2 sources parsed, 2 taken from another checkout;")
  assert(not second:find("shared compiles: ", 1, true), second)
  assert(parse_rows_of(tmp .. "/first") == parse_rows_of(tmp .. "/second"))
  checkout(tmp .. "/third")
  built_as(tmp .. "/third", env, "; 0 sources parsed, 4 taken from another checkout;")
end

local function test_the_cache_turned_off_shares_no_parse(tmp: string)
  tmp = assert(Fs.absolute(tmp))
  local env = environment(tmp)
  env.COSMIC_BUILD_CACHE = "0"
  checkout(tmp .. "/first")
  built_as(tmp .. "/first", env, "(4 compiled, 0 cached; 4 sources parsed;")
  checkout(tmp .. "/second")
  built_as(tmp .. "/second", env, "(4 compiled, 0 cached; 4 sources parsed;")
  assert(Fs.stat(tmp .. "/cache") == nil, "a cache turned off was written")
end

--- The tree a boot case derives: `build.importer` and the analyzer
--- modules it names (`build.analyzer`, `build.ast`), what they reach
--- (`build.thing`, `build.helper`, the declaration `build.raw`), and a
--- module no analyzer module reaches.
local analyzer_tree: {string:string} = {
  ["build/helper.tl"] = "local record helper\n  n: integer\nend\nhelper.n = 1\nreturn helper\n",
  ["build/importer.tl"] = "local helper = require(\"build.helper\")\n" ..
    "local record importer\n  n: integer\nend\nimporter.n = helper.n\nreturn importer\n",
  ["build/analyzer.tl"] = "local ast = require(\"build.ast\")\n" ..
    "local thing = require(\"build.thing\")\n--- The analyzer.\n" ..
    "local record analyzer\n  n: integer\nend\nanalyzer.n = ast.n + thing.n\nreturn analyzer\n",
  ["build/ast.tl"] = "local raw = require(\"build.raw\")\n" ..
    "local record ast\n  n: integer\nend\nast.n = raw.n\nreturn ast\n",
  ["build/thing.tl"] = "local record thing\n  n: integer\nend\nthing.n = 2\nreturn thing\n",
  ["build/raw.d.tl"] = "local record raw\n  n: integer\nend\nreturn raw\n",
  ["build/other.tl"] = "--- Other.\nlocal record other\n  n: integer\nend\nother.n = 3\n" ..
    "return other\n",
}

--- What a boot of the tree at `root` derives, sharing through the cache
--- at `path` ("0" for none): what it parsed, the analyzer it recorded,
--- and every row of every parse table. Run as a boot runs, with no
--- `boot_hash`, which the suite's binary carries, so `Store.meta` is
--- stood in for across the derive.
local function boot(root: string, path: string): importer.Parses, string, string
  local handle = assert(work.open(root))
  assert(work.stage(handle, true))
  local shared = shared_compiles.for_build({ COSMIC_BUILD_CACHE = path })
  local meta = Store.meta
  Store.meta = function(key: string): string | nil
    if key == "boot_hash" then return nil end
    return meta(key)
  end
  local ok, parses, trouble = pcall(importer.derive, handle, true, built, shared)
  Store.meta = meta
  if shared ~= nil then shared.finish() end
  assert(ok, tostring(parses))
  assert(parses ~= nil, trouble)
  local recorded = assert(Sqlite.text_rows(handle.db,
    "SELECT value FROM meta WHERE key = 'analyzer'"))
  local rows = parse_rows(handle.db)
  work.close(handle)
  return parses, recorded[1][1], rows
end

--- A tree like `analyzer_tree` at `root`, with `changed` written over it.
local function analyzer_checkout(root: string, changed?: {string:string})
  for _, dir in ipairs({ "build", "core" }) do assert(Fs.mkdirs(root .. "/" .. dir)) end
  local files: {string:string} = {}
  for name, source in pairs(analyzer_tree) do files[name] = source end
  for name, source in pairs(changed or {}) do files[name] = source end
  for name, source in pairs(files) do assert(Fs.write(root .. "/" .. name, source)) end
end

--- A boot's fixed point: a boot names its analyzer by the `requires`
--- rows of the very parse it is to take, so it takes an analyzer's
--- parses only where the rows that analyzer found name it again, here.
--- One whose analyzer modules are this tree's takes them all; one
--- whose analyzer reaches a module this tree holds otherwise, or whose
--- `requires` rows lead elsewhere, is declined, and the tree parsed.
local function test_a_boot_takes_only_the_parses_its_own_analyzer_made(tmp: string)
  tmp = assert(Fs.absolute(tmp))
  local path = tmp .. "/cache/cache.db"
  local count = 0
  for _ in pairs(analyzer_tree) do count = count + 1 end
  analyzer_checkout(tmp .. "/first")
  local parses, named, rows = boot(tmp .. "/first", path)
  assert(parses.parsed == count and parses.shared == 0, parses.parsed .. " " .. parses.shared)
  -- The same tree elsewhere: every parse taken, and the same rows.
  analyzer_checkout(tmp .. "/second")
  local taken, taken_named, taken_rows = boot(tmp .. "/second", path)
  assert(taken.parsed == 0 and taken.shared == count, taken.parsed .. " " .. taken.shared)
  assert(taken_named == named and taken_rows == rows, taken_rows .. "\n--\n" .. rows)
  -- An analyzer module edited that no root is: the roots' parses are
  -- the cache's, but the rows they name the analyzer by reach the edit,
  -- so the name is another, and nothing is taken.
  local edited = { ["build/thing.tl"] = analyzer_tree["build/thing.tl"] .. "-- edited\n" }
  analyzer_checkout(tmp .. "/edited", edited)
  local declined, declined_named, declined_rows = boot(tmp .. "/edited", path)
  assert(declined.parsed == count and declined.shared == 0,
    declined.parsed .. " " .. declined.shared)
  analyzer_checkout(tmp .. "/edited_alone", edited)
  local _, alone_named, alone_rows = boot(tmp .. "/edited_alone", "0")
  assert(declined_named ~= named and declined_named == alone_named and
    declined_rows == alone_rows, "a declined analyzer's parse differs from one made alone")
  -- The first tree's analyzer again, but the cache's `requires` of
  -- build.analyzer leave build.thing out: the name those rows give is
  -- not the analyzer's, so it is declined, the tree parsed, and the
  -- row made here replaces the one that led astray.
  local analyzer_hash = rows:match("\n([0-9a-f]+)\t1\tbuild%.ast\n")
  assert(analyzer_hash ~= nil, rows)
  local cache = assert(Sqlite.open(path, true))
  assert(Sqlite.run(cache, "UPDATE parsed_v1 SET requires = 'build.ast\n' " ..
    "WHERE analyzer = ?1 AND source_hash = ?2", { { text = named }, { text = analyzer_hash } }))
  assert(cache:close())
  assert(dump(path, "SELECT count(*) FROM parsed_v1 WHERE requires = 'build.ast\n'") == "1")
  analyzer_checkout(tmp .. "/misled")
  local misled, misled_named, misled_rows = boot(tmp .. "/misled", path)
  assert(misled.parsed == count and misled.shared == 0, misled.parsed .. " " .. misled.shared)
  assert(misled_named == named and misled_rows == rows)
  analyzer_checkout(tmp .. "/mended")
  local mended = boot(tmp .. "/mended", path)
  assert(mended.parsed == 0 and mended.shared == count, mended.parsed .. " " .. mended.shared)
end

--- A guess can accept an analyzer that is not the tree's: here the
--- cache's parse of build.analyzer, damaged, leaves out a require of
--- build.extra, a module the first tree lacked, so the rows it guesses
--- by name the first tree's analyzer over a tree that has it. The
--- damaged row fails its digest and is parsed here, which finds the
--- require, so the name after the parse is not the one taken: every
--- row is forgotten and the tree parsed afresh, with nothing taken, and
--- the count says so.
local function test_a_taken_analyzer_the_parse_moves_is_parsed_afresh(tmp: string)
  tmp = assert(Fs.absolute(tmp))
  local path = tmp .. "/cache/cache.db"
  local reaching: {string:string} = { ["build/analyzer.tl"] = "local ast = require(\"build.ast\")\n" ..
    "local thing = require(\"build.thing\")\nlocal extra = require(\"build.extra\")\n" ..
    "--- The analyzer.\nlocal record analyzer\n  n: integer\nend\n" ..
    "analyzer.n = ast.n + thing.n + extra.n\nreturn analyzer\n" }
  analyzer_checkout(tmp .. "/lacking", reaching)
  local _, lacking_named, lacking_rows = boot(tmp .. "/lacking", path)
  local having: {string:string} = {
    ["build/extra.tl"] = "local record extra\n  n: integer\nend\nextra.n = 4\nreturn extra\n",
  }
  for name, source in pairs(reaching) do having[name] = source end
  analyzer_checkout(tmp .. "/having", having)
  local _, having_named, having_rows = boot(tmp .. "/having", path)
  assert(having_named ~= lacking_named)
  local analyzer_hash = lacking_rows:match("\n([0-9a-f]+)\t3\tbuild%.extra\n")
  assert(analyzer_hash ~= nil, lacking_rows)
  local cache = assert(Sqlite.open(path, true))
  assert(Sqlite.run(cache, "UPDATE parsed_v1 SET requires = 'build.ast\nbuild.thing\n' " ..
    "WHERE analyzer = ?1 AND source_hash = ?2",
    { { text = lacking_named }, { text = analyzer_hash } }))
  assert(Sqlite.run(cache, "DELETE FROM parsed_v1 WHERE analyzer = ?1", { { text = having_named } }))
  assert(cache:close())
  local count = 0
  for _ in pairs(analyzer_tree) do count = count + 1 end
  analyzer_checkout(tmp .. "/again", having)
  local parses, named, rows = boot(tmp .. "/again", path)
  assert(parses.parsed == count + 1 and parses.shared == 0, parses.parsed .. " " .. parses.shared)
  assert(named == having_named, "the name the parse moved to was not recorded")
  assert(rows == having_rows, rows .. "\n--\n" .. having_rows)
end

--- A cache that holds no parse of the tree's analyzer roots offers the
--- boot nothing to try, and the boot parses the tree, as it would with
--- no cache at all.
local function test_a_boot_the_cache_knows_nothing_of_parses_the_tree(tmp: string)
  tmp = assert(Fs.absolute(tmp))
  local path = tmp .. "/cache/cache.db"
  analyzer_checkout(tmp .. "/first", { ["build/other.tl"] = "local x = 1\nreturn x\n" })
  local _, named = boot(tmp .. "/first", path)
  analyzer_checkout(tmp .. "/second", {
    ["build/importer.tl"] = analyzer_tree["build/importer.tl"] .. "-- another\n",
  })
  local parses, second_named = boot(tmp .. "/second", path)
  assert(parses.shared == 0 and second_named ~= named)
end

--- A parse kept comes back whole, and a row that decodes otherwise than
--- its digest says is none; parses and compiles are bounded together,
--- the least lately used of either going first.
local function test_a_kept_parse_comes_back_whole(tmp: string)
  local cache = assert(shared_compiles.open(tmp .. "/cache/cache.db"))
  local key: shared_compiles.ParseKey = { analyzer = "x", source_hash = "ab", mapped = true }
  local made: importer.Shared.Parse = { requires = { "c", "cosmic.fs" }, rows = "parsed 2 1\ni0;t1:m" }
  assert(shared_compiles.settle(cache, { kept = {}, used = {},
    parses = { { key = key, made = made } }, parses_used = {} }, 1))
  local found = assert(shared_compiles.look_parse(cache, key))
  assert(found.rows == made.rows and table.concat(found.requires, " ") == "c cosmic.fs")
  local unmapped, trouble = shared_compiles.look_parse(cache,
    { analyzer = "x", source_hash = "ab", mapped = false })
  assert(unmapped == nil and trouble == "", "a mapped parse stood for an unmapped one")
  local guessed = assert(shared_compiles.requires(cache, "x", { "ab", "cd" }))
  assert(table.concat(guessed.ab, " ") == "c cosmic.fs" and guessed.cd == nil)
  local analyzers = assert(shared_compiles.analyzers(cache, { "ab" }))
  assert(#analyzers == 1 and analyzers[1] == "x")
  assert(#assert(shared_compiles.analyzers(cache, { "ab", "cd" })) == 0)
  -- A row moved to another source is no row of that source.
  assert(Sqlite.run(cache.db, "UPDATE parsed_v1 SET source_hash = 'cd'"))
  local moved, moved_trouble = shared_compiles.look_parse(cache,
    { analyzer = "x", source_hash = "cd", mapped = true })
  assert(moved == nil and moved_trouble == "", "a moved row was taken")
  assert(dump(tmp .. "/cache/cache.db", "SELECT count(*) FROM parsed_v1") == "0",
    "a row that failed its digest was kept")
  -- Bounded together: a compile used long ago goes before a parse used
  -- lately, though the parse was written first.
  local kept: shared_compiles.Kept = { key = "k", lua = "return {}\n", bytecode = "\27Lua",
    references = {} }
  assert(shared_compiles.settle(cache, { kept = {}, used = {},
    parses = { { key = key, made = made } }, parses_used = {} }, 10))
  assert(shared_compiles.settle(cache, { kept = { kept }, used = {} }, 5))
  local sizes = assert(Sqlite.text_rows(cache.db,
    "SELECT (SELECT size FROM compiled_v2), (SELECT size FROM parsed_v1)"))
  local parse_size = math.tointeger(tonumber(sizes[1][2])) or 0
  assert(parse_size > 0)
  assert(shared_compiles.settle(cache, { kept = {}, used = {},
    parses = { { key = { analyzer = "y", source_hash = "ab", mapped = false }, made = made } },
    parses_used = {} }, 20, 2 * parse_size + 1))
  local left = assert(Sqlite.text_rows(cache.db,
    "SELECT (SELECT count(*) FROM compiled_v2), (SELECT count(*) FROM parsed_v1)"))
  shared_compiles.close(cache)
  assert(left[1][1] == "0" and left[1][2] == "2", left[1][1] .. " " .. left[1][2])
end
