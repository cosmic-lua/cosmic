--- The item store: a checkout of the state repository, where each
--- `items/<id>.tl` is one work item, its prose spec (when it has one)
--- is the sidecar `items/<id>.md`, and git is both the log and the
--- lock. A mutation is commit-then-push; a rejected push means someone
--- else moved first, so publish rebases onto their state, re-asks the
--- caller's invariant against the MERGED items, and drops the commit
--- if the invariant no longer holds. That retry loop is the
--- compare-and-swap GitHub's eventually-consistent label index cannot
--- offer, and `history` reads the same commits back as the flow record
--- `stats` would otherwise reconstruct from the GitHub timeline API.
local child = require("cosmic.child")
local fs = require("cosmic.fs")
local item = require("_work.item")
local literal = require("cosmic.literal")

--- One open state repository.
local record Store
  --- Checkout root; `items/` sits directly under it.
  root: string
end

--- One item mutation as git recorded it.
local record Event
  sha: string
  --- ISO 8601 commit time.
  at: string
  subject: string
end

--- The invariant a publish re-asks after rebasing onto concurrent
--- state: nil when the mutation still holds, a problem line when it
--- does not.
local type Revalidate = function(): string

--- Git defaults for every store call: a deterministic committer, so a
--- state commit is attributable to the board tool rather than the
--- host's git config, and rename-based object finalization —
--- link-based finalization fails with EXDEV on the overlay/bind
--- mounts CI containers run tests on, and `-c` propagates this to the
--- local receive-pack a file:// push spawns.
local GIT_DEFAULTS: {string} = {
  "-c", "user.email=board@cosmic", "-c", "user.name=cosmic-board",
  "-c", "core.createObject=rename",
}

