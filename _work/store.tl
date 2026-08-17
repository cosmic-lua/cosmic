--- The card store: a checkout of the state repository, where each
--- `cards/<issue>.tl` is one card and git is both the log and the
--- lock. A mutation is commit-then-push; a rejected push means someone
--- else moved first, so publish rebases onto their state, re-asks the
--- caller's invariant against the MERGED board, and drops the commit
--- if the invariant no longer holds. That retry loop is the
--- compare-and-swap GitHub's eventually-consistent label index cannot
--- offer, and `history` reads the same commits back as the flow record
--- `stats` would otherwise reconstruct from the GitHub timeline API.
local cards = require("_work.card")
local child = require("cosmic.child")
local fs = require("cosmic.fs")
local literal = require("cosmic.literal")
local model = require("_work.model")

--- One open state repository.
local record Store
  --- Checkout root; `cards/` sits directly under it.
  root: string
  --- "owner/name" of the tracked repo, for issue URLs.
  repo: string
end

--- One card mutation as git recorded it.
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

--- Committer identity for state commits: deterministic, so a card
--- commit is attributable to the board tool rather than whatever
--- happens to be in the host's git config.
local GIT_IDENT: {string} = {
  "-c", "user.email=board@cosmic", "-c", "user.name=cosmic-board",
}

--- Run one git command in the store's root.
--- @param s Store The store
--- @param argv {string} Arguments after "git"
--- @return child.Result | nil The finished run, whatever its exit
--- @return string Error message when git could not be started
local function git(s: Store, argv: {string}): child.Result | nil, string
  local full: {string} = {"git"}
  for _, a in ipairs(GIT_IDENT) do
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
    return nil, ("git %s failed: %s"):format(
      table.concat(argv, " "), ((r.stderr or ""):gsub("%s+$", "")))
  end
  return r
end

--- Open a state repository checkout. The root must be a git worktree
--- holding a `cards/` directory — `gitboard init` creates both.
--- @param root string Checkout root
--- @param repo string "owner/name" of the tracked repo
--- @return Store | nil The store
--- @return string Error message
local function open(root: string, repo: string): Store | nil, string
  if not fs.is_dir(fs.join(root, ".git")) then
    return nil, ("not a git repository: %s"):format(root)
  end
  if not fs.is_dir(fs.join(root, "cards")) then
    return nil, ("no cards/ directory in %s (run init)"):format(root)
  end
  return {root = root, repo = repo}
end

--- The file a card lives in.
--- @param s Store The store
--- @param issue integer Issue number
--- @return string Absolute-ish path under the store root
local function card_path(s: Store, issue: integer): string
  return fs.join(s.root, "cards", ("%d.tl"):format(issue))
end

--- Load one card.
--- @param s Store The store
--- @param issue integer Issue number
--- @return cards.Card | nil The card
--- @return string Error message; "no card for issue N" when absent
local function load_card(s: Store, issue: integer): cards.Card | nil, string
  local path = card_path(s, issue)
  if not fs.is_file(path) then
    return nil, ("no card for issue %d"):format(issue)
  end
  local t, perr = literal.parse_file(path)
  if t == nil then
    return nil, perr
  end
  return cards.decode(t)
end

