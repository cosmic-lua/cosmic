--- GitHub REST adapter for the work board: list a phase, fetch and
--- create issues, swap labels, ensure the label vocabulary exists —
--- over cosmic.fetch, no gh CLI. Everything network-shaped lives here
--- so _work.model stays pure. Auth is a GITHUB_TOKEN (or GH_TOKEN)
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

--- One conversation comment, on an issue or a PR — the REST API uses
--- the same endpoint and number space for both.
local record RawComment
  body: string
  created_at: string
  user: RawUser
end

--- One issue timeline event, as the REST events endpoint returns it.
--- `event` names the kind ("labeled", "unlabeled", "closed", and
--- others the flow-stats reader ignores); `label` carries the label
--- name and is present only on "labeled"/"unlabeled" events.
local record RawEvent
  event: string
  created_at: string
  label: RawLabel
end

--- The GitHub pull request fields the implementer lane reads.
local record RawPull
  number: integer
  state: string
  draft: boolean
  merged: boolean
  mergeable_state: string
  body: string
  html_url: string
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
        ["user-agent"] = "cosmic-work-board",
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

--- The single issue a successful exchange carried, as a RawIssue: the
--- one place the decoded JSON crosses into the record type.
--- @param res ApiResult A successful exchange
--- @return RawIssue The issue it carried
local function issue_of(res: ApiResult): RawIssue
  return res.value as RawIssue -- cast: from any
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

--- Optional narrowing for list_issues, beyond its default (open issues,
--- no window): `state` is "open"/"closed"/"all", defaulting to "open";
--- `since` (ISO 8601) restricts to issues updated at or after it.
local record ListWindow
  state: string
  since: string
end

--- Issues carrying one label, open by default; pass `opts` to widen the
--- state or add an updated-since window (the flow-stats reader wants
--- both: closed issues count too, and only the report window matters).
--- @param repo string "owner/name"
--- @param label string Label to filter on
--- @param opts ListWindow? State/window narrowing; nil for open, no window
--- @return {RawIssue} | nil Issues (never PRs)
--- @return string Error message on failure
local function list_issues(repo: string, label: string,
    opts?: ListWindow): {RawIssue}, string
  local state = (opts and opts.state) or "open"
  local path = ("/repos/%s/issues?state=%s&per_page=100&labels=%s")
  :format(repo, state, url.escape_param(label))
  if opts and opts.since then
    path = path .. "&since=" .. url.escape_param(opts.since)
  end
  local res, err = api("GET", path, nil)
  if res == nil then
    return nil, err
  end
  if not is_success(res.status) then
    return nil, api_error("GET", path, res)
  end
  return only_issues(res.value as {RawIssue}) -- cast: from any
end

--- An issue's timeline events — labels applied/removed and closes, in
--- chronological order — which the flow-stats reader replays into
--- per-phase stints. One page (100) suffices: a board issue
--- accumulating 100+ label events across its lifetime is not a case
--- worth paging for.
--- @param repo string "owner/name"
--- @param number integer Issue number
--- @return {RawEvent} | nil The events, oldest first
--- @return string Error message on failure
local function list_issue_events(repo: string, number: integer): {RawEvent}, string
  local path = ("/repos/%s/issues/%d/events?per_page=100"):format(repo, number)
  local res, err = api("GET", path, nil)
  if res == nil then
    return nil, err
  end
  if not is_success(res.status) then
    return nil, api_error("GET", path, res)
  end
  return res.value as {RawEvent} -- cast: from any
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
  return issue_of(res)
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
  return issue_of(res)
end

--- The PATCH body for an issue edit: only the fields the caller
--- supplied. Labels are never part of it — phases move through
--- edit_labels, which owns the WIP limits.
--- @param title string Replacement title; nil to leave it alone
--- @param body string Replacement body markdown; nil to leave it alone
--- @return {string: any} The request payload
local function issue_patch(title?: string, body?: string): {string: any}
  local payload: {string: any} = {}
  if title ~= nil then
    payload["title"] = title
  end
  if body ~= nil then
    payload["body"] = body
  end
  return payload
end

