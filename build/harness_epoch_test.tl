--- The harness's digest (`build.test`'s `harness`: what every worker
--- loads, the sandbox's maker and the code that makes and reads a key,
--- each by its source) is the one build/harness_epoch.tl acknowledges.
--- No key holds the harness's code, only its epoch, so an edit to it
--- runs no test again by itself: this fails until someone says, in one
--- line of build/harness_epoch.tl, whether the edit can alter a pass or
--- a fail.

local Sqlite = require("cosmic.sqlite")
local Test = require("cosmic.test")
local harness_epoch = require("build.harness_epoch")
local test = require("build.test")

--- The harness is read from the projection, o/cosmic.db: its modules
--- are the tree's, most of them outside this module's closure, and so
--- is the `imports` table `key_code`'s closure is walked by. Declared
--- `store`, the key holds the projection by its contents, so every
--- edit to the tree runs this again, an edit to the harness among
--- them; it is this module alone that pays that.
Test.needs{ store = true }

local function test_the_harness_is_acknowledged()
  local db = assert(Sqlite.open("o/cosmic.db", false))
  local harness, trouble = test.harness(db)
  db:close()
  assert(harness ~= nil, trouble)
  assert(harness.digest == harness_epoch.acknowledged,
    "the test harness moved (build/harness_epoch.tl): what every worker loads, " ..
    "the sandbox's maker or the code that makes and reads a key. Bump `epoch` if " ..
    "the change can alter a pass or a fail -- what a worker is given, how it is " ..
    "judged, how a key is computed; a sandbox's hold or bind tightened, too, which " ..
    "moves no other part of a key, so a pass earned through the hole does not " ..
    "stand -- which runs every test again; otherwise keep it. Either way, set " ..
    "`acknowledged` to " .. harness.digest)
end
