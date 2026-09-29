--- The harness's digests (`build.test`'s `harness`: what every worker
--- loads, the sandbox's maker and the code that makes and reads a key,
--- a digest per module by its source and bytecode) are the ones
--- build/harness_epoch.tl acknowledges, one to a line. No key holds
--- the harness's code, only its epoch, so an edit to it runs no test
--- again by itself: this fails until someone says, in
--- build/harness_epoch.tl, whether the edit can alter a pass or a
--- fail. And the digests hold all the harness runs: every module of
--- the tree the modules it runs require.

local Codec = require("cosmic.codec")
local Compress = require("cosmic.compress")
local Rand = require("cosmic.rand")
local Sqlite = require("cosmic.sqlite")
local Test = require("cosmic.test")
local harness_epoch = require("build.harness_epoch")
local test = require("build.test")

--- The harness is read from the projection, o/cosmic.db: its modules
--- are the tree's, most of them outside this module's closure, and so
--- is the `imports` table `key_code`'s closure is walked by. Declared
--- `store`, the key holds the projection by its contents, so every
--- edit to the tree runs this again, an edit to the harness among
--- them, and so does a compiler that makes other bytecode of it; it
--- is this module alone that pays that.
Test.needs{ store = true }

--- The line of build/harness_epoch.tl's `acknowledged` that holds
--- `name` at `digest`, as the file lays it out: each such line between
--- blank ones, so git merges changes to two modules that sort next to
--- each other as it does any other two.
local function entry(name: string, digest: string): string
  return string.format("  [%q] = %q,", name, digest)
end

--- The count `epoch` holds (build/harness_epoch.tl) when it has the
--- form the file keeps, a count, a dash and 8 lower-case hex digits
--- ("8-072f7458"), or nil where it has another.
local function epoch_count(epoch: string): integer | nil
  local count = epoch:match("^(%d+)%-%x%x%x%x%x%x%x%x$")
  if count == nil or epoch:find("%u") then return nil end
  return math.tointeger(tonumber(count))
end

--- A value to bump `epoch` to: the next count, and a token
--- drawn from the system's entropy, so that two bumps from one count --
--- on two branches -- differ, and conflict in git rather than merge as
--- one edit whose verdicts either branch's alone earned.
local function bumped(epoch: string): string
  local token = assert(Rand.entropy(4))
  local count = math.tointeger(tonumber(epoch:match("^%d+") or "0")) or 0
  return string.format("%d-%s", count + 1, Codec.hex(token))
end

--- The words that tell how to bump `epoch` from `epoch`, with a fresh
--- value to paste.
local function how_to_bump(epoch: string): string
  return string.format("To bump it, set `epoch = %q` -- a fresh token each time, " ..
    "never one copied from another branch; where two bumps conflict in a merge, keep " ..
    "neither: draw another, as this prints one on each run.", bumped(epoch))
end

