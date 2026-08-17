#!/usr/bin/env cosmic
--- Work board CLI over a state REPOSITORY instead of GitHub labels: a
--- proof of concept where the hierarchy is first-class. Long-lived
--- ranked GOALS decompose into EPICS, epics into SLICES an
--- implementer pulls across the kanban; FINDINGS capture evidence
--- until a planner adopts them. Each item is `items/<id>.tl` in a git
--- checkout (`_work.store`), its spec prose the sidecar
--- `items/<id>.md`; the flow rules are `_work.flow`. Pull requests
--- stay on GitHub and carry the fix; issues shrink to an inbound
--- queue. Every verb ends with a `gitboard-<verb>:` verdict line.
---
---   cosmic --make run _work/gitboard.tl init [--dir D]
---   cosmic --make run _work/gitboard.tl new goal fast-startup "t" --rank 1
---   cosmic --make run _work/gitboard.tl new epic make-cache "t" --parent fast-startup
---   cosmic --make run _work/gitboard.tl new slice stamp-env "t" --parent make-cache
---   cosmic --make run _work/gitboard.tl spec stamp-env SPEC.md
---   cosmic --make run _work/gitboard.tl check stamp-env
---   cosmic --make run _work/gitboard.tl move stamp-env ready
---   cosmic --make run _work/gitboard.tl status | tree | next [--role R]
---   cosmic --make run _work/gitboard.tl verdict stamp-env accept [--pr N]
---   cosmic --make run _work/gitboard.tl done stamp-env [--reason not-planned]
---   cosmic --make run _work/gitboard.tl show stamp-env
---   cosmic --make run _work/gitboard.tl sync
---
--- This file is the argument parsing and dispatch half; the verbs
--- themselves are `_work.gitverbs`.
local flags = require("cosmic.flags")
local fs = require("cosmic.fs")
local proc = require("cosmic.proc")
local store = require("_work.store")
local verbs = require("_work.gitverbs")

local function dir_flag(): flags.Flag
  return {long = "dir", arg = "DIR", default = ".",
    help = "state repository checkout"}
end

local CSPEC: flags.CommandSpec = {
  name = "gitboard",
  summary = "the work kanban over committed item files (proof of concept)",
  commands = {
    {name = "init", summary = "create items/ (and a git repo if needed)",
      spec = {flags = {dir_flag()}}},
    {name = "new", summary = "open a KIND item named ID titled TITLE",
      spec = {usage = "KIND ID TITLE [options]", flags = {dir_flag(),
          {long = "parent", arg = "ID", help = "the item this decomposes"},
          {long = "rank", arg = "N", help = "goal rank (goals only)"},
          {long = "spec-file", arg = "FILE", help = "spec markdown sidecar"},
          {long = "force", help = "override the plan WIP limit"}}}},
    {name = "spec", summary = "replace ID's spec sidecar with FILE",
      spec = {usage = "ID FILE [options]", flags = {dir_flag()}}},
    {name = "check", summary = "ready-bar and hierarchy lint of ID",
      spec = {usage = "ID [options]", flags = {dir_flag()}}},
    {name = "status", summary = "render the slice kanban and its WIP verdict",
      spec = {flags = {dir_flag()}}},
    {name = "tree", summary = "render goals, their epics, and their slices",
      spec = {flags = {dir_flag()}}},
    {name = "next", summary = "the one next action for a role",
      spec = {flags = {dir_flag(),
          {long = "role", arg = "ROLE", default = "implementer",
            help = "planner or implementer"}}}},
    {name = "move", summary = "move slice ID to PHASE (WIP-limited)",
      spec = {usage = "ID PHASE [options]", flags = {dir_flag(),
          {long = "claim", arg = "SESSION", help = "record who took it"},
          {long = "force", help = "override the target WIP limit"}}}},
    {name = "verdict", summary = "record a review verdict; the move it implies follows",
      spec = {usage = "ID KIND [options]", flags = {dir_flag(),
          {long = "pr", arg = "N", help = "the PR the verdict judges"},
          {long = "head", arg = "SHA", help = "head commit it judges"}}}},
    {name = "done", summary = "end ID, recording why",
      spec = {usage = "ID [options]", flags = {dir_flag(),
          {long = "reason", arg = "REASON", default = "completed",
            help = "completed or not-planned"},
          {long = "force", help = "end a slice even from ready/do"}}}},
    {name = "show", summary = "print ID's fields, spec, and git history",
      spec = {usage = "ID [options]", flags = {dir_flag()}}},
    {name = "sync", summary = "rebase onto the remote's state",
      spec = {flags = {dir_flag()}}},
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
  if d.command == "init" then
    return verbs.cmd_init(d.parsed.values["dir"] or ".")
  end
  local s, serr = store.open(d.parsed.values["dir"] or ".")
  if s == nil then
    io.stderr:write(tostring(serr) .. "\n")
    return 1
  end
  if d.command == "status" then
    return verbs.cmd_status(s)
  end
  if d.command == "tree" then
    return verbs.cmd_tree(s)
  end
  if d.command == "next" then
    return verbs.cmd_next(s, d.parsed.values["role"] or "implementer")
  end
  if d.command == "sync" then
    return verbs.cmd_sync(s)
  end
  if d.command == "new" then
    local kind = d.parsed.args[1]
    local id = d.parsed.args[2]
    local title = d.parsed.args[3]
    if kind == nil or id == nil or title == nil or title == "" then
      io.stderr:write("new needs KIND ID TITLE\n")
      return 1
    end
    local rank = math.tointeger(tonumber(d.parsed.values["rank"] or "0")) or 0
    local spec: string = nil
    local spec_file = d.parsed.values["spec-file"]
    if spec_file ~= nil then
      local body, rerr = fs.read(spec_file)
      if body == nil then
        io.stderr:write(tostring(rerr) .. "\n")
        return 1
      end
      spec = body
    end
    return verbs.cmd_new(s, kind, id, title, d.parsed.values["parent"] or "",
      rank, spec, d.parsed.switches["force"])
  end
  local id = d.parsed.args[1]
  if id == nil or id == "" then
    io.stderr:write(d.command .. " needs an item id\n")
    return 1
  end
  if d.command == "spec" then
    local file = d.parsed.args[2]
    if file == nil then
      io.stderr:write("spec needs a markdown file\n")
      return 1
    end
    return verbs.cmd_spec(s, id, file)
  end
  if d.command == "check" then
    return verbs.cmd_check(s, id)
  end
  if d.command == "move" then
    local target = d.parsed.args[2]
    if target == nil then
      io.stderr:write("move needs a phase\n")
      return 1
    end
    return verbs.cmd_move(s, id, target, d.parsed.values["claim"],
      d.parsed.switches["force"])
  end
  if d.command == "verdict" then
    local kind = d.parsed.args[2]
    if kind == nil then
      io.stderr:write("verdict needs a kind: accept, request changes, reject\n")
      return 1
    end
    local pr = math.tointeger(tonumber(d.parsed.values["pr"] or "0")) or 0
    return verbs.cmd_verdict(s, id, kind, pr, d.parsed.values["head"] or "")
  end
  if d.command == "done" then
    return verbs.cmd_done(s, id, d.parsed.values["reason"] or "completed",
      d.parsed.switches["force"])
  end
  return verbs.cmd_show(s, id)
end

if proc.is_main() then
  os.exit(main(...))
end

local record gitboard
  main: function(...: string): integer
end

local M: gitboard = {
  main = main,
}

return M