--- Rewrite an issue's title and/or body in place.
--- @param repo string "owner/name"
--- @param number integer Issue number
--- @param title string Replacement title; nil to leave it alone
--- @param body string Replacement body markdown; nil to leave it alone
--- @return RawIssue | nil The updated issue
--- @return string Error message on failure
local function update_issue(repo: string, number: integer,
    title?: string, body?: string): RawIssue, string
  local path = ("/repos/%s/issues/%d"):format(repo, number)
  local res, err = api("PATCH", path, issue_patch(title, body))
  if res == nil then
    return nil, err
  end
  if not is_success(res.status) then
    return nil, api_error("PATCH", path, res)
  end
  return issue_of(res)
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

--- The conversation comments on an issue or PR, oldest first.
--- @param repo string "owner/name"
--- @param number integer Issue or PR number (same space)
--- @return {RawComment} | nil The comments
--- @return string Error message on failure
local function list_issue_comments(repo: string, number: integer): {RawComment}, string
  -- capped at the first 100 comments; a thread that long is out of scope
  -- until it happens, and this bound is what makes that failure diagnosable
  local path = ("/repos/%s/issues/%d/comments?per_page=100"):format(repo, number)
  local res, err = api("GET", path, nil)
  if res == nil then
    return nil, err
  end
  if not is_success(res.status) then
    return nil, api_error("GET", path, res)
  end
  return res.value as {RawComment} -- cast: from any
end

--- One pull request, any state.
--- @param repo string "owner/name"
--- @param number integer PR number
--- @return RawPull | nil The pull request
--- @return string Error message on failure
local function get_pull(repo: string, number: integer): RawPull, string
  local path = ("/repos/%s/pulls/%d"):format(repo, number)
  local res, err = api("GET", path, nil)
  if res == nil then
    return nil, err
  end
  if not is_success(res.status) then
    return nil, api_error("GET", path, res)
  end
  return res.value as RawPull -- cast: from any
end

--- Squash-merge a pull request.
--- @param repo string "owner/name"
--- @param number integer PR number
--- @return boolean Success
--- @return string Error message on failure
local function merge_pull(repo: string, number: integer): boolean, string
  local path = ("/repos/%s/pulls/%d/merge"):format(repo, number)
  local res, err = api("PUT", path, {merge_method = "squash"})
  if res == nil then
    return false, err
  end
  if not is_success(res.status) then
    return false, api_error("PUT", path, res)
  end
  return true, nil
end

local record github
  type RawIssue = RawIssue
  type RawLabel = RawLabel
  type RawUser = RawUser
  type RawComment = RawComment
  type RawEvent = RawEvent
  type RawPull = RawPull
  type ListWindow = ListWindow
  only_issues: function(list: {RawIssue}): {RawIssue}
  list_issues: function(repo: string, label: string, opts?: ListWindow):
  {RawIssue}, string
  list_issue_events: function(repo: string, number: integer): {RawEvent}, string
  get_issue: function(repo: string, number: integer): RawIssue, string
  create_issue: function(repo: string, title: string, body: string,
  labels: {string}): RawIssue, string
  issue_patch: function(title?: string, body?: string): {string: any}
  update_issue: function(repo: string, number: integer,
  title?: string, body?: string): RawIssue, string
  edit_labels: function(repo: string, number: integer,
  add: {string}, remove: {string}): boolean, string
  ensure_label: function(repo: string, name: string, color: string,
  description: string): boolean, string
  list_issue_comments: function(repo: string, number: integer): {RawComment}, string
  get_pull: function(repo: string, number: integer): RawPull, string
  merge_pull: function(repo: string, number: integer): boolean, string
end

local M: github = {
  only_issues = only_issues,
  list_issues = list_issues,
  list_issue_events = list_issue_events,
  get_issue = get_issue,
  create_issue = create_issue,
  issue_patch = issue_patch,
  update_issue = update_issue,
  edit_labels = edit_labels,
  ensure_label = ensure_label,
  list_issue_comments = list_issue_comments,
  get_pull = get_pull,
  merge_pull = merge_pull,
}

return M
