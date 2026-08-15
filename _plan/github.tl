--- GitHub REST adapter for the plan board: list a column, fetch and
--- create issues, swap labels, ensure the label vocabulary exists —
--- over cosmic.fetch, no gh CLI. Everything network-shaped lives here
--- so _plan.model stays pure. Auth is a GITHUB_TOKEN (or GH_TOKEN)
--- env var; HTTPS_PROXY is honored, and behind a TLS-intercepting
--- proxy set SSL_USE_SYSTEM_CERTS=1 SSL_CERT_FILE=<bundle> (read by
--- the cosmos TLS root loader).

local env = require("cosmic.env")
local fetch = require("cosmic.fetch")
local url = require("cosmic.url")

--- The GitHub issue fields the board reads, as the REST API names
--- them. `pull_request` is present exactly when the "issue" is a PR —
--- the issues endpoints return both.
local record RawLabel
  name: string
end

local record RawUser
  login: string
end

local record RawIssue
  number: integer
  title: string
  body: string
  html_url: string
  state: string
  labels: {RawLabel}
  assignees: {RawUser}
  pull_request: {string: any}
end

--- One API exchange that got a response: its status and decoded body.
local record ApiResult
  status: integer
  value: any
end

local API < const > = "https://api.github.com"

--- One authenticated REST call. nil only when no response arrived
--- (missing token, transport failure); an HTTP error status is a
--- result — callers branch on res.status.
--- @param method string HTTP method
--- @param path string Path under api.github.com, leading slash
--- @param payload any? JSON request body
--- @return ApiResult | nil The exchange
--- @return string Error message when no response arrived
local function api(method: string, path: string, payload?: any): ApiResult, string
  local token = env.get("GITHUB_TOKEN") or env.get("GH_TOKEN")
  if token == nil or token == "" then
    return nil, "no GitHub token: set GITHUB_TOKEN (or GH_TOKEN)"
  end
  local resp, err = fetch.fetch(API .. path, {
      method = method,
      json = payload,
      proxy = env.get("HTTPS_PROXY") or env.get("https_proxy"),
      headers = {
        ["authorization"] = "Bearer " .. token,
        ["accept"] = "application/vnd.github+json",
        ["x-github-api-version"] = "2022-11-28",
        ["user-agent"] = "cosmic-plan-board",
      },
    })
  if resp == nil then
    return nil, ("%s %s: %s"):format(method, path, tostring(err))
  end
  local value: any = nil
  if resp.body and #resp.body > 0 then
    value = resp:json()
  end
  return {status = resp.status, value = value}, nil
end

--- Render a non-2xx exchange as an error message, using GitHub's own
--- "message" field when it sent one.
--- @param method string HTTP method
--- @param path string Request path
--- @param res ApiResult The exchange
--- @return string The message
local function api_error(method: string, path: string, res: ApiResult): string
  local detail = ""
  local v = res.value
  if v is {string: any} then
    detail = ": " .. tostring(v["message"])
  end
  return ("%s %s: HTTP %d%s"):format(method, path, res.status, detail)
end

local function is_success(status: integer): boolean
  return status >= 200 and status < 300
end

