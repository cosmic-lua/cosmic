#!/usr/bin/env cosmic
--- Plan board CLI: the kanban of plan:* labeled GitHub issues that
--- skills/plan/ operates. Verbs: status (the board and its WIP
--- verdict), next (the one action to take, per role), check (ready-bar
--- lint of an issue), move (column change, WIP-limited), edit (rewrite
--- a title/body in place), init (create the label vocabulary). Every
--- verb ends with a `plan-<verb>:` verdict line; read that, never a
--- piped exit status. WIP limits gate rightward motion and intake
--- only: a return (a leftward move) and a `new --finding` always land,
--- and an over-limit column blocks further pull until it drains.
---
---   cosmic --make run _plan/board.tl status [--repo OWNER/NAME]
---   cosmic --make run _plan/board.tl next [--role planner|implementer]
---   cosmic --make run _plan/board.tl check 123
---   cosmic --make run _plan/board.tl move 123 ready [--force]
---   cosmic --make run _plan/board.tl new "title" [--body-file F] [--epic]
---   cosmic --make run _plan/board.tl new "title" --finding
---   cosmic --make run _plan/board.tl edit 123 --body-file F [--title T]
---   cosmic --make run _plan/board.tl init
---
--- Auth is a GITHUB_TOKEN (or GH_TOKEN) env var — no gh CLI involved.
--- This file is the argument parsing and dispatch half; the verbs
--- themselves are `_plan.verbs`.

local flags = require("cosmic.flags")
local proc = require("cosmic.proc")
local gh = require("_plan.github")
local model = require("_plan.model")
local verbs = require("_plan.verbs")

local type Issue = model.Issue

local DEFAULT_REPO < const > = "whilp/cosmic"

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
    {name = "new", summary = "open a TITLE issue on the board (WIP-limited)",
      spec = {usage = "TITLE [options]", flags = {repo_flag(),
          {long = "body-file", arg = "FILE", help = "issue body markdown"},
          {long = "column", arg = "COL", default = "shaping",
            help = "target column (default shaping)"},
          {long = "epic", help = "mark as a decomposition parent"},
          {long = "enable", help = "mark as enablement work"},
          {long = "finding",
            help = "capture implementer evidence; lands even at the WIP limit"},
          {long = "force", help = "override the column WIP limit"}}}},
    {name = "edit", summary = "rewrite ISSUE's title and/or body in place",
      spec = {usage = "ISSUE [--body-file FILE] [--title TITLE]",
        flags = {repo_flag(),
          {long = "body-file", arg = "FILE", help = "replacement body markdown"},
          {long = "title", arg = "TITLE", help = "replacement title"}}}},
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
    return verbs.cmd_status(repo)
  end
  if d.command == "next" then
    return verbs.cmd_next(repo, d.parsed.values["role"] or "implementer")
  end
  if d.command == "check" then
    local n = math.tointeger(tonumber(d.parsed.args[1] or ""))
    if n == nil then
      io.stderr:write("check needs an issue number\n")
      return 1
    end
    return verbs.cmd_check(repo, n)
  end
  if d.command == "move" then
    local n = math.tointeger(tonumber(d.parsed.args[1] or ""))
    local target = d.parsed.args[2]
    if n == nil or target == nil then
      io.stderr:write("move needs an issue number and a column\n")
      return 1
    end
    return verbs.cmd_move(repo, n, target, d.parsed.switches["force"])
  end
  if d.command == "edit" then
    local n = math.tointeger(tonumber(d.parsed.args[1] or ""))
    if n == nil then
      io.stderr:write("edit needs an issue number\n")
      return 1
    end
    local body_file = d.parsed.values["body-file"]
    local title = d.parsed.values["title"]
    if body_file == nil and title == nil then
      io.stderr:write("edit needs --body-file and/or --title\n")
      return 1
    end
    return verbs.cmd_edit(repo, n, body_file, title)
  end
  if d.command == "new" then
    local title = d.parsed.args[1]
    if title == nil or title == "" then
      io.stderr:write("new needs a title\n")
      return 1
    end
    local column = d.parsed.values["column"] or "shaping"
    local known = false
    for _, c in ipairs(model.COLUMNS) do
      if c == column then
        known = true
      end
    end
    if not known then
      io.stderr:write("unknown column: " .. column .. " (expected "
        .. table.concat(model.COLUMNS, ", ") .. ")\n")
      return 1
    end
    return verbs.cmd_new(repo, title, d.parsed.values["body-file"], column,
      d.parsed.switches["epic"], d.parsed.switches["enable"],
      d.parsed.switches["finding"], d.parsed.switches["force"])
  end
  return verbs.cmd_init(repo)
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
  to_issue = verbs.to_issue,
}

return M
