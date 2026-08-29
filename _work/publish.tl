--- Publishing a store's commits to its remote: the compare-and-swap a
--- lost push race resolves with, the fast-forward that pulls in
--- concurrent state, and reading the log back as history. A mutation
--- is commit-then-push; a lost push race drops the mutation whole,
--- re-syncs onto the winner's state, and refuses with
--- `store.LOST_RACE` — the verb is re-run against the merged board,
--- re-applying EVERY gate, never replaying a commit whose
--- preconditions the winner may have falsified: the compare-and-swap
--- GitHub's eventually-consistent label index cannot offer. `history`
--- reads the same commits back as the flow record. The git identity
--- every call runs under, and the `Store` it runs against, live in
--- `_work.store`; every git command here goes back through its
--- `git`/`git_ok`.
---
--- Sync and the lost-race recovery both leave paths outside their own
--- mutation untouched, on purpose: the shared board worktree often
--- carries an unrelated `_work/**` edit mid-flight, and a mutation
--- must not block on it, or destroy it recovering from a lost race.
--- `git fetch` plus `git merge --ff-only` never touches the working
--- tree at a path it does not need to move, and refuses by naming the
--- path when a local edit overlaps the incoming commit, instead of a
--- whole-tree `git pull --rebase` refusing outright on any dirt
--- anywhere; the lost-race recovery narrows `reset --hard` to
--- `reset --mixed` plus a checkout of only the dropped mutation's own
--- paths, for the same reason.
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

