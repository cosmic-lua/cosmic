--- A boot's parses and the cache that keeps them, in this process: a
--- boot, whose analyzer is named by the tree it has yet to parse, takes
--- the parses of the analyzer the tree names and of no other
--- ([`build.importer`]'s `derive`), and a parse kept comes back whole
--- ([`build.shared_compiles`]). build/shared_parses_tool_test.tl holds
--- the builds of checkouts that share their parses end to end.

local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local importer = require("build.importer")
local shared_compiles = require("build.shared_compiles")
local teal = require("build.teal")
local work = require("build.work")
local parses_fixture = require("build.parses_fixture")

local built, load_trouble = teal.load()
if built == nil then
  error("could not load the compiler: " .. tostring(load_trouble))
end

--- Every row `sql` answers of the database at `path`, a line each, and
--- every row of every parse table of a working database.
local dump = parses_fixture.dump
local parse_rows = parses_fixture.rows

--- The tree a boot case derives: [`build.importer`] and the analyzer
--- modules it names ([`build.analyzer`], [`build.ast`]), what they reach
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
--- `boot_hash`, which the suite's binary carries, so [`Store.meta`] is
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
