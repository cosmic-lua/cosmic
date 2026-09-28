--- The harness's digest (`build.test`'s `harness`: what every worker
--- loads, the sandbox's maker and the code that makes and reads a key,
--- each by its source and bytecode) is the one build/harness_epoch.tl
--- acknowledges. No key holds the harness's code, only its epoch, so an
--- edit to it runs no test again by itself: this fails until someone
--- says, in build/harness_epoch.tl, whether the edit can alter a pass or
--- a fail. And the digest holds all the harness runs: every module of
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

local function test_the_harness_is_acknowledged()
  local db = assert(Sqlite.open("o/cosmic.db", false))
  local found, trouble = test.harness(db)
  db:close()
  assert(found ~= nil, trouble)
  assert(found.digest == harness_epoch.acknowledged,
    "the test harness moved (build/harness_epoch.tl): what every worker loads, " ..
    "the sandbox's maker or the code that makes and reads a key. Bump `epoch` if " ..
    "the change can alter a pass or a fail -- what a worker is given, how it is " ..
    "judged, how a key is computed; a sandbox's hold or bind tightened, too, which " ..
    "moves no other part of a key, so a pass earned through the hole does not " ..
    "stand -- which runs every test again; otherwise keep it. Either way, set " ..
    "`acknowledged` to " .. found.digest)
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
