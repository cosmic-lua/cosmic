--- Thin adapter over the gh CLI for the plan board: list a column,
--- fetch one issue, swap column labels, ensure the label vocabulary
--- exists. Everything network-shaped lives here so _plan.model stays
--- pure; auth is whatever `gh auth` already holds.

local child = require("cosmic.child")
local json = require("cosmic.json")

--- The gh JSON fields the board reads, as gh names them.
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
  url: string
  state: string
  labels: {RawLabel}
  assignees: {RawUser}
end

local FIELDS < const > = "number,title,body,url,state,labels,assignees"

--- Run gh and hand back stdout, or nil and a message carrying gh's
--- own stderr — the caller never re-diagnoses an exit code.
--- @param argv {string} Full argv, argv[1] = "gh"
--- @return string | nil Captured stdout
--- @return string Error message on failure
local function run_gh(argv: {string}): string, string
  local res, err = child.run(argv)
  if not res then
    return nil, "gh did not start: " .. tostring(err)
    .. " (is the gh CLI installed and on PATH?)"
  end
  if not res.ok then
    return nil, ("gh exited %d: %s"):format(
      res.code or -1, ((res.stderr or ""):gsub("%s+$", "")))
  end
  return res.stdout
end

--- Decode a gh --json payload into issues.
--- @param payload string JSON text (array or single object)
--- @param single boolean True to decode one issue, false for a list
--- @return {RawIssue} | nil Issues (a single issue is wrapped)
--- @return string Error message on failure
local function decode_issues(payload: string, single: boolean): {RawIssue}, string
  local v, derr = json.decode(payload)
  if v == nil then
    return nil, "gh returned undecodable JSON: " .. tostring(derr)
  end
  if single then
    return {v as RawIssue}, nil -- cast: from any
  end
  return v as {RawIssue}, nil -- cast: from any
end

--- Open issues carrying one label.
--- @param repo string "owner/name"
--- @param label string Label to filter on
--- @return {RawIssue} | nil Issues, oldest data as gh returns it
--- @return string Error message on failure
local function list_issues(repo: string, label: string): {RawIssue}, string
  local out, err = run_gh({
      "gh", "issue", "list", "--repo", repo, "--label", label,
      "--state", "open", "--limit", "100", "--json", FIELDS,
    })
  if out == nil then
    return nil, err
  end
  return decode_issues(out, false)
end

--- One issue, any state.
--- @param repo string "owner/name"
--- @param number integer Issue number
--- @return RawIssue | nil The issue
--- @return string Error message on failure
local function get_issue(repo: string, number: integer): RawIssue, string
  local out, err = run_gh({
      "gh", "issue", "view", tostring(number), "--repo", repo,
      "--json", FIELDS,
    })
  if out == nil then
    return nil, err
  end
  local issues, derr = decode_issues(out, true)
  if issues == nil then
    return nil, derr
  end
  return issues[1], nil
end

--- Swap labels on an issue in one edit.
--- @param repo string "owner/name"
--- @param number integer Issue number
--- @param add {string} Labels to add
--- @param remove {string} Labels to remove
--- @return boolean Success
--- @return string Error message on failure
local function edit_labels(repo: string, number: integer,
    add: {string}, remove: {string}): boolean, string
  local argv: {string} = {
    "gh", "issue", "edit", tostring(number), "--repo", repo,
  }
  for _, l in ipairs(add) do
    argv[#argv + 1] = "--add-label"
    argv[#argv + 1] = l
  end
  for _, l in ipairs(remove) do
    argv[#argv + 1] = "--remove-label"
    argv[#argv + 1] = l
  end
  local out, err = run_gh(argv)
  if out == nil then
    return false, err
  end
  return true, nil
end

--- Create or update one label (idempotent via --force).
--- @param repo string "owner/name"
--- @param name string Label name
--- @param color string Hex color without the #
--- @param description string One-line description
--- @return boolean Success
--- @return string Error message on failure
local function ensure_label(repo: string, name: string, color: string,
    description: string): boolean, string
  local out, err = run_gh({
      "gh", "label", "create", name, "--repo", repo,
      "--color", color, "--description", description, "--force",
    })
  if out == nil then
    return false, err
  end
  return true, nil
end

local record gh
  type RawIssue = RawIssue
  type RawLabel = RawLabel
  type RawUser = RawUser
  list_issues: function(repo: string, label: string): {RawIssue}, string
  get_issue: function(repo: string, number: integer): RawIssue, string
  edit_labels: function(repo: string, number: integer,
  add: {string}, remove: {string}): boolean, string
  ensure_label: function(repo: string, name: string, color: string,
  description: string): boolean, string
end

local M: gh = {
  list_issues = list_issues,
  get_issue = get_issue,
  edit_labels = edit_labels,
  ensure_label = ensure_label,
}

return M
