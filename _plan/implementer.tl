--- The implementer lane's verbs: `show` reads an issue (the body IS
--- the spec), `land` verifies a PR and squash-merges it. Same shape as
--- `_plan/verbs.tl` — each cmd_* takes plain arguments, prints its own
--- output including the trailing `plan-<verb>:` verdict line, and
--- returns the process exit code. Argument parsing and dispatch live
--- in board.tl.

local gh = require("_plan.github")
local model = require("_plan.model")

--- Pure: whether a comment's first line is exactly the machine-
--- readable accept the review skill emits, tolerant of a `\r\n` body.
--- @param comment_body string Comment body
--- @return boolean True when the first line is "plan-verdict: accept"
local function is_accept(comment_body: string): boolean
  local body = comment_body or ""
  local first = body:match("^([^\n]*)")
  first = first:gsub("\r$", "")
  return first == "plan-verdict: accept"
end

--- Pure: whether a PR body references "Closes #<issue>" (case-
--- insensitive on the verb), anchored on the full digit run so `#70`
--- never matches a search for `#7`.
--- @param pr_body string PR body
--- @param issue integer Issue number the PR must close
--- @return boolean True when the reference is present
local function closes(pr_body: string, issue: integer): boolean
  local body = pr_body or ""
  for num in body:gmatch("[Cc]loses #(%d+)") do
    if tonumber(num) == issue then
      return true
    end
  end
  return false
end

--- show: print an issue's title, column, URL, body verbatim, and every
--- conversation comment — the read half of the implementer loop (the
--- body IS the spec).
--- @param repo string "owner/name"
--- @param number integer Issue number
--- @return integer Exit code
local function cmd_show(repo: string, number: integer): integer
  local raw, err = gh.get_issue(repo, number)
  if raw == nil then
    io.stderr:write(err .. "\n")
    print("plan-show: ERROR")
    return 1
  end
  local names: {string} = {}
  for _, l in ipairs(raw.labels or {}) do
    names[#names + 1] = l.name
  end
  local column = model.column_of(names)
  local tags = ""
  if model.has_marker(names, "epic") then
    tags = tags .. " [epic]"
  end
  if model.has_marker(names, "finding") then
    tags = tags .. " [finding]"
  end
  if model.has_marker(names, "enable") then
    tags = tags .. " [enable]"
  end
  print(("#%d %s"):format(raw.number, raw.title))
  print((column or "none") .. tags)
  print(raw.html_url)
  print("")
  print(raw.body or "")
  local comments, cerr = gh.list_issue_comments(repo, number)
  if comments == nil then
    io.stderr:write(cerr .. "\n")
    print("plan-show: ERROR")
    return 1
  end
  for _, c in ipairs(comments) do
    local login = "?"
    if c.user then
      login = c.user.login
    end
    print("")
    print(("%s %s"):format(login, c.created_at))
    print("---")
    print(c.body or "")
  end
  print(("plan-show: #%d %s"):format(raw.number, column or "none"))
  return 0
end

--- land: verify a PR closes its issue and carries an accept verdict,
--- then squash-merge it — the write half of the implementer loop. The
--- gates that need no second API call (the closes reference, the PR's
--- own open/draft/merged state, both read off the one get_pull call)
--- run before the ones that do (the accept comment, which needs the
--- conversation fetched); the closes-reference gate runs first of all,
--- so a PR that does not even claim to close the right issue refuses
--- on that alone — even one long since closed or merged — before
--- anything resembling a merge is attempted.
--- @param repo string "owner/name"
--- @param issue integer Issue number the PR must close
--- @param pr integer PR number to land
--- @return integer Exit code
local function cmd_land(repo: string, issue: integer, pr: integer): integer
  local raw, err = gh.get_pull(repo, pr)
  if raw == nil then
    io.stderr:write(err .. "\n")
    print("plan-land: ERROR")
    return 1
  end
  if not closes(raw.body or "", issue) then
    print(("plan-land: REFUSED (PR #%d body doesn't reference 'Closes #%d'; "
        .. "the landing must close the issue it claims)"):format(pr, issue))
    return 1
  end
  if raw.merged then
    print(("plan-land: REFUSED (PR #%d is already merged)"):format(pr))
    return 1
  end
  if raw.state ~= "open" then
    print(("plan-land: REFUSED (PR #%d is %s, not open)"):format(pr, raw.state))
    return 1
  end
  if raw.draft then
    print(("plan-land: REFUSED (PR #%d is a draft; mark it ready for review "
        .. "— the REST API cannot)"):format(pr))
    return 1
  end
  local comments, cerr = gh.list_issue_comments(repo, pr)
  if comments == nil then
    io.stderr:write(cerr .. "\n")
    print("plan-land: ERROR")
    return 1
  end
  local accepted = false
  for _, c in ipairs(comments) do
    if is_accept(c.body or "") then
      accepted = true
      break
    end
  end
  if not accepted then
    print("plan-land: REFUSED (no comment's first line is exactly "
      .. "'plan-verdict: accept')")
    return 1
  end
  if raw.mergeable_state ~= "clean" then
    print(("plan-land: REFUSED (mergeable_state is %s; merge main, run the "
        .. "regen command the gate prints, push, and re-run land)"):format(
        raw.mergeable_state))
    return 1
  end
  local ok, merr = gh.merge_pull(repo, pr)
  if not ok then
    io.stderr:write(merr .. "\n")
    print("plan-land: ERROR")
    return 1
  end
  print(("plan-land: #%d via PR #%d"):format(issue, pr))
  return 0
end

local record implementer
  is_accept: function(comment_body: string): boolean
  closes: function(pr_body: string, issue: integer): boolean
  cmd_show: function(repo: string, number: integer): integer
  cmd_land: function(repo: string, issue: integer, pr: integer): integer
end

local M: implementer = {
  is_accept = is_accept,
  closes = closes,
  cmd_show = cmd_show,
  cmd_land = cmd_land,
}

return M