--- Git's own text, trimmed of the "hint:" advice lines it appends to
--- steer a normal terminal user toward `--no-ff`/`stash`/rebase —
--- guidance that is wrong here, so a refusal built from this text
--- never repeats it.
--- @param text string Raw stdout or stderr from a git command
--- @return string The text with advice lines removed, trailing
--- whitespace trimmed
local function clean_git_message(text: string): string
  local lines: {string} = {}
  for line in text:gmatch("([^\n]+)") do
    if not line:match("^hint:") then
      lines[#lines + 1] = line
    end
  end
  return (table.concat(lines, " "):gsub("%s+$", ""))
end

--- The checkout's current branch — the name `origin/<name>` merges
--- and checkouts below target.
--- @param s store.Store The store
--- @return string | nil The branch name
--- @return string Error message
local function current_branch(s: store.Store): string | nil, string
  local r, err = store.git_ok(s, {"rev-parse", "--abbrev-ref", "HEAD"})
  if r == nil then
    return nil, err
  end
  return ((r.stdout or ""):gsub("%s+$", ""))
end

--- Pull the remote's commits into this checkout without ever touching
--- the working tree at a path the fast-forward does not itself need
--- to move. A whole-tree `git pull --rebase` refuses on ANY unstaged
--- change anywhere, which is what used to block a mutation for the
--- length of an unrelated `_work/**` edit; `git merge --ff-only` only
--- refuses when the incoming commit and a local edit overlap the SAME
--- path, and then names it. Board history is linear here — commits
--- land only through this same fast-forward path — so a merge that
--- cannot fast-forward at all means this checkout carries a local
--- commit the remote does not have (the unpublished hand-edit
--- workaround): that is the compare-and-swap's own shape surfacing,
--- not a new failure mode, and it carries no per-file detail because
--- no merge was attempted.
--- @param s store.Store The store
--- @return boolean True when the checkout is level with the remote
--- @return string Error message
local function rebase_onto_remote(s: store.Store): boolean, string
  local branch, berr = current_branch(s)
  if branch == nil then
    return false, berr
  end
  local _, ferr = store.git_ok(s, {"fetch", "-q", "origin"})
  if ferr then
    return false, ferr
  end
  local target = ("origin/%s"):format(branch)
  local r = store.git(s, {"merge", "--ff-only", "-q", target})
  if r == nil then
    return false, "git merge could not start"
  end
  if r.ok then
    return true
  end
  local detail = clean_git_message(r.stderr or "")
  if detail == "" then
    detail = clean_git_message(r.stdout or "")
  end
  if detail:find("would be overwritten by merge", 1, true) then
    return false, ("%s — a _work/** slice belongs in its own clone; "
      .. "sync and mutate it there with --dir <private clone>"):format(detail)
  end
  return false, ("this checkout carries local commits %s does not have "
    .. "(%s) — the board is append-only and mutations publish one commit "
    .. "at a time, so local-only history means something outside the "
    .. "verbs wrote here; inspect `git log %s..HEAD`, then publish or "
    .. "drop those commits — a _work/** slice belongs in its own clone, "
    .. "driven with --dir"):format(target, detail, target)
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

--- The paths the tip commit touched — exactly what `stage` staged
--- there, read back rather than threaded through, since `save` writes
--- one mutation as ONE commit and this checkout may hold no other.
--- @param s store.Store The store
--- @return {string} | nil The paths, relative to the store root
--- @return string Error message
local function committed_paths(s: store.Store): {string} | nil, string
  local r, err = store.git_ok(s,
    {"diff-tree", "--no-commit-id", "--name-only", "-r", "HEAD"})
  if r == nil then
    return nil, err
  end
  local out: {string} = {}
  for line in r.stdout:gmatch("([^\n]+)") do
    out[#out + 1] = line
  end
  return out
end

--- Put each path back to `treeish`'s content, in the index and the
--- working tree — a path `treeish` does not carry either (a `new`
--- item's file, never committed before the dropped mutation created
--- it) has nothing to restore FROM, so it is removed outright instead.
--- Every OTHER path in the checkout, including one this mutation never
--- touched, is left exactly as it was.
--- @param s store.Store The store
--- @param treeish string A commit-ish to restore from, e.g. "HEAD"
--- @param paths {string} Paths to restore or remove
--- @return boolean True once every path is settled
--- @return string Error message
local function restore_paths(s: store.Store, treeish: string,
    paths: {string}): boolean, string
  for _, p in ipairs(paths) do
    local exists = store.git(s, {"cat-file", "-e", ("%s:%s"):format(treeish, p)})
    if exists == nil then
      return false, ("could not check %s at %s"):format(p, treeish)
    end
    if exists.ok then
      local _, cerr = store.git_ok(s, {"checkout", treeish, "--", p})
      if cerr then
        return false, cerr
      end
    elseif fs.is_present(fs.join(s.root, p)) then
      local removed, rerr = fs.remove(fs.join(s.root, p))
      if not removed then
        return false, rerr
      end
    end
  end
  return true
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
--- Dropping the mutation is `reset --mixed HEAD~1` — narrowed from
--- `reset --hard`, which would blow away every uncommitted edit in
--- the checkout, `_work/**` dirt included — followed by restoring
--- only the paths the dropped commit itself touched; every other
--- path, dirty or not, never moves. `reset --mixed` still drops
--- exactly the verb's own commit, exact because `save` writes one
--- mutation as ONE commit: an UNPUBLISHED hand-edit commit beneath it
--- (the missing-verb workaround) survives, and the re-sync that
--- follows still rebases it onto the remote and can still conflict —
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
  -- Read the tip commit's own paths back before HEAD moves off it —
  -- afterward there is no commit left to ask.
  local paths, perr = committed_paths(s)
  if paths == nil then
    return false, ("the push was rejected and the local commit's paths "
      .. "could not be read: %s"):format(perr)
  end
  local _, uerr = store.git_ok(s, {"reset", "-q", "--mixed", "HEAD~1"})
  if uerr then
    return false, ("the push was rejected and the local commit could not "
      .. "be dropped: %s"):format(uerr)
  end
  local restored, rperr = restore_paths(s, "HEAD", paths)
  if not restored then
    return false, ("the push was rejected, the local commit was dropped, "
      .. "but its own paths could not be restored: %s"):format(rperr)
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
