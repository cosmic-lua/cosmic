--- Plan board verbs: the implementation behind every `_plan/board.tl`
--- subcommand. Each cmd_* takes plain arguments, prints its own output
--- including the trailing `plan-<verb>:` verdict line, and returns the
--- process exit code. Argument parsing and dispatch live in board.tl.

local fs = require("cosmic.fs")
local gh = require("_plan.github")
local model = require("_plan.model")

local type Issue = model.Issue
local type Board = model.Board

--- Label colors for init, one entry per label the board uses.
local LABELS: {{string}} = {
  {"plan:shaping", "FBCA04", "traced to a goal, still ambiguous"},
  {"plan:ready", "0E8A16", "meets the ready bar; pullable"},
  {"plan:doing", "1D76DB", "in implementation: claimed work and rework"},
  {"plan:review", "5319E7", "PR open; awaiting a planner verdict"},
  {"plan:epic", "C5DEF5", "decomposition parent; never pulled"},
  {"plan:enable", "F9D0C4", "exists to make implementers succeed"},
}

--- Reduce a gh issue to the model's shape.
--- @param raw gh.RawIssue The issue as gh returned it
--- @return Issue The board's view of it
local function to_issue(raw: gh.RawIssue): Issue
  local names: {string} = {}
  for _, l in ipairs(raw.labels or {}) do
    names[#names + 1] = l.name
  end
  local assignee: string = nil
  if raw.assignees and raw.assignees[1] then
    assignee = raw.assignees[1].login
  end
  return {
    number = raw.number,
    title = raw.title,
    column = model.column_of(names),
    epic = model.has_marker(names, "epic"),
    enable = model.has_marker(names, "enable"),
    assignee = assignee,
    url = raw.html_url,
    body = raw.body or "",
  }
end

--- Fetch the whole board, one list call per column.
--- @param repo string "owner/name"
--- @return Board | nil The board
--- @return string Error message on failure
local function fetch_board(repo: string): Board, string
  local board: Board = {}
  for _, col in ipairs(model.COLUMNS) do
    local raw, err = gh.list_issues(repo, "plan:" .. col)
    if raw == nil then
      return nil, ("listing %s: %s"):format(col, err)
    end
    local list: {Issue} = {}
    for _, r in ipairs(raw) do
      list[#list + 1] = to_issue(r)
    end
    board[col] = list
  end
  return board, nil
end

--- A blocker-state oracle over one repo, memoized per issue number.
--- @param repo string "owner/name"
--- @return model.IsOpen The oracle (unfetchable blockers read as open)
local function open_oracle(repo: string): model.IsOpen
  local cache: {integer: boolean} = {}
  return function(n: integer): boolean
    if cache[n] ~= nil then
      return cache[n]
    end
    local raw = gh.get_issue(repo, n)
    local open = raw == nil or (raw.state or ""):upper() == "OPEN"
    cache[n] = open
    return open
  end
end

--- One board line: "#123 title [epic] [enable] (assignee)".
--- @param i Issue The issue
--- @return string The rendered line
local function issue_line(i: Issue): string
  local tags = ""
  if i.epic then
    tags = tags .. " [epic]"
  end
  if i.enable then
    tags = tags .. " [enable]"
  end
  if i.assignee then
    tags = tags .. " (" .. i.assignee .. ")"
  end
  return ("  #%d %s%s"):format(i.number, i.title, tags)
end

--- status: render the board right to left and verdict on WIP.
--- @param repo string "owner/name"
--- @return integer Exit code
local function cmd_status(repo: string): integer
  local board, err = fetch_board(repo)
  if board == nil then
    io.stderr:write(err .. "\n")
    print("plan-board: ERROR")
    return 1
  end
  print("plan board — " .. repo .. " (pull right to left)")
  for idx = #model.COLUMNS, 1, -1 do
    local col = model.COLUMNS[idx]
    local list = model.oldest_first(board, col)
    print(("%s %d/%d"):format(col, #list, model.LIMITS[col]))
    for _, i in ipairs(list) do
      print(issue_line(i))
    end
  end
  local violations = model.wip_violations(board)
  if #violations > 0 then
    print("plan-board: ATTENTION (" .. table.concat(violations, "; ") .. ")")
    return 1
  end
  print("plan-board: OK")
  return 0
end

--- next: the one action for a role.
--- @param repo string "owner/name"
--- @param role string "planner" or "implementer"
--- @return integer Exit code
local function cmd_next(repo: string, role: string): integer
  local board, err = fetch_board(repo)
  if board == nil then
    io.stderr:write(err .. "\n")
    print("plan-next: ERROR")
    return 1
  end
  local action, aerr = model.next_action(board, role, open_oracle(repo))
  if action == nil then
    io.stderr:write(aerr .. "\n")
    print("plan-next: ERROR")
    return 1
  end
  if action.issue then
    print(("next (%s): %s #%d — %s"):format(
        role, action.kind, action.issue.number, action.issue.title))
    print("  " .. action.issue.url)
  else
    print(("next (%s): %s"):format(role, action.kind))
  end
  print("  rule: " .. action.reason)
  if action.alt then
    print(("  fallback: #%d — %s"):format(action.alt.number, action.alt.title))
  end
  if action.issue then
    print(("plan-next: %s #%d"):format(action.kind, action.issue.number))
  else
    print("plan-next: " .. action.kind)
  end
  return 0
end

--- check: ready-bar lint of one issue body plus its blocker states.
--- @param repo string "owner/name"
--- @param number integer Issue number
--- @return integer Exit code
local function cmd_check(repo: string, number: integer): integer
  local raw, err = gh.get_issue(repo, number)
  if raw == nil then
    io.stderr:write(err .. "\n")
    print("plan-check: ERROR")
    return 1
  end
  local issue = to_issue(raw)
  local problems: {string} = {}
  local gaps = model.ready_gaps(issue.body)
  if #gaps > 0 then
    problems[#problems + 1] = "missing or empty: " .. table.concat(gaps, ", ")
  end
  local is_open = open_oracle(repo)
  for _, b in ipairs(model.blockers(issue.body)) do
    if is_open(b) then
      problems[#problems + 1] = ("blocked by open #%d"):format(b)
    end
  end
  if issue.epic then
    problems[#problems + 1] = "is an epic (never marked ready; decompose it)"
  end
  if #problems > 0 then
    print("plan-check: FAIL (" .. table.concat(problems, "; ") .. ")")
    return 1
  end
  print("plan-check: PASS")
  return 0
end

--- move: change an issue's column, refusing to overfill the target.
--- @param repo string "owner/name"
--- @param number integer Issue number
--- @param target string Target column
--- @param force boolean True to override the WIP limit
--- @return integer Exit code
local function cmd_move(repo: string, number: integer, target: string,
    force: boolean): integer
  local known = false
  for _, c in ipairs(model.COLUMNS) do
    if c == target then
      known = true
    end
  end
  if not known then
    io.stderr:write("unknown column: " .. target .. " (expected "
      .. table.concat(model.COLUMNS, ", ") .. ")\n")
    print("plan-move: ERROR")
    return 1
  end
  local board, berr = fetch_board(repo)
  if board == nil then
    io.stderr:write(berr .. "\n")
    print("plan-move: ERROR")
    return 1
  end
  local count = #(board[target] or {})
  if count >= model.LIMITS[target] and not force then
    print(("plan-move: REFUSED (%s %d/%d at limit; work right to left "
        .. "to drain it, or --force)"):format(
        target, count, model.LIMITS[target]))
    return 1
  end
  if target == "ready" and not force then
    local raw, gerr = gh.get_issue(repo, number)
    if raw == nil then
      io.stderr:write(gerr .. "\n")
      print("plan-move: ERROR")
      return 1
    end
    local issue = to_issue(raw)
    local problems: {string} = {}
    local gaps = model.ready_gaps(issue.body)
    if #gaps > 0 then
      problems[#problems + 1] = "missing or empty: " .. table.concat(gaps, ", ")
    end
    if issue.epic then
      problems[#problems + 1] = "is an epic (decompose it instead)"
    end
    if #problems > 0 then
      print("plan-move: REFUSED (ready bar: "
        .. table.concat(problems, "; ") .. ")")
      return 1
    end
  end
  local remove: {string} = {}
  for _, c in ipairs(model.COLUMNS) do
    if c ~= target then
      remove[#remove + 1] = "plan:" .. c
    end
  end
  local ok, err = gh.edit_labels(repo, number, {"plan:" .. target}, remove)
  if not ok then
    io.stderr:write(err .. "\n")
    print("plan-move: ERROR")
    return 1
  end
  print(("plan-move: #%d -> %s"):format(number, target))
  return 0
end

--- The default body for a new issue: the ready bar's own skeleton,
--- so refinement fills sections in rather than remembering them.
local TEMPLATE < const > = [[
## Goal

## Change

## Non-goals

## Acceptance

## Enablement
]]

--- new: open an issue on the board, WIP-limited like any other entry.
--- @param repo string "owner/name"
--- @param title string Issue title
--- @param body_file string Path to a body markdown file; nil for the template
--- @param column string Target column
--- @param epic boolean Mark as a decomposition parent
--- @param enable boolean Mark as enablement work
--- @param force boolean True to override the column WIP limit
--- @return integer Exit code
local function cmd_new(repo: string, title: string, body_file: string,
    column: string, epic: boolean, enable: boolean, force: boolean): integer
  local body = TEMPLATE
  if body_file then
    local data, rerr = fs.read(body_file)
    if data == nil then
      io.stderr:write(rerr .. "\n")
      print("plan-new: ERROR")
      return 1
    end
    body = data
  end
  local board, berr = fetch_board(repo)
  if board == nil then
    io.stderr:write(berr .. "\n")
    print("plan-new: ERROR")
    return 1
  end
  local count = #(board[column] or {})
  if count >= model.LIMITS[column] and not force then
    print(("plan-new: REFUSED (%s %d/%d at limit; drain the board "
        .. "right to left first, or --force)"):format(
        column, count, model.LIMITS[column]))
    return 1
  end
  local labels: {string} = {"plan:" .. column}
  if epic then
    labels[#labels + 1] = "plan:epic"
  end
  if enable then
    labels[#labels + 1] = "plan:enable"
  end
  local raw, err = gh.create_issue(repo, title, body, labels)
  if raw == nil then
    io.stderr:write(err .. "\n")
    print("plan-new: ERROR")
    return 1
  end
  print("  " .. raw.html_url)
  print(("plan-new: #%d %s"):format(raw.number, column))
  return 0
end

--- init: create the label vocabulary, idempotently.
--- @param repo string "owner/name"
--- @return integer Exit code
local function cmd_init(repo: string): integer
  for _, l in ipairs(LABELS) do
    local ok, err = gh.ensure_label(repo, l[1], l[2], l[3])
    if not ok then
      io.stderr:write(l[1] .. ": " .. err .. "\n")
      print("plan-init: ERROR")
      return 1
    end
    print("  " .. l[1])
  end
  print("plan-init: OK")
  return 0
end

local record verbs
  to_issue: function(raw: gh.RawIssue): Issue
  cmd_status: function(repo: string): integer
  cmd_next: function(repo: string, role: string): integer
  cmd_check: function(repo: string, number: integer): integer
  cmd_move: function(repo: string, number: integer, target: string,
  force: boolean): integer
  cmd_new: function(repo: string, title: string, body_file: string,
  column: string, epic: boolean, enable: boolean, force: boolean): integer
  cmd_init: function(repo: string): integer
end

local M: verbs = {
  to_issue = to_issue,
  cmd_status = cmd_status,
  cmd_next = cmd_next,
  cmd_check = cmd_check,
  cmd_move = cmd_move,
  cmd_new = cmd_new,
  cmd_init = cmd_init,
}

return M
