#!/usr/bin/env cosmic
--- Plan board CLI: the kanban of plan:* labeled GitHub issues that
--- skills/plan/ operates. Verbs: status (the board and its WIP
--- verdict), next (the one action to take, per role), check (ready-bar
--- lint of an issue), move (column change, WIP-limited), init (create
--- the label vocabulary). Every verb ends with a `plan-<verb>:`
--- verdict line; read that, never a piped exit status.
---
---   cosmic --make run _plan/board.tl status [--repo OWNER/NAME]
---   cosmic --make run _plan/board.tl next [--role planner|implementer]
---   cosmic --make run _plan/board.tl check 123
---   cosmic --make run _plan/board.tl move 123 ready [--force]
---   cosmic --make run _plan/board.tl init

local flags = require("cosmic.flags")
local proc = require("cosmic.proc")
local gh = require("_plan.gh")
local model = require("_plan.model")

local type Issue = model.Issue
local type Board = model.Board

local DEFAULT_REPO < const > = "whilp/cosmic"

--- Label colors for init, one entry per label the board uses.
local LABELS: {{string}} = {
  {"plan:shaping", "FBCA04", "traced to a goal, still ambiguous"},
  {"plan:ready", "0E8A16", "meets the ready bar; pullable"},
  {"plan:doing", "1D76DB", "claimed by an implementer session"},
  {"plan:review", "5319E7", "PR open; awaiting planner review"},
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
    url = raw.url,
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
    problems[#problems + 1] = "missing: " .. table.concat(gaps, ", ")
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

local function repo_flag(): flags.Flag
  return {long = "repo", arg = "OWNER/NAME",
    help = "board repository", default = DEFAULT_REPO}
end

local CSPEC: flags.CommandSpec = {
  name = "board",
  summary = "the plan kanban over plan:* labeled GitHub issues",
  commands = {
    {name = "status", summary = "render the board and its WIP verdict",
      spec = {flags = {repo_flag()}}},
    {name = "next", summary = "the one next action for a role",
      spec = {flags = {repo_flag(),
          {long = "role", arg = "ROLE", default = "implementer",
            help = "planner or implementer"}}}},
    {name = "check", summary = "ready-bar lint of ISSUE",
      spec = {usage = "ISSUE [options]", flags = {repo_flag()}}},
    {name = "move", summary = "move ISSUE to COLUMN (WIP-limited)",
      spec = {usage = "ISSUE COLUMN [options]", flags = {repo_flag(),
          {long = "force", help = "override the target WIP limit"}}}},
    {name = "init", summary = "create the plan:* labels",
      spec = {flags = {repo_flag()}}},
  },
}

--- CLI entry point.
--- @param ... string Command-line arguments
--- @return integer Exit code
local function main(...: string): integer
  local d, derr = flags.command(CSPEC, {...})
  if d == nil then
    io.stderr:write(tostring(derr) .. "\n")
    io.stderr:write(flags.command_help(CSPEC))
    return 1
  end
  if d.help or d.command == nil then
    print(flags.command_help(CSPEC, d.command))
    return 0
  end
  local repo = d.parsed.values["repo"] or DEFAULT_REPO
  if d.command == "status" then
    return cmd_status(repo)
  end
  if d.command == "next" then
    return cmd_next(repo, d.parsed.values["role"] or "implementer")
  end
  if d.command == "check" then
    local n = math.tointeger(tonumber(d.parsed.args[1] or ""))
    if n == nil then
      io.stderr:write("check needs an issue number\n")
      return 1
    end
    return cmd_check(repo, n)
  end
  if d.command == "move" then
    local n = math.tointeger(tonumber(d.parsed.args[1] or ""))
    local target = d.parsed.args[2]
    if n == nil or target == nil then
      io.stderr:write("move needs an issue number and a column\n")
      return 1
    end
    return cmd_move(repo, n, target, d.parsed.switches["force"])
  end
  return cmd_init(repo)
end

if proc.is_main() then
  os.exit(main(...))
end

local record board
  main: function(...: string): integer
  to_issue: function(raw: gh.RawIssue): Issue
end

local M: board = {
  main = main,
  to_issue = to_issue,
}

return M
