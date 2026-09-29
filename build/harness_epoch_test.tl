--- The harness's digests (`build.test`'s `harness`: what every worker
--- loads, the sandbox's maker and the code that makes and reads a key,
--- a digest per module by its source and bytecode) are the ones
--- build/harness_epoch.tl acknowledges, one to a line. No key holds
--- the harness's code, only its epoch, so an edit to it runs no test
--- again by itself: this fails until someone says, in
--- build/harness_epoch.tl, whether the edit can alter a pass or a fail. And the digest holds all the harness runs: every module of
--- the tree the modules it runs require.

local Compress = require("cosmic.compress")
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
--- `name` at `digest`, as the file lays it out.
local function entry(name: string, digest: string): string
  return string.format("  [%q] = %q,", name, digest)
end

--- What differs between the harness's modules as `found` has them (a
--- digest per module, `build.test`'s `harness`) and `acknowledged`:
--- nil where they agree, or a message naming each module that moved,
--- that has no entry, and each entry that names no module of the
--- harness, with the lines that acknowledge the first two.
local function unacknowledged(found: {string:string}, acknowledged: {string:string}): string | nil
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
    "stand -- which runs every test again; otherwise keep it. Either way, in " ..
    "`acknowledged`:",
  }
  for _, name in ipairs(moved) do
    out[#out + 1] = (acknowledged[name] == nil and "no entry for " or "moved: ") .. name ..
      "; set its line to"
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
  local complaint = unacknowledged(found.modules, harness_epoch.acknowledged)
  assert(complaint == nil, complaint)
end

--- A module that moved is named alone, with the one line to set; one
--- the harness gained has a line to add; an entry for a module it no
--- longer holds is stale.
local function test_unacknowledged_names_each_module()
  local acknowledged = { ["build.a"] = "1", ["build.b"] = "2" }
  assert(unacknowledged({ ["build.a"] = "1", ["build.b"] = "2" }, acknowledged) == nil)
  local moved = assert(unacknowledged({ ["build.a"] = "1", ["build.b"] = "3" }, acknowledged))
  assert(moved:find("moved: build.b; set its line to\n" .. entry("build.b", "3"), 1, true), moved)
  assert(not moved:find("build.a", 1, true), moved)
  assert(moved:find("Bump `epoch`", 1, true), moved)
  local added = assert(unacknowledged({ ["build.a"] = "1", ["build.b"] = "2", ["build.c"] = "4" },
    acknowledged))
  assert(added:find("no entry for build.c; set its line to\n" .. entry("build.c", "4"), 1, true),
    added)
  local gone = assert(unacknowledged({ ["build.a"] = "1" }, acknowledged))
  assert(gone:find("stale entry: build.b", 1, true), gone)
  assert(not gone:find("build.a", 1, true), gone)
end

--- The lines the guard prints are the lines build/harness_epoch.tl
--- holds, sorted by name, so pasting one is the whole edit and git
--- merges two changes to different modules line by line.
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
    local at = text:find("\n" .. entry(name, harness_epoch.acknowledged[name]) .. "\n", 1, true)
    assert(at ~= nil, name .. "'s entry is not one line as the guard prints it")
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

--- The modules `source` requires by value -- anywhere, a lazy require
--- inside a function too -- rather than only as `local type`, which
--- Teal erases.
local function value_requires(source: string): {string:boolean}
  local out: {string:boolean} = {}
  for line in (source .. "\n"):gmatch("([^\n]*)\n") do
    if not line:match("^%s*local%s+type%s") then
      for name in line:gmatch("require%(%s*[\"']([%w_.]+)[\"']%s*%)") do out[name] = true end
    end
  end
  return out
end

--- Every module of the tree a module the harness runs requires by value
--- (what every worker loads, and the sandbox's maker, `harness_own`) is
--- in the harness's digest, or an edit to it moves neither a key nor
--- the digest: build.caches reached build/zig.tl so, which decides
--- where a declared cache is bound from.
local function test_the_harness_holds_what_it_runs_requires()
  local db = assert(Sqlite.open("o/cosmic.db", false))
  local found, trouble = test.harness(db)
  assert(found ~= nil, trouble)
  local named: {string:boolean} = {}
  for _, name in ipairs(found.names) do named[name] = true end
  named["build.harness_epoch"] = true
  local missing: {string} = {}
  for _, name in ipairs(found.runs) do
    local rows = assert(Sqlite.rows(db, "SELECT source FROM modules WHERE path = ?1",
      { { text = name } }))
    assert(#rows == 1, name .. " is no module of the tree")
    local source = assert(Compress.inflate("raw", rows[1][1].blob))
    local required = assert(Sqlite.text_rows(db,
      "SELECT requires FROM imports i WHERE path = ?1 AND EXISTS " ..
      "(SELECT 1 FROM modules m WHERE m.path = i.requires)", { { text = name } }))
    local by_value = value_requires(source)
    for _, row in ipairs(required) do
      local wanted = row[1]
      if by_value[wanted] and not named[wanted] and
          not (unfollowed[name] or {})[wanted] then
        missing[#missing + 1] = name .. " requires " .. wanted
      end
    end
  end
  db:close()
  assert(#missing == 0, "the harness runs what its digest does not hold -- name each " ..
    "in build/test.tl's `harness_own`, or build/test_worker.tl's `worker.loads` where " ..
    "a worker loads it: " .. table.concat(missing, ", "))
end