--- Issues only: the REST issues endpoints return pull requests too,
--- marked by a pull_request key; the board never boards a PR.
--- @param list {RawIssue} Mixed issues and PRs
--- @return {RawIssue} The issues
local function only_issues(list: {RawIssue}): {RawIssue}
  local out: {RawIssue} = {}
  for _, i in ipairs(list) do
    if i.pull_request == nil then
      out[#out + 1] = i
    end
  end
  return out
end

--- Open issues carrying one label.
--- @param repo string "owner/name"
--- @param label string Label to filter on
--- @return {RawIssue} | nil Issues (never PRs)
--- @return string Error message on failure
local function list_issues(repo: string, label: string): {RawIssue}, string
  local path = ("/repos/%s/issues?state=open&per_page=100&labels=%s")
  :format(repo, url.escape_param(label))
  local res, err = api("GET", path, nil)
  if res == nil then
    return nil, err
  end
  if not is_success(res.status) then
    return nil, api_error("GET", path, res)
  end
  return only_issues(res.value as {RawIssue}) -- cast: from any
end

--- One issue, any state.
--- @param repo string "owner/name"
--- @param number integer Issue number
--- @return RawIssue | nil The issue
--- @return string Error message on failure
local function get_issue(repo: string, number: integer): RawIssue, string
  local path = ("/repos/%s/issues/%d"):format(repo, number)
  local res, err = api("GET", path, nil)
  if res == nil then
    return nil, err
  end
  if not is_success(res.status) then
    return nil, api_error("GET", path, res)
  end
  return res.value as RawIssue -- cast: from any
end

--- Create an issue.
--- @param repo string "owner/name"
--- @param title string Issue title
--- @param body string Issue body markdown
--- @param labels {string} Labels to apply
--- @return RawIssue | nil The created issue
--- @return string Error message on failure
local function create_issue(repo: string, title: string, body: string,
    labels: {string}): RawIssue, string
  local path = ("/repos/%s/issues"):format(repo)
  local res, err = api("POST", path, {title = title, body = body, labels = labels})
  if res == nil then
    return nil, err
  end
  if not is_success(res.status) then
    return nil, api_error("POST", path, res)
  end
  return res.value as RawIssue -- cast: from any
end

--- Swap labels on an issue: removals first (absent labels are fine),
--- then additions.
--- @param repo string "owner/name"
--- @param number integer Issue number
--- @param add {string} Labels to add
--- @param remove {string} Labels to remove
--- @return boolean Success
--- @return string Error message on failure
local function edit_labels(repo: string, number: integer,
    add: {string}, remove: {string}): boolean, string
  for _, l in ipairs(remove) do
    local path = ("/repos/%s/issues/%d/labels/%s")
    :format(repo, number, url.escape_param(l))
    local res, err = api("DELETE", path, nil)
    if res == nil then
      return false, err
    end
    if not is_success(res.status) and res.status ~= 404 then
      return false, api_error("DELETE", path, res)
    end
  end
  if #add > 0 then
    local path = ("/repos/%s/issues/%d/labels"):format(repo, number)
    local res, err = api("POST", path, {labels = add})
    if res == nil then
      return false, err
    end
    if not is_success(res.status) then
      return false, api_error("POST", path, res)
    end
  end
  return true, nil
end

--- Create or update one label (create, PATCH on already-exists).
--- @param repo string "owner/name"
--- @param name string Label name
--- @param color string Hex color without the #
--- @param description string One-line description
--- @return boolean Success
--- @return string Error message on failure
local function ensure_label(repo: string, name: string, color: string,
    description: string): boolean, string
  local path = ("/repos/%s/labels"):format(repo)
  local res, err = api("POST", path,
    {name = name, color = color, description = description})
  if res == nil then
    return false, err
  end
  if is_success(res.status) then
    return true, nil
  end
  if res.status ~= 422 then
    return false, api_error("POST", path, res)
  end
  local patch_path = ("/repos/%s/labels/%s"):format(repo, url.escape_param(name))
  local pres, perr = api("PATCH", patch_path,
    {color = color, description = description})
  if pres == nil then
    return false, perr
  end
  if not is_success(pres.status) then
    return false, api_error("PATCH", patch_path, pres)
  end
  return true, nil
end

local record github
  type RawIssue = RawIssue
  type RawLabel = RawLabel
  type RawUser = RawUser
  only_issues: function(list: {RawIssue}): {RawIssue}
  list_issues: function(repo: string, label: string): {RawIssue}, string
  get_issue: function(repo: string, number: integer): RawIssue, string
  create_issue: function(repo: string, title: string, body: string,
  labels: {string}): RawIssue, string
  edit_labels: function(repo: string, number: integer,
  add: {string}, remove: {string}): boolean, string
  ensure_label: function(repo: string, name: string, color: string,
  description: string): boolean, string
end

local M: github = {
  only_issues = only_issues,
  list_issues = list_issues,
  get_issue = get_issue,
  create_issue = create_issue,
  edit_labels = edit_labels,
  ensure_label = ensure_label,
}

return M