--- Every card in the store, done ones included, sorted by issue.
--- @param s Store The store
--- @return {cards.Card} | nil The cards
--- @return string Error message naming the first unreadable card
local function list(s: Store): {cards.Card} | nil, string
  local found, ferr = fs.find(fs.join(s.root, "cards"),
    {glob = "*.tl", max_depth = 1, sorted = true})
  if found == nil then
    return nil, ferr
  end
  local out: {cards.Card} = {}
  for _, path in ipairs(found) do
    local t, perr = literal.parse_file(path)
    if t == nil then
      return nil, perr
    end
    local c, derr = cards.decode(t)
    if c == nil then
      return nil, ("%s: %s"):format(path, derr)
    end
    out[#out + 1] = c
  end
  table.sort(out, function(a: cards.Card, b: cards.Card): boolean
      return a.issue < b.issue
    end)
  return out
end

--- The open board: every non-done card, grouped by phase for
--- `_work.model`. Done cards stay in the tree for history but are off
--- the board, the same way a closed issue leaves the label board.
--- @param s Store The store
--- @return model.Board | nil The board
--- @return string Error message
local function board(s: Store): model.Board | nil, string
  local all, err = list(s)
  if all == nil then
    return nil, err
  end
  local out: model.Board = {}
  for _, c in ipairs(all) do
    if c.phase ~= cards.DONE then
      local phase = out[c.phase] or {}
      phase[#phase + 1] = cards.to_issue(c, s.repo)
      out[c.phase] = phase
    end
  end
  return out
end

--- The blocker oracle over this store: an issue is open while its card
--- exists and is not done. An issue with no card does not block — the
--- board only reasons about state it holds.
--- @param s Store The store
--- @return model.IsOpen The oracle
local function is_open_fn(s: Store): model.IsOpen
  return function(n: integer): boolean
    local c = load_card(s, n)
    return c ~= nil and c.phase ~= cards.DONE
  end
end

--- Write a card and commit it as one mutation. The commit is local;
--- `publish` is what makes it the board's truth.
--- @param s Store The store
--- @param c cards.Card The card
--- @param message string Commit subject, e.g. "move #12 ready -> do"
--- @return boolean True on success
--- @return string Error message
local function save(s: Store, c: cards.Card, message: string): boolean, string
  local bad = cards.problems(c)
  if #bad > 0 then
    return false, table.concat(bad, "; ")
  end
  local ok, werr = literal.format_file(card_path(s, c.issue), cards.encode(c))
  if not ok then
    return false, werr
  end
  local rel = fs.join("cards", ("%d.tl"):format(c.issue))
  local _, aerr = git_ok(s, {"add", rel})
  if aerr then
    return false, aerr
  end
  local _, cerr = git_ok(s, {"commit", "-q", "-m", message})
  if cerr then
    return false, cerr
  end
  return true
end

--- Whether the store has an `origin` remote to publish to.
--- @param s Store The store
--- @return boolean True when origin exists
local function has_origin(s: Store): boolean
  local r = git(s, {"remote"})
  return r ~= nil and r.ok and r.stdout:find("origin", 1, true) ~= nil
end

--- Pull concurrent state: rebase this checkout's unpublished commits
--- onto the remote. A store with no origin is local-only and syncs
--- trivially.
--- @param s Store The store
--- @return boolean True on success
--- @return string Error message
local function sync(s: Store): boolean, string
  if not has_origin(s) then
    return true
  end
  local _, err = git_ok(s, {"pull", "-q", "--rebase", "origin"})
  if err then
    return false, err
  end
  return true
end

--- Publish the last commit: push, and treat a rejected push as the
--- compare half of a compare-and-swap. On rejection, rebase onto what
--- won, re-ask `revalidate` against the merged board, and if the
--- mutation no longer holds, drop the commit and refuse — the same
--- refusal `move` gives at the limit, arriving late instead of never.
--- Bounded retries; a store with no origin publishes trivially.
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
    local _, rerr = git_ok(s, {"pull", "-q", "--rebase", "origin"})
    if rerr then
      return false, rerr
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

--- One card's mutation history, newest first, from git alone.
--- @param s Store The store
--- @param issue integer Issue number
--- @return {Event} | nil Events, possibly empty
--- @return string Error message
local function history(s: Store, issue: integer): {Event} | nil, string
  local rel = fs.join("cards", ("%d.tl"):format(issue))
  local r, err = git_ok(s, {"log", "--format=%h\t%cI\t%s", "--", rel})
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
  open: function(root: string, repo: string): Store | nil, string
  card_path: function(s: Store, issue: integer): string
  load: function(s: Store, issue: integer): cards.Card | nil, string
  list: function(s: Store): {cards.Card} | nil, string
  board: function(s: Store): model.Board | nil, string
  is_open_fn: function(s: Store): model.IsOpen
  save: function(s: Store, c: cards.Card, message: string): boolean, string
  sync: function(s: Store): boolean, string
  publish: function(s: Store, revalidate?: Revalidate): boolean, string
  history: function(s: Store, issue: integer): {Event} | nil, string
end

local M: store = {
  open = open,
  card_path = card_path,
  load = load_card,
  list = list,
  board = board,
  is_open_fn = is_open_fn,
  save = save,
  sync = sync,
  publish = publish,
  history = history,
}

return M
