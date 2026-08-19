--- The GitHub reads the board's gates need, and the one write that
--- lands an accepted item: a pull request's state, its head's check
--- runs, and a squash merge. The transport is `_work.api`; what the
--- fetched values MEAN is `_work.review`, which is pure.
---
--- Deliberately four calls wide. The board's state lives in committed
--- files, so nothing here reads or writes work state — GitHub is
--- consulted only about the pull request carrying a diff, which is the
--- one fact the board cannot hold itself.
local api = require("_work.api")
local child = require("cosmic.child")
local review = require("_work.review")
local store = require("_work.store")

--- The `owner/repo` this checkout pushes to, read from origin. Both
--- URL shapes GitHub hands out are accepted; a `.git` suffix is
--- dropped.
--- @param s store.Store The store
--- @return string | nil The slug
--- @return string Error message
local function slug(s: store.Store): string | nil, string
  local r, err = child.run({"git", "remote", "get-url", "origin"},
    {cwd = s.root})
  if r == nil then
    return nil, err
  end
  if not r.ok then
    return nil, "no origin remote: " .. ((r.stderr or ""):gsub("%s+$", ""))
  end
  local url = (r.stdout or ""):gsub("%s+$", "")
  local owner, repo = url:match("github%.com[:/]([^/]+)/(.+)$")
  if owner == nil then
    return nil, ("origin is not a github remote: %s"):format(url)
  end
  return ("%s/%s"):format(owner, (repo:gsub("%.git$", "")))
end

--- One pull request, reduced to what the gates read.
--- @param s store.Store The store
--- @param number integer The PR number
--- @return review.Pull | nil The request
--- @return string Error message
local function pull(s: store.Store, number: integer): review.Pull | nil, string
  local repo, serr = slug(s)
  if repo == nil then
    return nil, serr
  end
  local path = ("/repos/%s/pulls/%d"):format(repo, number)
  local res, err = api.call("GET", path)
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
  return {
    number = number,
    draft = v["draft"] == true,
    merged = v["merged"] == true,
    body = tostring(v["body"] or ""),
    head_sha = sha,
    state = tostring(v["state"] or ""),
  }
end

--- The check runs on a commit. An empty list means GitHub reported
--- none, which is not the same as passing — `review.blocks_on_ci`
--- decides what silence is worth.
--- @param s store.Store The store
--- @param sha string The head commit
--- @return {review.CheckRun} | nil The runs
--- @return string Error message
local function checks(s: store.Store, sha: string): {review.CheckRun} | nil, string
  local repo, serr = slug(s)
  if repo == nil then
    return nil, serr
  end
  local path = ("/repos/%s/commits/%s/check-runs?per_page=100"):format(repo, sha)
  local res, err = api.call("GET", path)
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

--- One merge attempt's outcome: the HTTP status GitHub answered with,
--- and the rendered detail — empty on success, GitHub's own message
--- (via `api.error_of`) on any non-2xx.
local record Result
  status: integer
  detail: string
end

--- Squash-merge a pull request: the landing itself. `nil, err` only
--- when no response arrived at all (transport failure) — an HTTP
--- error status is still a `Result`, for `is_merged`/`refusal` to
--- classify.
--- @param s store.Store The store
--- @param number integer The PR number
--- @return Result | nil The exchange's outcome
--- @return string Error message when no response arrived
local function merge(s: store.Store, number: integer): Result | nil, string
  local repo, serr = slug(s)
  if repo == nil then
    return nil, serr
  end
  local path = ("/repos/%s/pulls/%d/merge"):format(repo, number)
  local res, err = api.call("PUT", path, {merge_method = "squash"})
  if res == nil then
    return nil, err
  end
  if not api.is_success(res.status) then
    return {status = res.status, detail = api.error_of("PUT", path, res)}
  end
  return {status = res.status, detail = ""}
end

--- Whether a merge outcome landed the PR.
--- @param res Result The merge outcome
--- @return boolean True on a 2xx
local function is_merged(res: Result): boolean
  return api.is_success(res.status)
end

--- Render a merge that did not land as text an operator acts on: a
--- 403 is a permission wall, distinct from every other failure.
--- @param pr integer The PR number
--- @param res Result The merge outcome
--- @return string The message
local function refusal(pr: integer, res: Result): string
  if res.status == 403 then
    return ("REFUSED (403: this token may not merge PR #%d into the base "
      .. "branch — a permission refusal, not the diff. The accept stands "
      .. "and PR #%d stays in land — ask a maintainer to squash-merge "
      .. "PR #%d. %s)"):format(pr, pr, pr, res.detail)
  end
  return ("ERROR (the merge of PR #%d failed and nothing was merged; "
    .. "PR #%d stays in land — re-run land once the cause clears. %s)")
  :format(pr, pr, res.detail)
end

local record gh
  type Result = Result
  slug: function(s: store.Store): string | nil, string
  pull: function(s: store.Store, number: integer): review.Pull | nil, string
  checks: function(s: store.Store, sha: string): {review.CheckRun} | nil, string
  merge: function(s: store.Store, number: integer): Result | nil, string
  is_merged: function(res: Result): boolean
  refusal: function(pr: integer, res: Result): string
end

local M: gh = {
  slug = slug,
  pull = pull,
  checks = checks,
  merge = merge,
  is_merged = is_merged,
  refusal = refusal,
}

return M
