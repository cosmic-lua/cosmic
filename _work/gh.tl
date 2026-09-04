--- The GitHub reads the board's gates need: a pull request's state
--- and the check runs on its head. The transport is `_work.api`; what
--- the fetched values MEAN is `_work.review`, which is pure.
---
--- Reads and nothing else. The board's state lives in committed
--- files, so nothing here touches work state; and nothing here writes
--- to GitHub either — a merge is performed by whoever runs the board,
--- and the board only asks whether it happened. GitHub is consulted
--- about the pull request carrying a diff, which is the one fact the
--- board cannot hold itself.
local api = require("_work.api")
local child = require("cosmic.child")
local review = require("_work.review")
local store = require("_work.store")

--- The `owner/repo` a call addresses: `repo` verbatim when set, else
--- read from this checkout's origin. Both URL shapes GitHub hands out
--- are accepted; a `.git` suffix is dropped.
--- @param s store.Store The store
--- @param repo string | nil The item's repo field, when it carries one
--- @return string | nil The slug
--- @return string Error message
local function slug(s: store.Store, repo: string | nil): string | nil, string
  if (repo or "") ~= "" then
    return repo
  end
  local r, err = child.run({"git", "remote", "get-url", "origin"},
    {cwd = s.root})
  if r == nil then
    return nil, err
  end
  if not r.ok then
    return nil, "no origin remote: " .. ((r.stderr or ""):gsub("%s+$", ""))
  end
  local url = (r.stdout or ""):gsub("%s+$", "")
  local owner, name = url:match("github%.com[:/]([^/]+)/(.+)$")
  if owner == nil then
    return nil, ("origin is not a github remote: %s"):format(url)
  end
  return ("%s/%s"):format(owner, (name:gsub("%.git$", "")))
end

--- One pull request, reduced to what the gates read.
--- @param s store.Store The store
--- @param number integer The PR number
--- @param repo string | nil The item's repo field, when it carries one
--- @return review.Pull | nil The request
--- @return string Error message
local function pull(s: store.Store, number: integer, repo: string | nil):
  review.Pull | nil, string
  local slugged, serr = slug(s, repo)
  if slugged == nil then
    return nil, serr
  end
  local path = ("/repos/%s/pulls/%d"):format(slugged, number)
  local res, err = api.call("GET", path, s.root)
  if res == nil then
    return nil, err
  end
  if not api.is_success(res.status) then
    return nil, api.error_of("GET", path, res)
  end
  local v = res.value
  if not (v is {string: any}) then
    return nil, ("GET %s: response is not an object"):format(path)
  end
  local head = v["head"]
  local sha = ""
  if head is {string: any} then
    sha = tostring(head["sha"] or "")
  end
  local base = v["base"]
  local base_ref = ""
  if base is {string: any} then
    base_ref = tostring(base["ref"] or "")
  end
  return {
    number = number,
    draft = v["draft"] == true,
    merged = v["merged"] == true,
    body = tostring(v["body"] or ""),
    head_sha = sha,
    base = base_ref,
    state = tostring(v["state"] or ""),
    merge_sha = tostring(v["merge_commit_sha"] or ""),
  }
end

--- The check runs on a commit. An empty list means GitHub reported
--- none, which is not the same as passing — `review.blocks_on_ci`
--- decides what silence is worth.
--- @param s store.Store The store
--- @param sha string The head commit
--- @param repo string | nil The item's repo field, when it carries one
--- @return {review.CheckRun} | nil The runs
--- @return string Error message
local function checks(s: store.Store, sha: string, repo: string | nil):
  {review.CheckRun} | nil, string
  local slugged, serr = slug(s, repo)
  if slugged == nil then
    return nil, serr
  end
  local path = ("/repos/%s/commits/%s/check-runs?per_page=100"):format(slugged, sha)
  local res, err = api.call("GET", path, s.root)
  if res == nil then
    return nil, err
  end
  if not api.is_success(res.status) then
    return nil, api.error_of("GET", path, res)
  end
  local out: {review.CheckRun} = {}
  local v = res.value
  if not (v is {string: any}) then
    return out
  end
  local runs = v["check_runs"]
  if not (runs is {any}) then
    return out
  end
  for _, entry in ipairs(runs) do
    if entry is {string: any} then
      out[#out + 1] = {
        name = tostring(entry["name"] or "?"),
        status = tostring(entry["status"] or ""),
        conclusion = tostring(entry["conclusion"] or ""),
      }
    end
  end
  return out
end

--- One pull request's head reduced to a single summary a caller can
--- act on without re-deriving it from the raw run list, plus the raw
--- data it was derived from — so a caller that needs to EXPLAIN the
--- state (a sha7 and a done/total count in a refusal message) reads
--- `head_sha` and `runs` off this one record instead of re-fetching
--- the same PR and check-run list a second time.
local record HeadChecks
  --- "green" (every completed run passed), "red" (`review.blocks_on_ci`
  --- already calls that a failure), "running" (nothing has failed yet,
  --- but something is still going), or "none" (the repo runs no checks
  --- on this head at all — not the same as passing, and worth a word
  --- of its own rather than an empty list a caller must interpret
  --- itself).
  state: string
  --- The head commit this summarizes.
  head_sha: string
  --- The check runs `state` was derived from, possibly empty.
  runs: {review.CheckRun}
end

--- Composes `pull` and `checks` in ONE call each — the same one-read
--- discipline `gitverdict.cmd_verdict` and `gitgate.handover_refusal`
--- already hold. Fails exactly when either underlying read does — no
--- origin, no token, a network or API error — and a caller reads that
--- the same way it always could: nil is "unknown", never "red".
--- @param s store.Store The store
--- @param number integer The PR number
--- @param repo string | nil The item's repo field, when it carries one
--- @return HeadChecks | nil The summary
--- @return string Error message
local function head_checks(s: store.Store, number: integer, repo: string | nil):
  HeadChecks | nil, string
  local p, perr = pull(s, number, repo)
  if p == nil then
    return nil, perr
  end
  local runs, cerr = checks(s, p.head_sha, repo)
  if runs == nil then
    return nil, cerr
  end
  local state = "green"
  if review.blocks_on_ci(runs) ~= nil then
    state = "red"
  elseif #runs == 0 then
    state = "none"
  else
    for _, r in ipairs(runs) do
      if r.status ~= "completed" then
        state = "running"
        break
      end
    end
  end
  return {state = state, head_sha = p.head_sha, runs = runs}, ""
end

local record gh
  slug: function(s: store.Store, repo: string | nil): string | nil, string
  pull: function(s: store.Store, number: integer, repo: string | nil):
  review.Pull | nil, string
  checks: function(s: store.Store, sha: string, repo: string | nil):
  {review.CheckRun} | nil, string
  head_checks: function(s: store.Store, number: integer, repo: string | nil):
  HeadChecks | nil, string
  type HeadChecks = HeadChecks
end

local M: gh = {
  slug = slug,
  pull = pull,
  checks = checks,
  head_checks = head_checks,
}

return M
