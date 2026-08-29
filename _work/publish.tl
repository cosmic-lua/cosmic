--- Publishing a store's commits to its remote: the compare-and-swap a
--- lost push race resolves with, the rebase that unwinds a stopped
--- conflict, and reading the log back as history. A mutation is
--- commit-then-push; a lost push race drops the mutation whole,
--- re-syncs onto the winner's state, and refuses with
--- `store.LOST_RACE` — the verb is re-run against the merged board,
--- re-applying EVERY gate, never replaying a commit whose
--- preconditions the winner may have falsified: the compare-and-swap
--- GitHub's eventually-consistent label index cannot offer. `history`
--- reads the same commits back as the flow record. The git identity
--- every call runs under, and the `Store` it runs against, live in
--- `_work.store`; every git command here goes back through its
--- `git`/`git_ok`.
local fs = require("cosmic.fs")
local store = require("_work.store")

--- One item mutation as git recorded it.
local record Event
  sha: string
  --- ISO 8601 commit time.
  at: string
  subject: string
end

--- Whether the store has an `origin` remote to publish to. A store
--- without one is local-only: it publishes trivially, and the gates
--- that ask GitHub about a pull request have nothing to ask.
--- @param s store.Store The store
--- @return boolean True when origin exists
local function has_origin(s: store.Store): boolean
  local r = store.git(s, {"remote"})
  return r ~= nil and r.ok and r.stdout:find("origin", 1, true) ~= nil
end