--- Run one git command in the store's root.
--- @param s Store The store
--- @param argv {string} Arguments after "git"
--- @return child.Result | nil The finished run, whatever its exit
--- @return string Error message when git could not be started
local function git(s: Store, argv: {string}): child.Result | nil, string
  local full: {string} = {"git"}
  for _, a in ipairs(GIT_DEFAULTS) do
    full[#full + 1] = a
  end
  for _, a in ipairs(argv) do
    full[#full + 1] = a
  end
  return child.run(full, {cwd = s.root})
end

--- Run one git command that must succeed.
--- @param s Store The store
--- @param argv {string} Arguments after "git"
--- @return child.Result | nil The zero-exit run
--- @return string Error message naming the command and its stderr
local function git_ok(s: Store, argv: {string}): child.Result | nil, string
  local r, err = git(s, argv)
  if r == nil then
    return nil, err
  end
  if not r.ok then
    -- Git reports some refusals on stdout ("nothing to commit"), so a
    -- stderr-only message would be an empty one.
    local detail = (r.stderr or ""):gsub("%s+$", "")
    if detail == "" then
      detail = (r.stdout or ""):gsub("%s+$", "")
    end
    return nil, ("git %s failed: %s"):format(table.concat(argv, " "), detail)
  end
  return r
end

--- Open a state repository checkout. The root must be a git worktree
--- holding an `items/` directory — `gitboard init` creates both.
--- @param root string Checkout root
--- @return Store | nil The store
--- @return string Error message
local function open(root: string): Store | nil, string
  -- A linked worktree's .git is a FILE pointing at the real gitdir —
  -- and the board's canonical home is exactly such a worktree — so
  -- presence, not directory-ness, is the test.
  if not fs.is_present(fs.join(root, ".git")) then
    return nil, ("not a git repository: %s"):format(root)
  end
  if not fs.is_dir(fs.join(root, "items")) then
    return nil, ("no items/ directory in %s (run init)"):format(root)
  end
  return {root = root}
end

--- The file an item lives in.
--- @param s Store The store
--- @param id string Item id
--- @return string Path under the store root
local function item_path(s: Store, id: string): string
  return fs.join(s.root, "items", id .. ".tl")
end

--- The sidecar an item's prose spec lives in.
--- @param s Store The store
--- @param id string Item id
--- @return string Path under the store root
local function spec_path(s: Store, id: string): string
  return fs.join(s.root, "items", id .. ".md")
end

--- Load one item.
--- @param s Store The store
--- @param id string Item id
--- @return item.Item | nil The item
--- @return string Error message; "no item <id>" when absent
local function load_item(s: Store, id: string): item.Item | nil, string
  local path = item_path(s, id)
  if not fs.is_file(path) then
    return nil, ("no item %s"):format(id)
  end
  local t, perr = literal.parse_file(path)
  if t == nil then
    return nil, perr
  end
  return item.decode(t)
end

--- The full id a unique prefix names — KSUIDs are 27 characters, so
--- verbs accept any unambiguous prefix the way git accepts short
--- hashes. An exact-length id resolves without touching the
--- directory.
--- @param s Store The store
--- @param prefix string An id or a prefix of one
--- @return string | nil The full id
--- @return string Error message: nothing matched, or the matches
local function resolve(s: Store, prefix: string): string | nil, string
  if prefix == nil or prefix == "" or prefix:match("^%w+$") == nil then
    return nil, ("not an id prefix: %s"):format(tostring(prefix))
  end
  if fs.is_file(item_path(s, prefix)) then
    return prefix
  end
  local found, ferr = fs.find(fs.join(s.root, "items"),
    {glob = prefix .. "*.tl", max_depth = 1, sorted = true})
  if found == nil then
    return nil, ferr
  end
  local matches: {string} = {}
  for _, path in ipairs(found) do
    matches[#matches + 1] = fs.basename(path):gsub("%.tl$", "")
  end
  if #matches == 0 then
    return nil, ("no item matches %s"):format(prefix)
  end
  if #matches > 1 then
    return nil, ("%s is ambiguous: %s"):format(prefix,
      table.concat(matches, " "))
  end
  return matches[1]
end

--- An item's spec sidecar, "" when it has none.
--- @param s Store The store
--- @param id string Item id
--- @return string The spec markdown, possibly empty
local function read_spec(s: Store, id: string): string
  local body = fs.read(spec_path(s, id))
  return body or ""
end

--- Every item in the store, done ones included, sorted by id.
--- @param s Store The store
--- @return {item.Item} | nil The items
--- @return string Error message naming the first unreadable item
local function list(s: Store): {item.Item} | nil, string
  local found, ferr = fs.find(fs.join(s.root, "items"),
    {glob = "*.tl", max_depth = 1, sorted = true})
  if found == nil then
    return nil, ferr
  end
  local out: {item.Item} = {}
  for _, path in ipairs(found) do
    local t, perr = literal.parse_file(path)
    if t == nil then
      return nil, ("%s: %s"):format(path, perr)
    end
    local it, derr = item.decode(t)
    if it == nil then
      return nil, ("%s: %s"):format(path, derr)
    end
    out[#out + 1] = it
  end
  return out
end

--- Write one item and its spec sidecar, and stage both.
--- @param s Store The store
--- @param it item.Item The item
--- @param spec string Replacement spec markdown; nil leaves the sidecar alone
--- @return boolean True on success
--- @return string Error message
local function stage(s: Store, it: item.Item, spec?: string): boolean, string
  local bad = item.problems(it)
  if #bad > 0 then
    return false, table.concat(bad, "; ")
  end
  local ok, werr = literal.format_file(item_path(s, it.id), item.encode(it))
  if not ok then
    return false, werr
  end
  if spec ~= nil then
    local wrote, serr = fs.write(spec_path(s, it.id), spec)
    if not wrote then
      return false, serr
    end
  end
  local add: {string} = {"add", fs.join("items", it.id .. ".tl")}
  if fs.is_file(spec_path(s, it.id)) then
    add[#add + 1] = fs.join("items", it.id .. ".md")
  end
  local _, aerr = git_ok(s, add)
  if aerr then
    return false, aerr
  end
  return true
end

--- Write an item (and, when given, its spec sidecar and further items
--- the same mutation touches) and commit them as ONE commit. Every
--- board mutation is exactly one commit, which is what lets `publish`
--- undo a refused one by dropping a single commit: a decomposition
--- that de-phases a parent while filing its child writes both here,
--- so the pair can never half-land.
--- @param s Store The store
--- @param it item.Item The item
--- @param message string Commit subject, e.g. "move fetch-retry ready -> do"
--- @param spec string Replacement spec markdown; omitted leaves the sidecar alone
--- @param also {item.Item} Further items to write into the same commit
--- @return boolean True on success
--- @return string Error message; "nothing to record" when state is unchanged
local function save(s: Store, it: item.Item, message: string,
    spec?: string, also?: {item.Item}): boolean, string
  local ok, err = stage(s, it, spec)
  if not ok then
    return false, err
  end
  for _, other in ipairs(also or {}) do
    local staged, serr = stage(s, other, nil)
    if not staged then
      return false, serr
    end
  end
  -- A mutation that changes nothing stages nothing, and `git commit`
  -- reports that on STDOUT while exiting non-zero — which reads as a
  -- bare "git commit failed:" unless it is caught here. Re-running an
  -- identical verdict or spec is the way to meet it.
  local clean = git(s, {"diff", "--cached", "--quiet"})
  if clean ~= nil and clean.ok then
    return false, ("nothing to record: %s leaves the board unchanged"):format(
      message)
  end
  local _, cerr = git_ok(s, {"commit", "-q", "-m", message})
  if cerr then
    return false, cerr
  end
  return true
end

--- Whether the store has an `origin` remote to publish to. A store
--- without one is local-only: it publishes trivially, and the gates
--- that ask GitHub about a pull request have nothing to ask.
--- @param s Store The store
--- @return boolean True when origin exists
local function has_origin(s: Store): boolean
  local r = git(s, {"remote"})
  return r ~= nil and r.ok and r.stdout:find("origin", 1, true) ~= nil
end

--- The items a stopped rebase left conflicted, as one readable list.
--- @param s Store The store
--- @return string Item ids, or "" when the paths cannot be read
local function conflicted_items(s: Store): string
  local r = git(s, {"diff", "--name-only", "--diff-filter=U"})
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
--- @param s Store The store
--- @return boolean True when the rebase completed
--- @return string Error message naming the conflicting items
local function rebase_onto_remote(s: Store): boolean, string
  local r, err = git(s, {"pull", "-q", "--rebase", "origin"})
  if r == nil then
    return false, err
  end
  if r.ok then
    return true
  end
  local ids = conflicted_items(s)
  local _, aerr = git(s, {"rebase", "--abort"})
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
--- @param s Store The store
--- @return boolean True on success
--- @return string Error message
local function sync(s: Store): boolean, string
  if not has_origin(s) then
    return true
  end
  return rebase_onto_remote(s)
end

--- Publish the last commit: push, and treat a rejected push as the
--- compare half of a compare-and-swap. On rejection, rebase onto what
--- won, re-ask `revalidate` against the merged state, and if the
--- mutation no longer holds, drop the commit and refuse — the same
--- refusal `move` gives at the limit, arriving late instead of never.
--- Bounded retries; a store with no origin publishes trivially.
---
--- Dropping the mutation is `reset --hard HEAD~1`, which is exact
--- because `save` writes every item one mutation touches into ONE
--- commit. A caller that committed twice for a single logical change
--- would have half of it survive the refusal, so it must not.
--- @param s Store The store
--- @param revalidate Revalidate Invariant re-check; nil skips it
--- @return boolean True once the commit is on the remote
--- @return string Error message
local function publish(s: Store, revalidate?: Revalidate): boolean, string
  if not has_origin(s) then
    return true
  end
  for _ = 1, 3 do
    local pushed = git(s, {"push", "-q", "origin", "HEAD"})
    if pushed == nil then
      return false, "git push could not start"
    end
    if pushed.ok then
      return true
    end
    local rebased, rerr = rebase_onto_remote(s)
    if not rebased then
      -- The mutation cannot be replayed over the winner's, so it is
      -- refused: drop it and take the remote's state, leaving a clean
      -- checkout to re-apply the change in.
      local _, uerr = git_ok(s, {"reset", "-q", "--hard", "HEAD~1"})
      if uerr then
        return false, ("%s (and the local commit could not be dropped: %s)")
        :format(rerr, uerr)
      end
      local _, serr = rebase_onto_remote(s)
      if serr then
        return false, serr
      end
      return false, ("refused after concurrent update: %s"):format(rerr)
    end
    if revalidate then
      local problem = revalidate()
      if problem then
        local _, uerr = git_ok(s, {"reset", "-q", "--hard", "HEAD~1"})
        if uerr then
          return false, uerr
        end
        return false, ("refused after concurrent update: %s"):format(problem)
      end
    end
  end
  return false, "publish did not converge after 3 attempts"
end

--- One item's mutation history, newest first, from git alone.
--- @param s Store The store
--- @param id string Item id
--- @return {Event} | nil Events, possibly empty
--- @return string Error message
local function history(s: Store, id: string): {Event} | nil, string
  local r, err = git_ok(s, {"log", "--format=%h\t%cI\t%s", "--",
      fs.join("items", id .. ".tl")})
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

local record store
  type Store = Store
  type Event = Event
  type Revalidate = Revalidate
  open: function(root: string): Store | nil, string
  item_path: function(s: Store, id: string): string
  spec_path: function(s: Store, id: string): string
  load: function(s: Store, id: string): item.Item | nil, string
  resolve: function(s: Store, prefix: string): string | nil, string
  read_spec: function(s: Store, id: string): string
  list: function(s: Store): {item.Item} | nil, string
  stage: function(s: Store, it: item.Item, spec?: string): boolean, string
  save: function(s: Store, it: item.Item, message: string, spec?: string,
  also?: {item.Item}): boolean, string
  has_origin: function(s: Store): boolean
  sync: function(s: Store): boolean, string
  publish: function(s: Store, revalidate?: Revalidate): boolean, string
  history: function(s: Store, id: string): {Event} | nil, string
end

local M: store = {
  open = open,
  item_path = item_path,
  spec_path = spec_path,
  load = load_item,
  resolve = resolve,
  read_spec = read_spec,
  list = list,
  stage = stage,
  save = save,
  has_origin = has_origin,
  sync = sync,
  publish = publish,
  history = history,
}

return M
