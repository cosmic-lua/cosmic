--- The implementer lane's verbs: `show` reads an issue (the body IS
--- the spec), `land` verifies a PR and squash-merges it. Same shape as
--- `_work/verbs.tl` — each cmd_* takes plain arguments, prints its own
--- output including the trailing `work-<verb>:` verdict line, and
--- returns the process exit code. Argument parsing and dispatch live
--- in board.tl.

local gh = require("_work.github")
local model = require("_work.model")

--- Pure: whether a comment's first line is exactly the machine-
--- readable accept a planner's verdict carries, tolerant of a `\r\n`
--- body.
--- Both spellings count: `work-verdict: accept` and the older
--- `plan-verdict: accept`, which open PRs still carry. Drop the older
--- one once no open PR carries it.
--- @param comment_body string Comment body
--- @return boolean True when the first line is an accept verdict
local function is_accept(comment_body: string): boolean
  local body = comment_body or ""
  local first = body:match("^([^\n]*)")
  first = first:gsub("\r$", "")
  return first == "work-verdict: accept" or first == "plan-verdict: accept"
end

--- Pure: whether a label set places an issue in the landing queue, the
--- phase a landing exits. A landing is that exit, so `land` refuses an
--- issue in any other phase — it was never accepted.
--- @param labels {string} Label names on the issue
--- @return boolean True when the issue is in the land phase
local function in_landing_queue(labels: {string}): boolean
  return model.phase_of(labels) == "land"
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

--- show: print an issue's title, phase, URL, body verbatim, and every
--- conversation comment — the read half of the implementer loop (the
--- body IS the spec).
--- @param repo string "owner/name"
--- @param number integer Issue number
--- @return integer Exit code
local function cmd_show(repo: string, number: integer): integer
  local raw, err = gh.get_issue(repo, number)
  if raw == nil then
    io.stderr:write(err .. "\n")
    print("work-show: ERROR")
    return 1
  end
  local names: {string} = {}
  for _, l in ipairs(raw.labels or {}) do
    names[#names + 1] = l.name
  end
  local phase = model.phase_of(names)
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
  print((phase or "none") .. tags)
  print(raw.html_url)
  print("")
  print(raw.body or "")
  local comments, cerr = gh.list_issue_comments(repo, number)
  if comments == nil then
    io.stderr:write(cerr .. "\n")
    print("work-show: ERROR")
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
  print(("work-show: #%d %s"):format(raw.number, phase or "none"))
  return 0
end

--- land: verify a PR closes its issue, that the issue sits in the
--- `land` phase, and that the PR carries an accept verdict, then
--- squash-merge it — the write half of the implementer loop. The gates
--- that need no second API call (the closes reference, the PR's own
--- open/draft/merged state, both read off the one get_pull call) run
--- before the ones that do (the issue's phase, then the accept
--- comment, which needs the conversation fetched); the closes-
--- reference gate runs first of all, so a PR that does not even claim
--- to close the right issue refuses on that alone — even one long
--- since closed or merged — before anything resembling a merge is
--- attempted. A landing is the exit from the landing queue, so an
--- issue that never reached `land` was never accepted and cannot be
--- landed.
--- @param repo string "owner/name"
--- @param issue integer Issue number the PR must close
--- @param pr integer PR number to land
--- @return integer Exit code
local function cmd_land(repo: string, issue: integer, pr: integer): integer
  local raw, err = gh.get_pull(repo, pr)
  if raw == nil then
    io.stderr:write(err .. "\n")
    print("work-land: ERROR")
    return 1
  end
  if not closes(raw.body or "", issue) then
    print(("work-land: REFUSED (PR #%d body doesn't reference 'Closes #%d'; "
        .. "the landing must close the issue it claims)"):format(pr, issue))
    return 1
  end
  if raw.merged then
    print(("work-land: REFUSED (PR #%d is already merged)"):format(pr))
    return 1
  end
  if raw.state ~= "open" then
    print(("work-land: REFUSED (PR #%d is %s, not open)"):format(pr, raw.state))
    return 1
  end
  if raw.draft then
    print(("work-land: REFUSED (PR #%d is a draft; mark it ready for review "
        .. "— the REST API cannot)"):format(pr))
    return 1
  end
  local target, ierr = gh.get_issue(repo, issue)
  if target == nil then
    io.stderr:write(ierr .. "\n")
    print("work-land: ERROR")
    return 1
  end
  local names: {string} = {}
  for _, l in ipairs(target.labels or {}) do
    names[#names + 1] = l.name
  end
  if not in_landing_queue(names) then
    print(("work-land: REFUSED (#%d is in %s, not land; only accepted work "
        .. "sits in the landing queue)"):format(
        issue, model.phase_of(names) or "no phase"))
    return 1
  end
  local comments, cerr = gh.list_issue_comments(repo, pr)
  if comments == nil then
    io.stderr:write(cerr .. "\n")
    print("work-land: ERROR")
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
    print("work-land: REFUSED (no comment's first line is exactly "
      .. "'work-verdict: accept', or the older 'plan-verdict: accept')")
    return 1
  end
  if raw.mergeable_state ~= "clean" then
    print(("work-land: REFUSED (mergeable_state is %s; merge main, run the "
        .. "regen command the gate prints, push, and re-run land)"):format(
        raw.mergeable_state))
    return 1
  end
  local ok, merr = gh.merge_pull(repo, pr)
  if not ok then
    io.stderr:write(merr .. "\n")
    print("work-land: ERROR")
    return 1
  end
  print(("work-land: #%d via PR #%d"):format(issue, pr))
  return 0
end

local record implementer
  is_accept: function(comment_body: string): boolean
  in_landing_queue: function(labels: {string}): boolean
  closes: function(pr_body: string, issue: integer): boolean
  cmd_show: function(repo: string, number: integer): integer
  cmd_land: function(repo: string, issue: integer, pr: integer): integer
end

local M: implementer = {
  is_accept = is_accept,
  in_landing_queue = in_landing_queue,
  closes = closes,
  cmd_show = cmd_show,
  cmd_land = cmd_land,
}

return M
