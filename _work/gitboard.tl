#!/usr/bin/env cosmic
--- Work board CLI over a state REPOSITORY instead of GitHub labels: a
--- proof of concept where roles emerge from the dependency graph.
--- There are no kinds and no goal tier — an item with open children
--- is a container being decomposed, a childless root is awaiting
--- triage, and a parented leaf is workable: the only thing that
--- crosses the kanban. Which items matter more is a recorded
--- comparison (`compare`), derived into an order by `_work.priority`,
--- never a number an item asserts about itself. Each item is `items/<ksuid>.tl`
--- in a git checkout (`_work.store`), its spec prose the sidecar
--- `items/<ksuid>.md`; the flow rules are `_work.flow`. Pull requests
--- stay on GitHub and carry the fix; issues shrink to an inbound
--- queue. Ids are KSUIDs; renders lead with the handle, the id's last
--- 8 characters (e.g. «d0x1_37YJ»); every verb accepts that handle,
--- bare or wrapped, either divider, case-tolerant — or an unambiguous prefix.
---
---   cosmic --make run _work/gitboard.tl init [--dir D]
---   cosmic --make run _work/gitboard.tl new "an outcome"
---   cosmic --make run _work/gitboard.tl new "a piece of it" --parent 2ai3
---   cosmic --make run _work/gitboard.tl compare 2ai3 2akQ
---   cosmic --make run _work/gitboard.tl attach 2akQ 2ai3
---   cosmic --make run _work/gitboard.tl block 2akQ 2ai3 | unblock 2akQ 2ai3
---   cosmic --make run _work/gitboard.tl spec 2akQ SPEC.md
---   cosmic --make run _work/gitboard.tl show [2akQ]
---   cosmic --make run _work/gitboard.tl next [--session S]
---   cosmic --make run _work/gitboard.tl take 2akQ [--pr 42]
---   cosmic --make run _work/gitboard.tl drop 2akQ --why "the gap"
---   cosmic --make run _work/gitboard.tl verdict 2akQ accept [--pr N]
---   cosmic --make run _work/gitboard.tl done 2akQ [--reason not-planned]
---   cosmic --make run _work/gitboard.tl sync
---
--- This file is the argument parsing, prefix resolution, and dispatch
--- half; the verbs themselves are `_work.gitverbs` (the state
--- verbs) and `_work.gitgraph` (the graph mutations).
local flags = require("cosmic.flags")
local fs = require("cosmic.fs")
local proc = require("cosmic.proc")
local cmp = require("_work.gitcompare")
local graph = require("_work.gitgraph")
local session = require("_work.session")
local store = require("_work.store")
local tail = require("_work.tail")
local verbs = require("_work.gitverbs")
local vrd = require("_work.gitverdict")
local show = require("_work.gitshow")
local view = require("_work.gitview")

--- The verbs that write. Each one publishes, so each needs the
--- remote's state before it reads the board at all: mutating a stale
--- checkout produces a change computed against items someone else has
--- already moved. Reads stay local and offline, and are as current as
--- the last sync.
local MUTATES: {string: boolean} = {
  ["new"] = true, ["attach"] = true, ["block"] = true, ["unblock"] = true,
  ["spec"] = true, ["take"] = true, ["drop"] = true, ["verdict"] = true,
  ["done"] = true, ["compare"] = true,
}

local function dir_flag(): flags.Flag
  return {long = "dir", arg = "DIR", default = ".",
    help = "state repository checkout"}
end

--- Resolve one id-taking argument, whatever position it sits in: an
--- id prefix is tried first; only when that refuses AND the input has
--- a tail's shape (8 base62 characters, one optional hyphen, either
--- bare or guillemet-wrapped) does a board-wide tail search follow —
--- so a plain id-prefix typo still gets store.resolve's own message.
--- Every id-taking argument (the first, and PARENT/OTHER/BLOCKER)
--- routes through this so a rendered handle resolves in any position.
--- @param s store.Store The store
--- @param input string What a session typed
--- @return string | nil The resolved item id
--- @return string Error message
local function resolve_id(s: store.Store, input: string): string | nil, string
  local id, rerr = store.resolve(s, input)
  if id == nil and tail.is_tail_shape(input) then
    local all, aerr = store.list(s)
    if all == nil then
      return nil, aerr
    end
    id, rerr = tail.resolve(all, input)
  end
  return id, rerr
