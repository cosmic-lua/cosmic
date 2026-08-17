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

--- Squash-merge a pull request: the landing itself.
--- @param s store.Store The store
--- @param number integer The PR number
--- @return boolean True once merged
--- @return string Error message
local function merge(s: store.Store, number: integer): boolean, string
  local repo, serr = slug(s)
  if repo == nil then
    return false, serr
  end
  local path = ("/repos/%s/pulls/%d/merge"):format(repo, number)
  local res, err = api.call("PUT", path, {merge_method = "squash"})
  if res == nil then
    return false, err
  end
  -- 403 is its own answer: the request is fine and this token may not
  -- merge it. Saying so beats "the merge failed".
  if res.status == 403 then
    return false, ("PR #%d: this token may not merge (403) — a human with "
      .. "write access has to land it"):format(number)
  end
  if not api.is_success(res.status) then
    return false, api.error_of("PUT", path, res)
  end
  return true
end

local record gh
  slug: function(s: store.Store): string | nil, string
  pull: function(s: store.Store, number: integer): review.Pull | nil, string
  checks: function(s: store.Store, sha: string): {review.CheckRun} | nil, string
  merge: function(s: store.Store, number: integer): boolean, string
end

local M: gh = {
  slug = slug,
  pull = pull,
  checks = checks,
  merge = merge,
}

return M