--- The items a stopped rebase left conflicted, as one readable list.
--- @param s store.Store The store
--- @return string Item ids, or "" when the paths cannot be read
local function conflicted_items(s: store.Store): string
  local r = store.git(s, {"diff", "--name-only", "--diff-filter=U"})
  if r == nil or not r.ok then
    return ""
  end
  local ids: {string} = {}
  for line in r.stdout:gmatch("([^\n]+)") do
    local id = line:match("^items/(.+)%.tl$") or line:match("^items/(.+)%.md$")
    if id then
      ids[#ids + 1] = id:sub(1, 8)
    end
  end
  return table.concat(ids, " ")
end

--- Rebase this checkout's unpublished commits onto the remote.
---
--- Two sessions editing the SAME item conflict, and git stops the
--- rebase mid-flight with markers in the item file — a state where
--- every later verb fails, reads included, because a conflicted item
--- is no longer parseable literal data. So a stopped rebase is always
--- unwound here: the checkout goes back to where it started and the
--- caller is told which items collided, rather than being left to
--- discover a half-applied rebase.
--- @param s store.Store The store
--- @return boolean True when the rebase completed
--- @return string Error message naming the conflicting items
local function rebase_onto_remote(s: store.Store): boolean, string
  local r, err = store.git(s, {"pull", "-q", "--rebase", "origin"})
  if r == nil then
    return false, err
  end
  if r.ok then
    return true
  end
  local ids = conflicted_items(s)
  local _, aerr = store.git(s, {"rebase", "--abort"})
  if aerr then
    return false, aerr
  end
  if ids == "" then
    return false, ("git pull --rebase failed: %s"):format(
      ((r.stderr or ""):gsub("%s+$", "")))
  end
  return false, ("concurrent edit of %s — the rebase was undone; "
    .. "sync and re-apply your change"):format(ids)
end

--- Pull concurrent state. A store with no origin is local-only and
--- syncs trivially.
--- @param s store.Store The store
--- @return boolean True on success
--- @return string Error message
local function sync(s: store.Store): boolean, string
  if not has_origin(s) then
    return true
  end
  return rebase_onto_remote(s)
end

--- Publish the last commit: one push, and a rejected push is
--- diagnosed before anything is destroyed. It is a lost race only
--- when the remote holds commits this checkout lacks: then no commit
--- is replayed — its guards were decided against state the winner
--- just changed — so the mutation is dropped whole, the checkout
--- re-synced, and the refusal is `LOST_RACE`, whose recovery is
--- re-running the verb against the merged board. A rejection with
--- the remote unmoved — a pre-receive hook, a read-only token — is
--- policy, not a race: the commit stays local and the refusal
--- carries the remote's own words instead of asserting a race.
---
--- Dropping the mutation is `reset --hard HEAD~1`, exact because
--- `save` writes one mutation as ONE commit. The reset drops only
--- the verb's commit: an UNPUBLISHED hand-edit commit beneath it
--- (the missing-verb workaround) still rebases and can conflict, and
--- that refusal also says the mutation was already dropped.
--- @param s store.Store The store
--- @return boolean True once the commit is on the remote
--- @return string Error message; `LOST_RACE` exactly, for a lost race
local function publish(s: store.Store): boolean, string
  if not has_origin(s) then
    return true
  end
  local pushed = store.git(s, {"push", "-q", "origin", "HEAD"})
  if pushed == nil then
    return false, "git push could not start"
  end
  if pushed.ok then
    return true
  end
  -- After a fetch, an upstream that is an ancestor of HEAD gained
  -- nothing this checkout lacks: not a race. Only a clean "not an
  -- ancestor" (exit 1) is one; an unreadable remote or a missing
  -- upstream keeps the conservative, non-destructive answer.
  local _, ferr = store.git_ok(s, {"fetch", "-q", "origin"})
  if ferr then
    return false, ("the push was rejected and the remote could not be "
      .. "read to say why — the commit is still local: %s"):format(ferr)
  end
  local race = store.git(s, {"merge-base", "--is-ancestor", "@{u}", "HEAD"})
  if race == nil or race.code ~= 1 then
    local why = (pushed.stderr or ""):gsub("%s+$", "")
    if why == "" then
      why = (pushed.stdout or ""):gsub("%s+$", "")
    end
    return false, ("the push was rejected, and not by a concurrent "
      .. "mutation — the commit is still local; the remote said: %s")
    :format(why)
  end
  local _, uerr = store.git_ok(s, {"reset", "-q", "--hard", "HEAD~1"})
  if uerr then
    return false, ("the push was rejected and the local commit could not "
      .. "be dropped: %s"):format(uerr)
  end
  local synced, serr = rebase_onto_remote(s)
  if not synced then
    return false, ("lost the push race — the mutation was dropped whole, "
      .. "and the re-sync then stopped: %s"):format(serr)
  end
  return false, store.LOST_RACE
end

--- Mutation history, newest first, from git alone: one item's when
--- `id` names one, the whole branch's flow record when it does not.
--- An item is TWO files and its log is both — a `spec` commit touches
--- only the sidecar, and a record-only trail would miss every one.
--- @param s store.Store The store
--- @param id string Item id, or nil for every commit on the branch
--- @return {Event} | nil Events, possibly empty
--- @return string Error message
local function history(s: store.Store, id?: string): {Event} | nil, string
  local argv: {string} = {"log", "--format=%h\t%cI\t%s"}
  if id ~= nil then
    argv[#argv + 1] = "--"
    argv[#argv + 1] = fs.join("items", id .. ".tl")
    argv[#argv + 1] = fs.join("items", id .. ".md")
  end
  local r, err = store.git_ok(s, argv)
  if r == nil then
    return nil, err
  end
  local out: {Event} = {}
  for line in r.stdout:gmatch("([^\n]+)") do
    local sha, at, subject = line:match("^(%S+)\t(%S+)\t(.*)$")
    if sha then
      out[#out + 1] = {sha = sha, at = at, subject = subject}
    end
  end
  return out
end

--- When an item's file was last committed, as epoch seconds. Every
--- board mutation is one commit, so this is the item's last touch —
--- the fact claim staleness is judged from (`_work.health`).
--- @param s store.Store The store
--- @param id string Item id
--- @return integer | nil Epoch seconds of the last commit naming it
--- @return string Error message, also when it has no history
local function touched_at(s: store.Store, id: string): integer | nil, string
  local r, err = store.git_ok(s, {"log", "-1", "--format=%ct", "--",
      fs.join("items", id .. ".tl")})
  if r == nil then
    return nil, err
  end
  local t = math.tointeger(tonumber(r.stdout:match("%d+") or ""))
  if t == nil then
    return nil, ("no commit history for %s"):format(id)
  end
  return t
end

local record publish_module
  type Event = Event
  has_origin: function(s: store.Store): boolean
  sync: function(s: store.Store): boolean, string
  publish: function(s: store.Store): boolean, string
  history: function(s: store.Store, id?: string): {Event} | nil, string
  touched_at: function(s: store.Store, id: string): integer | nil, string
end

local M: publish_module = {
  has_origin = has_origin,
  sync = sync,
  publish = publish,
  history = history,
  touched_at = touched_at,
}

return M
