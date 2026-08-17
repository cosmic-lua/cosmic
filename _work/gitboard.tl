#!/usr/bin/env cosmic
--- Work board CLI over a state REPOSITORY instead of GitHub labels: a
--- proof of concept where roles emerge from the dependency graph.
--- There are no kinds — a ranked root is a goal, an unranked root is
--- a finding awaiting triage, a parented item with open children is a
--- container being decomposed, and a parented leaf is workable: the
--- only thing that crosses the kanban. Each item is `items/<ksuid>.tl`
--- in a git checkout (`_work.store`), its spec prose the sidecar
--- `items/<ksuid>.md`; the flow rules are `_work.flow`. Pull requests
--- stay on GitHub and carry the fix; issues shrink to an inbound
--- queue. Ids are KSUIDs; every verb accepts an unambiguous prefix.
---
---   cosmic --make run _work/gitboard.tl init [--dir D]
---   cosmic --make run _work/gitboard.tl new "a goal" --rank 1
---   cosmic --make run _work/gitboard.tl new "a piece of it" --parent 2ai3
---   cosmic --make run _work/gitboard.tl attach 2akQ 2ai3
---   cosmic --make run _work/gitboard.tl block 2akQ 2ai3 | unblock 2akQ 2ai3
---   cosmic --make run _work/gitboard.tl spec 2akQ SPEC.md
---   cosmic --make run _work/gitboard.tl check 2akQ
---   cosmic --make run _work/gitboard.tl move 2akQ check --pr 42
---   cosmic --make run _work/gitboard.tl status | tree | next [--role R]
---   cosmic --make run _work/gitboard.tl verdict 2akQ accept [--pr N]
---   cosmic --make run _work/gitboard.tl done 2akQ [--reason not-planned]
---   cosmic --make run _work/gitboard.tl show 2akQ
---   cosmic --make run _work/gitboard.tl sync
---
--- This file is the argument parsing, prefix resolution, and dispatch
--- half; the verbs themselves are `_work.gitverbs`.
local flags = require("cosmic.flags")
local fs = require("cosmic.fs")
local proc = require("cosmic.proc")
local store = require("_work.store")
local verbs = require("_work.gitverbs")
local vrd = require("_work.gitverdict")
local view = require("_work.gitview")

