--- `build.docs`' test of `docs.databases`, which reads every database a
--- lookup answers from -- the binary's own and the tree's o/cosmic.db --
--- rather than one a test builds: apart from build/docs_test.tl's so
--- those stand while the tree moves. The standard library's stand-ins
--- are held to their commands by `cosmic fix --check .`
--- (`build.tree_checks`), not here.

local Fs = require("cosmic.fs")
local sys = require("cosmic.sys")
local Test = require("cosmic.test")
local docs = require("build.docs")

--- The store's handles, since `docs.databases` is what hands them
--- out, and whether the tree is cosmic's own. It stays here, rerunning
--- on every edit to the tree, until `docs.databases` takes the store's
--- handles as a parameter.
Test.needs{ reads = { "core" }, store = true }

--- A project's own o/cosmic.db that is not a database is left out,
--- rather than failing every lookup: help and docs still answer from
--- the binary's own databases.
local function test_an_unreadable_own_database_is_left_out(dir: string)
  assert(Fs.mkdirs(dir .. "/o"))
  assert(Fs.write(dir .. "/o/cosmic.db", "not a database"))
  local before = assert(sys.getcwd())
  assert(sys.chdir(dir))
  local sources = docs.databases()
  assert(sys.chdir(before))
  local looked = assert(docs.view(sources.handles, sources.public))
  local found = assert(docs.lookup(looked, "Fs.read"))
  assert(#found > 0 and found.exact)
end