--- What differs between the harness's modules as `found` has them (a
--- digest per module, `build.test`'s `harness`) and `acknowledged`:
--- nil where they agree, or a message naming each module that moved,
--- that has no entry, and each entry that names no module of the
--- harness, with the lines that acknowledge the first two.
local function unacknowledged(found: {string:string}, acknowledged: {string:string},
                              epoch: string): string | nil
  local moved: {string} = {}
  local stale: {string} = {}
  for name, digest in pairs(found) do
    if acknowledged[name] ~= digest then moved[#moved + 1] = name end
  end
  for name in pairs(acknowledged) do
    if found[name] == nil then stale[#stale + 1] = name end
  end
  if #moved == 0 and #stale == 0 then return nil end
  table.sort(moved)
  table.sort(stale)
  local out: {string} = {
    "the test harness moved (build/harness_epoch.tl): what every worker loads, " ..
    "the sandbox's maker or the code that makes and reads a key. Bump `epoch` if " ..
    "the change can alter a pass or a fail -- what a worker is given, how it is " ..
    "judged, how a key is computed; a sandbox's hold or bind tightened, too, which " ..
    "moves no other part of a key, so a pass earned through the hole does not " ..
    "stand -- which runs every test again; otherwise keep it. " .. how_to_bump(epoch) ..
    " Either way, in `acknowledged`:",
  }
  for _, name in ipairs(moved) do
    out[#out + 1] = acknowledged[name] == nil and
      "no entry for " .. name .. "; add this line, in its place by name, between blank lines" or
      "moved: " .. name .. "; set its line to"
    out[#out + 1] = entry(name, found[name])
  end
  for _, name in ipairs(stale) do
    out[#out + 1] = "stale entry: " .. name .. " is no module of the harness; delete its line"
  end
  return table.concat(out, "\n")
end

local function test_the_harness_is_acknowledged()
  local db = assert(Sqlite.open("o/cosmic.db", false))
  local found, trouble = test.harness(db)
  db:close()
  assert(found ~= nil, trouble)
  local complaint = unacknowledged(found.modules, harness_epoch.acknowledged,
    harness_epoch.epoch)
  assert(complaint == nil, complaint)
end

--- A module that moved is named alone, with the one line to set; one
--- the harness gained has a line to add; an entry for a module the
--- harness does not hold is stale.
local function test_unacknowledged_names_each_module()
  local acknowledged = { ["build.a"] = "1", ["build.b"] = "2" }
  local epoch = "8-072f7458"
  assert(unacknowledged({ ["build.a"] = "1", ["build.b"] = "2" }, acknowledged, epoch) == nil)
  local moved = assert(unacknowledged({ ["build.a"] = "1", ["build.b"] = "3" }, acknowledged,
    epoch))
  assert(moved:find("moved: build.b; set its line to\n" .. entry("build.b", "3"), 1, true), moved)
  assert(not moved:find("build.a", 1, true), moved)
  assert(moved:find("Bump `epoch`", 1, true), moved)
  assert(moved:find('set `epoch = "9%-%x%x%x%x%x%x%x%x"`'), moved)
  local added = assert(unacknowledged({ ["build.a"] = "1", ["build.b"] = "2", ["build.c"] = "4" },
    acknowledged, epoch))
  assert(added:find("no entry for build.c; add this line, in its place by name, between " ..
    "blank lines\n" .. entry("build.c", "4"), 1, true), added)
  local gone = assert(unacknowledged({ ["build.a"] = "1" }, acknowledged, epoch))
  assert(gone:find("stale entry: build.b", 1, true), gone)
  assert(not gone:find("build.a", 1, true), gone)
end

--- `epoch` is a count and a token, as build/harness_epoch.tl says: a
--- bare count, as it once was, is two branches' one edit.
local function test_the_epoch_is_a_count_and_a_token()
  assert(epoch_count(harness_epoch.epoch) ~= nil, string.format("build/harness_epoch.tl's " ..
    "`epoch` is %q, not a count, a dash and 8 lower-case hex digits. %s",
    harness_epoch.epoch, how_to_bump(harness_epoch.epoch)))
end

--- The form is held exactly, and a bump the guard prints has it, counts
--- one on, and differs from another drawn from the same count.
local function test_the_guard_holds_the_epoch_form()
  assert(epoch_count("8-072f7458") == 8)
  assert(epoch_count("12-00000000") == 12)
  for _, malformed in ipairs({ "8", "", "8-", "-072f7458", "8-072f745", "8-072f74581",
    "8-072F7458", "8-072g7458", "x-072f7458", "8_072f7458", " 8-072f7458" }) do
    assert(epoch_count(malformed) == nil, string.format("%q was taken as an epoch", malformed))
  end
  local one, two = bumped("8-072f7458"), bumped("8-072f7458")
  assert(epoch_count(one) == 9 and epoch_count(two) == 9, one .. ", " .. two)
  assert(one ~= two, "two bumps from one count drew one token: " .. one)
  -- A bare count, as the file held before its token, counts on too.
  assert(epoch_count(bumped("7")) == 8, "a bare count's bump did not count on")
end

--- The lines the guard prints are the lines build/harness_epoch.tl
--- holds, sorted by name and each between blank lines, so pasting one
--- is the whole edit and git merges two changes to different modules,
--- even two that sort next to each other.
local function test_the_file_holds_its_entries_as_the_guard_prints_them()
  local db = assert(Sqlite.open("o/cosmic.db", false))
  local rows = assert(Sqlite.rows(db, "SELECT source FROM modules WHERE path = ?1",
    { { text = "build.harness_epoch" } }))
  db:close()
  local text = assert(Compress.inflate("raw", rows[1][1].blob))
  local names: {string} = {}
  for name in pairs(harness_epoch.acknowledged) do names[#names + 1] = name end
  assert(#names > 0)
  table.sort(names)
  local last = 0
  for _, name in ipairs(names) do
    local at = text:find("\n\n" .. entry(name, harness_epoch.acknowledged[name]) .. "\n\n", 1,
      true)
    assert(at ~= nil, name .. "'s entry is not one line as the guard prints it, between " ..
      "blank lines")
    assert(at > last, name .. "'s entry is out of order: keep them sorted by name")
    last = at
  end
end

--- A require the harness never follows: cosmic's main hands the
--- command line to build.dispatch, which a worker never reaches, since
--- main starts a worker ahead of it (cmd/cosmic/main.tl).
local unfollowed: {string:{string:boolean}} = {
  ["cmd.cosmic.main"] = { ["build.dispatch"] = true },
}

--- Every module of the tree a module the harness runs requires by value
--- (what every worker loads, and the sandbox's maker, `harness_own`) is
--- in the harness's digest. Otherwise an edit to it moves neither a key
--- nor the digest. build/zig.tl, which build.caches requires, is such a
--- module: it decides where a declared cache is bound from.
local function test_the_harness_holds_what_it_runs_requires()
  local db = assert(Sqlite.open("o/cosmic.db", false))
  local found, trouble = test.harness(db)
  assert(found ~= nil, trouble)
  local named: {string:boolean} = {}
  for _, name in ipairs(found.names) do named[name] = true end
  named["build.harness_epoch"] = true
  local by_value = assert(test.value_imports(db))
  local tree: {string:boolean} = {}
  for _, row in ipairs((assert(Sqlite.text_rows(db, "SELECT path FROM modules")))) do
    tree[row[1]] = true
  end
  local missing: {string} = {}
  for _, name in ipairs(found.runs) do
    assert(tree[name], name .. " is no module of the tree")
    for _, wanted in ipairs(by_value[name] or {}) do
      if tree[wanted] and not named[wanted] and not (unfollowed[name] or {})[wanted] then
        missing[#missing + 1] = name .. " requires " .. wanted
      end
    end
  end
  db:close()
  assert(#missing == 0, "the harness runs what its digest does not hold -- name each " ..
    "in build/test.tl's `harness_own`, or build/test_worker.tl's `worker.loads` where " ..
    "a worker loads it: " .. table.concat(missing, ", "))
end

--- The harness's `cosmic.*` modules are exactly those
--- build/harness_epoch.tl's `library` names, each with its reason: a
--- module of the harness that comes to require another -- cosmic.time
--- for a clock the raw binding gives -- fails here with the rule,
--- rather than passing once its digest is acknowledged.
local function test_the_harness_names_its_library()
  local db = assert(Sqlite.open("o/cosmic.db", false))
  local found, trouble = test.harness(db)
  db:close()
  assert(found ~= nil, trouble)
  local held: {string:boolean} = {}
  local unnamed: {string} = {}
  for _, name in ipairs(found.names) do
    if name:match("^cosmic%.") then
      held[name] = true
      if harness_epoch.library[name] == nil then unnamed[#unnamed + 1] = name end
    end
  end
  local unheld: {string} = {}
  for name, reason in pairs(harness_epoch.library) do
    assert(reason ~= "", name .. " is in `library` with no reason")
    if not held[name] then unheld[#unheld + 1] = name end
  end
  table.sort(unnamed)
  table.sort(unheld)
  assert(#unnamed == 0, "the harness reaches " .. table.concat(unnamed, ", ") ..
    ", which build/harness_epoch.tl's `library` does not name: a module of the harness " ..
    "reaches the host through raw bindings and the library `library` names, each " ..
    "with its reason; take what it needs from a raw binding, or name the module there " ..
    "with why the harness must reach it")
  assert(#unheld == 0, "build/harness_epoch.tl's `library` names " ..
    table.concat(unheld, ", ") .. ", which no module of the harness reaches: " ..
    "delete its entry")
end

--- An edge of `imports` is followed unless the importer's bytecode
--- lacks the name it requires: a require spelt `require"x"`, or split
--- across lines, keeps the name there and is followed; a `local type`
--- one, which Teal erases, leaves none and is not.
local function test_value_imports_follows_every_spelling_of_a_require()
  local db = assert(Sqlite.memory())
  assert(db:exec("CREATE TABLE modules (path TEXT, kind TEXT, bytecode BLOB); " ..
    "CREATE TABLE imports (path TEXT, requires TEXT)"))
  local compiled = string.dump(assert(load(table.concat({
    'local a = require"cosmic.fs"',
    'local b = require(',
    '  "cosmic.env")',
    'return a, b',
  }, "\n"))), true)
  assert(Sqlite.run(db, "INSERT INTO modules VALUES ('build.x', 'module', ?1)",
    { { blob = compiled } }))
  for _, wanted in ipairs({ "cosmic.fs", "cosmic.env", "cosmic.child" }) do
    assert(Sqlite.run(db, "INSERT INTO imports VALUES ('build.x', ?1)", { { text = wanted } }))
  end
  -- An importer the table holds no bytecode of is followed as it is.
  assert(Sqlite.run(db, "INSERT INTO imports VALUES ('build.y', 'cosmic.time')"))
  local by_value = assert(test.value_imports(db))
  db:close()
  local kept: {string:boolean} = {}
  for _, name in ipairs(by_value["build.x"] or {}) do kept[name] = true end
  assert(kept["cosmic.fs"] and kept["cosmic.env"], "a require's spelling dropped its edge")
  assert(not kept["cosmic.child"], "an edge the bytecode does not name was followed")
  assert((by_value["build.y"] or {})[1] == "cosmic.time")
end