end

local CSPEC: flags.CommandSpec = {
  name = "gitboard",
  summary = "the work board over committed item files: todo, doing, done",
  commands = {
    {name = "init", summary = "create items/ (and a git repo if needed)",
      spec = {flags = {dir_flag()}}},
    {name = "new", summary = "open an item titled TITLE; role comes from the graph",
      spec = {usage = "TITLE [options]", flags = {dir_flag(),
          {long = "parent", arg = "ID", help = "the item this decomposes"},
          {long = "spec-file", arg = "FILE", help = "spec markdown sidecar"},
          {long = "repo", arg = "OWNER/NAME",
            help = "the repo its PR lands in; default is the board's origin"}}}},
    {name = "attach", summary = "put ID under PARENT (adopt, re-parent)",
      spec = {usage = "ID PARENT [options]", flags = {dir_flag()}}},
    {name = "compare", summary = "record that ID outranks OTHER "
      .. "(a standing reverse edge is reversed)",
      spec = {usage = "ID OTHER [options]", flags = {dir_flag()}}},
    {name = "block", summary = "record that ID waits on BLOCKER",
      spec = {usage = "ID BLOCKER [options]", flags = {dir_flag(),
          {long = "reason", arg = "WHY",
            help = "what concretely cannot proceed until BLOCKER ends"}}}},
    {name = "unblock", summary = "drop BLOCKER from ID's blockers",
      spec = {usage = "ID BLOCKER [options]", flags = {dir_flag()}}},
    {name = "spec", summary = "replace ID's spec sidecar with FILE",
      spec = {usage = "ID FILE [options]", flags = {dir_flag(),
          {long = "base", arg = "FILE",
            help = "the spec text you read, as the compare-and-swap base"},
          {long = "session", arg = "SESSION",
            help = "the session making the write. Omit to derive it from "
            .. "the environment"},
          {long = "force", help = "rewrite another session's LIVE claim's "
            .. "spec (a stale one needs no force)"},
          {long = "why", arg = "REASON", help = "why --force was needed"}}}},
    {name = "next", summary = "the one next action to take now, and what "
      .. "the kind of action means",
      spec = {flags = {dir_flag(),
          {long = "session", arg = "SESSION",
            help = "this session; steps over anything another session "
            .. "has claimed, work and reviews alike. Omit to derive it "
            .. "from the environment (GITBOARD_SESSION, else a runner's "
            .. "own id)"}}}},
    {name = "take", summary = "claim ID: the pull (spec bar and doing "
      .. "bound apply), its review when it awaits a verdict, or record "
      .. "its PR",
      spec = {usage = "ID [options]", flags = {dir_flag(),
          {long = "session", arg = "SESSION",
            help = "the claiming session. Omit to derive it from the "
            .. "environment"},
          {long = "pr", arg = "N",
            help = "record the PR that hands the build over for review"},
          {long = "force", help = "take over another session's LIVE claim "
            .. "(a stale one needs no force), or skip the take gates"},
          {long = "why", arg = "REASON", help = "why --force was needed"}}}},
    {name = "drop", summary = "release ID back to todo, the gap named",
      spec = {usage = "ID [options]", flags = {dir_flag(),
          {long = "why", arg = "REASON",
            help = "what the spec cannot answer; the next session refines "
            .. "from it"},
          {long = "session", arg = "SESSION",
            help = "the dropping session. Omit to derive it from the "
            .. "environment"},
          {long = "force", help = "drop another session's live claim"}}}},
    {name = "verdict", summary = "record a review verdict; its effect follows",
      spec = {usage = "ID KIND [options]", flags = {dir_flag(),
          {long = "pr", arg = "N", help = "the PR the verdict judges"},
          {long = "head", arg = "SHA", help = "head commit it judges"},
          {long = "session", arg = "SESSION",
            help = "the reviewing session; it rides in the commit "
            .. "subject. Omit to derive it from the environment"}}}},
    {name = "done", summary = "end ID, recording why (an accepted PR is "
      .. "verified merged first)",
      spec = {usage = "ID [options]", flags = {dir_flag(),
          {long = "reason", arg = "REASON", default = "completed",
            help = "completed or not-planned"},
          {long = "force", help = "end an item under an unjudged PR, or "
            .. "without reading its merge"},
          {long = "why", arg = "REASON", help = "why --force was needed"}}}},
    {name = "show", summary = "the board (no ID), or one item: fields, "
      .. "spec-bar problems, spec, git history",
      spec = {usage = "[ID] [options]", flags = {dir_flag()}}},
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
  if d.command == "next" then
    local who = session.resolve(d.parsed.values["session"])
    return view.cmd_next(s, who)
  end
  if d.command == "sync" then
    return verbs.cmd_sync(s)
  end
  -- Bare `show` is the board; `show ID` is one item, resolved below
  -- with every other id-taking verb.
  if d.command == "show" and (d.parsed.args[1] or "") == "" then
    return view.cmd_status(s)
  end
  if d.command == "new" then
    local title = d.parsed.args[1]
    if title == nil or title == "" then
      io.stderr:write("new needs a title\n")
      return 1
    end
    local parent = ""
    local parent_prefix = d.parsed.values["parent"]
    if parent_prefix ~= nil then
      local resolved, perr = resolve_id(s, parent_prefix)
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
    return graph.cmd_new(s, title, parent, spec, d.parsed.values["repo"] or "")
  end
  local input = d.parsed.args[1] or ""
  local id, rerr = resolve_id(s, input)
  if id == nil then
    io.stderr:write(tostring(rerr) .. "\n")
    return 1
  end
  if d.command == "attach" then
    local parent, perr = resolve_id(s, d.parsed.args[2] or "")
    if parent == nil then
      io.stderr:write(tostring(perr) .. "\n")
      return 1
    end
    return graph.cmd_attach(s, id, parent)
  end
  if d.command == "compare" then
    local other, oerr = resolve_id(s, d.parsed.args[2] or "")
    if other == nil then
      io.stderr:write(tostring(oerr) .. "\n")
      return 1
    end
    return cmp.cmd_compare(s, id, other)
  end
  if d.command == "block" or d.command == "unblock" then
    local blocker, berr = resolve_id(s, d.parsed.args[2] or "")
    if blocker == nil then
      io.stderr:write(tostring(berr) .. "\n")
      return 1
    end
    return graph.cmd_block(s, id, blocker, d.command == "unblock",
      d.parsed.values["reason"] or "")
  end
  if d.command == "spec" then
    local file = d.parsed.args[2]
    if file == nil then
      io.stderr:write("spec needs a markdown file\n")
      return 1
    end
    local who = session.resolve(d.parsed.values["session"])
    return verbs.cmd_spec(s, id, file, d.parsed.values["base"] or "", who,
      d.parsed.switches["force"], d.parsed.values["why"] or "")
  end
  if d.command == "take" then
    local pr = math.tointeger(tonumber(d.parsed.values["pr"] or "0")) or 0
    local who = session.resolve(d.parsed.values["session"])
    return verbs.cmd_take(s, id, who, pr,
      d.parsed.switches["force"], d.parsed.values["why"] or "")
  end
  if d.command == "drop" then
    local who = session.resolve(d.parsed.values["session"])
    return verbs.cmd_drop(s, id, who, d.parsed.values["why"] or "",
      d.parsed.switches["force"])
  end
  if d.command == "verdict" then
    local kind = d.parsed.args[2]
    if kind == nil then
      io.stderr:write("verdict needs a kind: accept, request changes, reject\n")
      return 1
    end
    local pr = math.tointeger(tonumber(d.parsed.values["pr"] or "0")) or 0
    local who = session.resolve(d.parsed.values["session"])
    return vrd.cmd_verdict(s, id, kind, pr, d.parsed.values["head"] or "", who)
  end
  if d.command == "done" then
    return verbs.cmd_done(s, id, d.parsed.values["reason"] or "completed",
      d.parsed.switches["force"], d.parsed.values["why"] or "")
  end
  return show.cmd_show(s, id)
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
