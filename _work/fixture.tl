--- Scratch state repositories for the verb tests: a hermetic git
--- environment, a fresh store, a ready-bar-passing spec, and the two
--- shapes every verb test starts from — a goal with one workable leaf
--- under it, and a pair of clones over one bare remote.
---
--- A module rather than a copy in each test file: the harness is a
--- hundred lines of git plumbing, and two copies of it drift the way
--- any duplicate does. It is required only by `*_test.tl`.
local check = require("cosmic.check")
local child = require("cosmic.child")
local env = require("cosmic.env")
local fs = require("cosmic.fs")
local cmp = require("_work.gitcompare")
local gitspec = require("_work.gitspec")
local graph = require("_work.gitgraph")
local store = require("_work.store")

local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp"

-- Git reads a global (and system) config before it does anything, and
-- a config it cannot READ is fatal, not skipped: under the build
-- fence the home directory is outside the granted trees, so every git
-- call here — the fixtures' and the store's own — dies on
-- `unable to access '~/.gitconfig'`. Pointing this process at an
-- empty config makes the fixtures depend on no ambient state at all,
-- which is what a test of git behaviour wants regardless of the
-- fence. The store itself is deliberately NOT hermetic: a real
-- session's push needs the user's credentials and config.
local hermetic_config < const > = fs.join(tmpdir, "gitconfig-empty")
assert(fs.write(hermetic_config, ""))
assert(env.set("GIT_CONFIG_GLOBAL", hermetic_config))
assert(env.set("GIT_CONFIG_NOSYSTEM", "1"))

local READY_SPEC < const > = [[
## Change
Do exactly this.
## Non-goals
Not that.
]]

