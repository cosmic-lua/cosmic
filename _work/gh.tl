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

local record gh
  slug: function(s: store.Store, repo: string | nil): string | nil, string
  pull: function(s: store.Store, number: integer, repo: string | nil):
  review.Pull | nil, string
  checks: function(s: store.Store, sha: string, repo: string | nil):
  {review.CheckRun} | nil, string
end

local M: gh = {
  slug = slug,
  pull = pull,
  checks = checks,
}

return M