--- The verbs that write. Each one publishes, so each needs the
--- remote's state before it reads the board at all: mutating a stale
--- checkout produces a change computed against items someone else has
--- already moved. Reads stay local and offline, and are as current as
--- the last sync.
local MUTATES: {string: boolean} = {
  ["new"] = true, ["attach"] = true, ["block"] = true, ["unblock"] = true,
  ["spec"] = true, ["move"] = true, ["verdict"] = true, ["done"] = true,
}

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
    {name = "new", summary = "open an item titled TITLE; role comes from the graph",
      spec = {usage = "TITLE [options]", flags = {dir_flag(),
          {long = "parent", arg = "ID", help = "the item this decomposes"},
          {long = "rank", arg = "N", help = "rank a parentless item as a goal"},
          {long = "spec-file", arg = "FILE", help = "spec markdown sidecar"},
          {long = "force", help = "override the plan WIP limit"},
          {long = "why", arg = "REASON", help = "why --force was needed"}}}},
    {name = "attach", summary = "put ID under PARENT (triage a finding, re-parent)",
      spec = {usage = "ID PARENT [options]", flags = {dir_flag()}}},
    {name = "block", summary = "record that ID waits on BLOCKER",
      spec = {usage = "ID BLOCKER [options]", flags = {dir_flag()}}},
    {name = "unblock", summary = "drop BLOCKER from ID's blockers",
      spec = {usage = "ID BLOCKER [options]", flags = {dir_flag()}}},
    {name = "spec", summary = "replace ID's spec sidecar with FILE",
      spec = {usage = "ID FILE [options]", flags = {dir_flag()}}},
    {name = "check", summary = "ready-bar and graph lint of ID",
      spec = {usage = "ID [options]", flags = {dir_flag()}}},
    {name = "status", summary = "render the kanban and its WIP verdict",
      spec = {flags = {dir_flag()}}},
    {name = "tree", summary = "render goals, their subtrees, and the triage queue",
      spec = {flags = {dir_flag()}}},
    {name = "next", summary = "the one next action for a role",
      spec = {flags = {dir_flag(),
          {long = "role", arg = "ROLE", default = "implementer",
            help = "planner or implementer"},
          {long = "session", arg = "SESSION",
            help = "this session; skips do items another session claimed"}}}},
    {name = "move", summary = "move workable ID to PHASE (WIP-limited)",
      spec = {usage = "ID PHASE [options]", flags = {dir_flag(),
          {long = "claim", arg = "SESSION", help = "record who took it"},
          {long = "pr", arg = "N", help = "the PR carrying the work"},
          {long = "force", help = "override the target WIP limit"},
          {long = "why", arg = "REASON", help = "why --force was needed"}}}},
    {name = "verdict", summary = "record a review verdict; the move it implies follows",
      spec = {usage = "ID KIND [options]", flags = {dir_flag(),
          {long = "pr", arg = "N", help = "the PR the verdict judges"},
          {long = "head", arg = "SHA", help = "head commit it judges"},
          {long = "enable", arg = "VALUE",
            help = "countermeasure a non-accept verdict files: ID or 'none: why'"}}}},
    {name = "done", summary = "end ID, recording why",
      spec = {usage = "ID [options]", flags = {dir_flag(),
          {long = "reason", arg = "REASON", default = "completed",
            help = "completed or not-planned"},
          {long = "force", help = "end an item even from ready/do"},
          {long = "why", arg = "REASON", help = "why --force was needed"}}}},
    {name = "show", summary = "print ID's fields, role, spec, and git history",
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
  if MUTATES[d.command] then
    local synced, syerr = store.sync(s)
    if not synced then
      io.stderr:write(("gitboard-%s: could not sync before mutating: %s\n")
        :format(d.command, syerr))
      return 1
    end
  end
  if d.command == "status" then
    return view.cmd_status(s)
  end
  if d.command == "tree" then
    return view.cmd_tree(s)
  end
  if d.command == "next" then
    return view.cmd_next(s, d.parsed.values["role"] or "implementer",
      d.parsed.values["session"] or "")
  end
  if d.command == "sync" then
    return verbs.cmd_sync(s)
  end
  if d.command == "new" then
    local title = d.parsed.args[1]
    if title == nil or title == "" then
      io.stderr:write("new needs a title\n")
      return 1
    end
    local rank = math.tointeger(tonumber(d.parsed.values["rank"] or "0")) or 0
    local parent = ""
    local parent_prefix = d.parsed.values["parent"]
    if parent_prefix ~= nil then
      local resolved, perr = store.resolve(s, parent_prefix)
      if resolved == nil then
        io.stderr:write(tostring(perr) .. "\n")
        return 1
      end
      parent = resolved
    end
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
    return verbs.cmd_new(s, title, parent, rank, spec,
      d.parsed.switches["force"], d.parsed.values["why"] or "")
  end
  local id, rerr = store.resolve(s, d.parsed.args[1] or "")
  if id == nil then
    io.stderr:write(tostring(rerr) .. "\n")
    return 1
  end
  if d.command == "attach" then
    local parent, perr = store.resolve(s, d.parsed.args[2] or "")
    if parent == nil then
      io.stderr:write(tostring(perr) .. "\n")
      return 1
    end
    return verbs.cmd_attach(s, id, parent)
  end
  if d.command == "block" or d.command == "unblock" then
    local blocker, berr = store.resolve(s, d.parsed.args[2] or "")
    if blocker == nil then
      io.stderr:write(tostring(berr) .. "\n")
      return 1
    end
    return verbs.cmd_block(s, id, blocker, d.command == "unblock")
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
    local pr = math.tointeger(tonumber(d.parsed.values["pr"] or "0")) or 0
    return verbs.cmd_move(s, id, target, d.parsed.values["claim"], pr,
      d.parsed.switches["force"], d.parsed.values["why"] or "")
  end
  if d.command == "verdict" then
    local kind = d.parsed.args[2]
    if kind == nil then
      io.stderr:write("verdict needs a kind: accept, request changes, reject\n")
      return 1
    end
    local pr = math.tointeger(tonumber(d.parsed.values["pr"] or "0")) or 0
    return vrd.cmd_verdict(s, id, kind, pr, d.parsed.values["head"] or "",
      d.parsed.values["enable"] or "")
  end
  if d.command == "done" then
    return verbs.cmd_done(s, id, d.parsed.values["reason"] or "completed",
      d.parsed.switches["force"], d.parsed.values["why"] or "")
  end
  return view.cmd_show(s, id)
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