--- Run one git command in `cwd`, failing loudly — fixture setup.
local function git(cwd: string, argv: {string})
  local full: {string} = {"git", "-c", "user.email=test@example.com",
    "-c", "user.name=test", "-c", "core.createObject=rename"}
  for _, a in ipairs(argv) do
    full[#full + 1] = a
  end
  local r = check.must(child.run(full, {cwd = cwd}))
  assert(r.ok, "git " .. table.concat(argv, " ") .. " failed: " .. r.stderr)
end

--- A fresh local-only state repo with one seed commit.
local function init_state_repo(name: string): store.Store
  local root = fs.join(tmpdir, "verbs-" .. name)
  assert(fs.remove_all(root))
  assert(fs.make_dirs(fs.join(root, "items")))
  git(root, {"init", "-q"})
  assert(fs.write(fs.join(root, "items", ".gitkeep"), ""))
  git(root, {"add", "-A"})
  git(root, {"commit", "-q", "-m", "init"})
  return check.must(store.open(root))
end

--- A bare "remote" seeded with an empty items/ tree, plus two clones.
local function init_shared(name: string): store.Store, store.Store
  local base = fs.join(tmpdir, "verbs-shared-" .. name)
  assert(fs.remove_all(base))
  assert(fs.make_dirs(base))
  local bare = fs.join(base, "remote.git")
  git(base, {"init", "-q", "--bare", bare})
  git(bare, {"config", "core.createObject", "rename"})
  local seed = fs.join(base, "seed")
  git(base, {"clone", "-q", bare, seed})
  assert(fs.make_dirs(fs.join(seed, "items")))
  assert(fs.write(fs.join(seed, "items", ".gitkeep"), ""))
  git(seed, {"add", "-A"})
  git(seed, {"commit", "-q", "-m", "init"})
  git(seed, {"push", "-q", "origin", "HEAD"})
  local out: {store.Store} = {}
  for i = 1, 2 do
    local dir = fs.join(base, ("clone%d"):format(i))
    git(base, {"clone", "-q", bare, dir})
    git(dir, {"config", "core.createObject", "rename"})
    out[#out + 1] = check.must(store.open(dir))
  end
  return out[1], out[2]
end

--- Point a store's origin at GitHub for READING while its pushes keep
--- landing where they did: `url` becomes the https form of `slug`, so
--- `gh.slug(s, nil)` resolves the board's owner, and `pushurl` keeps
--- the local bare path a clone from `init_shared` already publishes
--- to. Opt-in — a fixture that never asks about the owner is
--- unchanged — and applied to a clone, never to a local-only store:
--- `publish` fetches only after a rejected push, so nothing here
--- ever reaches the network.
--- @param s store.Store A store cloned from a local bare remote
--- @param slug string The `owner/name` the board is to read as its own
local function github_origin(s: store.Store, slug: string)
  local r = check.must(child.run({"git", "remote", "get-url", "origin"},
      {cwd = s.root}))
  assert(r.ok, "the store has an origin to keep pushing to: " .. r.stderr)
  local bare = (r.stdout:gsub("%s+$", ""))
  git(s.root, {"remote", "set-url", "origin",
      ("https://github.com/%s.git"):format(slug)})
  git(s.root, {"remote", "set-url", "--push", "origin", bare})
end

--- File an item through `new` and return its id. A KSUID orders by
--- its one-second timestamp, so items minted inside the same second
--- sort by their random half — "the newest item" is not something a
--- test can read off the sorted list. The set difference is.
local function file_item(s: store.Store, title: string,
    parent: string): string
  local before: {string: boolean} = {}
  for _, i in ipairs(check.must(store.list(s))) do
    before[i.id] = true
  end
  assert(graph.cmd_new(s, title, parent, nil, "") == 0,
    "new should be accepted: " .. title)
  for _, i in ipairs(check.must(store.list(s))) do
    if not before[i.id] then
      return i.id
    end
  end
  error("new filed nothing: " .. title)
end

--- How many commits a store's checkout carries.
local function commits(s: store.Store): integer
  local r = check.must(child.run({"git", "rev-list", "--count", "HEAD"},
      {cwd = s.root}))
  assert(r.ok, "git rev-list failed: " .. r.stderr)
  return math.tointeger(tonumber((r.stdout:gsub("%s+$", "")))) or -1
end

--- HEAD's committer-recorded author email — what a reader (GitHub's
--- verified badge, a `git log`) actually sees a board commit as.
--- @param s store.Store The store
--- @return string The author email HEAD carries
local function commit_author_email(s: store.Store): string
  local r = check.must(child.run({"git", "log", "-1", "--format=%ae"},
      {cwd = s.root}))
  assert(r.ok, "git log failed: " .. r.stderr)
  return (r.stdout:gsub("%s+$", ""))
end

--- A spec sidecar meeting the ready bar, through the spec verb.
local function give_spec(s: store.Store, id: string)
  local path = fs.join(tmpdir, "ready-spec.md")
  assert(fs.write(path, READY_SPEC))
  assert(gitspec.cmd_spec(s, id, path) == 0, "spec should be accepted")
end

--- An organizing root with one workable leaf under it, both filed
--- through `new`. The root is COMPARED against a peer so that it —
--- and everything beneath it — has a position in the priority order:
--- an unplaced root would leave its leaf unpromotable, which is the
--- rule under test elsewhere, not a property of this fixture.
local function root_with_leaf(s: store.Store): string, string
  local root = file_item(s, "an outcome", "")
  local peer = file_item(s, "a lesser outcome", "")
  assert(cmp.cmd_compare(s, root, peer) == 0,
    "compare should be accepted")
  return root, file_item(s, "a workable slice", root)
end

-- A decomposition writes the child AND the parent it de-phases, and
-- they are one commit: half of it reaching the board would leave a
-- parent off the board with nothing decomposing it.

local record fixture
  READY_SPEC: string
  tmpdir: string
  git: function(cwd: string, argv: {string})
  init_state_repo: function(name: string): store.Store
  init_shared: function(name: string): store.Store, store.Store
  github_origin: function(s: store.Store, slug: string)
  file_item: function(s: store.Store, title: string,
  parent: string): string
  commits: function(s: store.Store): integer
  commit_author_email: function(s: store.Store): string
  give_spec: function(s: store.Store, id: string)
  root_with_leaf: function(s: store.Store): string, string
end

local M: fixture = {
  READY_SPEC = READY_SPEC,
  tmpdir = tmpdir,
  git = git,
  init_state_repo = init_state_repo,
  init_shared = init_shared,
  github_origin = github_origin,
  file_item = file_item,
  commits = commits,
  commit_author_email = commit_author_email,
  give_spec = give_spec,
  root_with_leaf = root_with_leaf,
}

return M
