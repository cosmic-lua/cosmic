--- The item store: a checkout of the state repository, where each
--- `items/<id>.tl` is one work item, its prose spec (when it has one)
--- is the sidecar `items/<id>.md`, and git backs every write — one
--- mutation is one commit, staged and committed here. Reading that
--- history back, publishing it to a remote, and the compare-and-swap a
--- lost push race resolves with live in `_work.publish`, which calls
--- back into `git`/`git_ok` here for the same deterministic git
--- identity every store call uses.
local child = require("cosmic.child")
local fs = require("cosmic.fs")
local item = require("_work.item")
local literal = require("cosmic.literal")

--- One open state repository.
local record Store
  --- Checkout root; `items/` sits directly under it.
  root: string
end

--- The refusal a lost push race earns, exported so a verb can tell
--- it from a terminal failure; compared by identity, never matched.
local LOST_RACE < const > = "lost the push race — the mutation was dropped "
.. "whole and the checkout re-synced; re-run the verb against the "
.. "current board"

--- Git defaults for every store call: a deterministic committer, so a
--- state commit is attributable to the board tool rather than the
--- host's git config, and rename-based object finalization —
--- link-based finalization fails with EXDEV on the overlay/bind
--- mounts CI containers run tests on, and `-c` propagates this to the
--- local receive-pack a file:// push spawns.
local GIT_DEFAULTS: {string} = {
  "-c", "user.email=noreply@anthropic.com", "-c", "user.name=Claude",
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

--- The full id a unique prefix names — KSUIDs are 27 characters, so verbs accept any
--- unambiguous prefix the way git accepts short hashes, or the 8-character render
--- handle `_work.tail` resolves separately (bare or wrapped, either divider,
--- case-tolerant). An exact-length id resolves without touching the directory.
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

local record store
  type Store = Store
  LOST_RACE: string
  git: function(s: Store, argv: {string}): child.Result | nil, string
  git_ok: function(s: Store, argv: {string}): child.Result | nil, string
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
end

local M: store = {
  LOST_RACE = LOST_RACE,
  git = git,
  git_ok = git_ok,
  open = open,
  item_path = item_path,
  spec_path = spec_path,
  load = load_item,
  resolve = resolve,
  read_spec = read_spec,
  list = list,
  stage = stage,
  save = save,
}

return M
