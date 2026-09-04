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
---   cosmic --make run _work/gitboard.tl hold 2ai3 --reason "..." | unhold 2ai3
---   cosmic --make run _work/gitboard.tl attach 2akQ 2ai3
---   cosmic --make run _work/gitboard.tl block 2akQ 2ai3 | unblock 2akQ 2ai3
---   cosmic --make run _work/gitboard.tl set 2akQ --title "a truer title"
---   cosmic --make run _work/gitboard.tl spec 2akQ SPEC.md
---   cosmic --make run _work/gitboard.tl show [2akQ]
---   cosmic --make run _work/gitboard.tl next [--session S]
---   cosmic --make run _work/gitboard.tl take 2akQ [--pr 42 | --result]
---   cosmic --make run _work/gitboard.tl drop 2akQ --why "wave agent died"
---   cosmic --make run _work/gitboard.tl verdict 2akQ accept [--pr N]
---   cosmic --make run _work/gitboard.tl done 2akQ [--reason not-planned]
---   cosmic --make run _work/gitboard.tl brief builder 2akQ
---   cosmic --make run _work/gitboard.tl sync
---   cosmic --make run _work/gitboard.tl help system
---
--- `help <topic>` serves the doctrine pages (`_work.doctrine`) — the
--- system of work itself, not one verb's options — and the overview
--- help lists the topics.
---
--- This file is the argument parsing, prefix resolution, and dispatch
--- half; the verbs themselves are `_work.gitverbs` (the state
--- verbs) and `_work.gitgraph` (the graph mutations).
local flags = require("cosmic.flags")
local fs = require("cosmic.fs")
local proc = require("cosmic.proc")
local brief = require("_work.brief")
local cmp = require("_work.gitcompare")
local doctrine = require("_work.doctrine")
local graph = require("_work.gitgraph")
local gitspec = require("_work.gitspec")
local publish = require("_work.publish")
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
  ["done"] = true, ["compare"] = true, ["set"] = true, ["hold"] = true,
  ["unhold"] = true,
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
  summary = "the work board over committed item files: todo, doing, done\n\n"
  .. "ids are KSUIDs; the board renders each item by its handle, the id's last 8 "
  .. "characters\n(e.g. «d0x1_37YJ»), accepted by every verb bare or wrapped, any "
  .. "divider, any case;\nan unambiguous prefix or the full id also work "
  .. "everywhere; item branches are named\nby the id's first 8 characters — a "
  .. "different string from the handle.",
  commands = {
    {name = "init", summary = "create items/ (and a git repo if needed)",
      spec = {flags = {dir_flag()}}},
    {name = "new", summary = "open an item titled TITLE; role comes from the graph",
      spec = {usage = "TITLE [options]",
        summary = "open an item titled TITLE; role comes from the graph.\n\n"
        .. "A `friction:` title is refused unless its spec (--spec-file) "
        .. "names every agent this\nsession claimed work under since the "
        .. "pass began, one `## <kind> <handle>` heading\neach; "
        .. "--force --why files it anyway (a pass whose transcripts are "
        .. "gone).",
        flags = {dir_flag(),
          {long = "parent", arg = "ID", help = "the item this decomposes"},
          {long = "spec-file", arg = "FILE", help = "spec markdown sidecar"},
          {long = "repo", arg = "OWNER/NAME",
            help = "the repo its PR lands in; default is the board's origin "
            .. "(needs --parent)"},
          {long = "force", help = "file a `friction:` item over an "
            .. "incomplete roll call"},
          {long = "why", arg = "REASON", help = "why --force was needed"}}}},
    {name = "attach", summary = "put ID under PARENT (adopt, re-parent)",
      spec = {usage = "ID PARENT [options]", flags = {dir_flag()}}},
    {name = "compare", summary = "record that ID outranks OTHER "
      .. "(a standing reverse edge is reversed)",
      spec = {usage = "ID OTHER [options]", flags = {dir_flag()}}},
    {name = "hold", summary = "mark root ID held: its win condition verified; "
      .. "intake walks past it until evidence is filed under it",
      spec = {usage = "ID [options]", flags = {dir_flag(),
          {long = "reason", arg = "WHY",
            help = "what verified the win condition, and how"}}}},
    {name = "unhold", summary = "clear root ID's hold marker by hand "
      .. "(filing a child under it clears it too)",
      spec = {usage = "ID [options]", flags = {dir_flag()}}},
    {name = "block", summary = "record that ID waits on BLOCKER",
      spec = {usage = "ID BLOCKER [options]",
        summary = "record that ID waits on BLOCKER, the reason on the "
        .. "item.\n\nAn item that cannot proceed — a spec gap, a reopened "
        .. "decision, a falsified\npremise — is never dropped bare. The "
        .. "procedure, in this order:\n\n"
        .. "  1. `new '<the question>' --parent <ID's parent> --spec-file Q.md`\n"
        .. "     (parented, so the question is placed and takeable)\n"
        .. "  2. `block ID <question> --reason '<what cannot proceed>'`\n"
        .. "  3. `drop ID --why 'blocked on <question>'` if holding the claim\n\n"
        .. "ID is then never offered while the question is open, and the "
        .. "question's\n`done` unblocks it by itself — no unblock needed. "
        .. "A blocker is ordered up\nby what waits on it, so blocking lifts "
        .. "the question's place in the queue.",
        flags = {dir_flag(),
          {long = "reason", arg = "WHY",
            help = "what concretely cannot proceed until BLOCKER ends"}}}},
    {name = "unblock", summary = "drop BLOCKER from ID's blockers",
      spec = {usage = "ID BLOCKER [options]", flags = {dir_flag()}}},
    {name = "set", summary = "repair ID's title, repo and/or base "
      .. "(at least one; nothing else moves here)",
      spec = {usage = "ID [options]", flags = {dir_flag(),
          {long = "title", arg = "TITLE", help = "the item's title"},
          {long = "repo", arg = "OWNER/NAME",
            help = "the repo its PR lands in"},
          {long = "base", arg = "BRANCH",
            help = "the branch its PR targets"}}}},
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
    {name = "brief", summary = "print KIND's subagent prompt for ID, "
      .. "board facts filled",
      spec = {usage = "KIND ID [options]",
        summary = "print one role's subagent prompt for ID — KIND is "
        .. "builder, research,\nreview, refine, or decompose — with "
        .. "the item's spec verbatim and every\nboard-known placeholder "
        .. "filled, including the session label this kind's own\nclaim "
        .. "belongs under (also named on the closing verdict line). The "
        .. "verdict\nline names what is still left to fill (a worktree "
        .. "path, a bounce paragraph);\nfill those, then paste the body "
        .. "as the agent's prompt — never\nparaphrase or summarize it, "
        .. "and never hand-write a brief instead: a\nhand-written brief "
        .. "drifts.",
        flags = {dir_flag()}}},
    {name = "take", summary = "claim ID: the pull (spec bar and doing "
      .. "bound apply), its review when it awaits a verdict, or record "
      .. "its handover (--pr N for a diff, --result for a research spec)",
      spec = {usage = "ID [options]", flags = {dir_flag(),
          {long = "session", arg = "SESSION",
            help = "the claiming session; an orchestrator claiming for an "
            .. "agent always passes the name it minted for that agent — "
            .. "omitted, the claim binds to THIS session's one-claim "
            .. "identity"},
          {long = "pr", arg = "N",
            help = "record the PR that hands the build over for review"},
          {long = "result", help = "record the research handover: the "
            .. "spec as it stands is the deliverable, awaiting a verdict. "
            .. "The claim holder's own motion; never with --pr"},
          {long = "force", help = "take over another session's LIVE claim "
            .. "(a stale one needs no force), or skip the take gates"},
          {long = "why", arg = "REASON", help = "why --force was needed"}}}},
    {name = "drop", summary = "return ID's lease; the item, blockers "
      .. "included, is untouched",
      spec = {usage = "ID [options]",
        summary = "return ID's lease: the claim (or the review claim "
        .. "alone) releases; the\nitem, its blockers included, is "
        .. "untouched.\n\nA bare drop asserts the WORKER stopped — a dead "
        .. "wave agent, a session out\nof budget, a review nobody can "
        .. "finish — so the item is safe to re-offer\nas-is. An ITEM that "
        .. "cannot proceed is never dropped bare: `new` the\nquestion, "
        .. "`block` ID on it, then drop (see `help block` for the "
        .. "procedure).",
        flags = {dir_flag(),
          {long = "why", arg = "REASON",
            help = "why the session lets go (a dead agent, a build out of "
            .. "budget) — worker-side, never the item's gap"},
          {long = "session", arg = "SESSION",
            help = "the dropping session. Omit to derive it from the "
            .. "environment"},
          {long = "force", help = "drop another session's live claim"}}}},
    {name = "verdict", summary = "record a review verdict on a PR or a "
      .. "research handover (`take --result`); its effect follows",
      spec = {usage = "ID KIND [options]", flags = {dir_flag(),
          {long = "pr", arg = "N", help = "the PR the verdict judges; a "
            .. "research handover has none — omit --pr and --head, the "
            .. "verdict judges the spec revision the handover recorded"},
          {long = "head", arg = "SHA", help = "head commit it judges"},
          {long = "session", arg = "SESSION",
            help = "the reviewing session; it rides in the commit "
            .. "subject. Omit to derive it from the environment"},
          {long = "force", help = "record over the distance guard "
            .. "(the session built or specced this item) — repair only"},
          {long = "why", arg = "REASON", help = "why --force was needed"}}}},
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
  -- `help <topic>` serves doctrine before the dispatcher sees it —
  -- topics are not commands, so flags.command would refuse them as
  -- unknown. A topic never shadows a verb (`_work/doctrine_test.tl`
  -- pins that), so a verb's own help page always wins this race by
  -- construction.
  local argv = {...}
  if argv[1] == "help" and argv[2] ~= nil then
    local topic = doctrine.page(argv[2])
    if topic ~= nil then
      print(topic)
      return 0
    end
  end
  local d, derr = flags.command(CSPEC, argv)
  if d == nil then
    io.stderr:write(tostring(derr) .. "\n")
    io.stderr:write(flags.command_help(CSPEC)
      .. "\n\n" .. doctrine.listing() .. "\n")
    return 1
  end
  if d.help or d.command == nil then
    local text = flags.command_help(CSPEC, d.command)
    if d.command == nil then
      text = text .. "\n\n" .. doctrine.listing()
    end
    print(text)
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
    local synced, syerr = publish.sync(s)
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
  -- `brief`'s first argument is the KIND, not an id, so it cannot
  -- ride the shared id resolution below. A missing id passes through
  -- as "" so an unknown kind refuses on the kind, not on the id.
  if d.command == "brief" then
    local target = d.parsed.args[2] or ""
    if target ~= "" then
      local resolved, berr = resolve_id(s, target)
      if resolved == nil then
        io.stderr:write(tostring(berr) .. "\n")
        return 1
      end
      target = resolved
    end
    return brief.cmd_brief(s, d.parsed.args[1] or "", target)
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
    return graph.cmd_new(s, title, parent, spec, d.parsed.values["repo"] or "",
      d.parsed.switches["force"], d.parsed.values["why"] or "")
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
  if d.command == "hold" then
    return cmp.cmd_hold(s, id, d.parsed.values["reason"] or "")
  end
  if d.command == "unhold" then
    return cmp.cmd_unhold(s, id)
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
  if d.command == "set" then
    return graph.cmd_set(s, id, d.parsed.values["title"],
      d.parsed.values["repo"], d.parsed.values["base"])
  end
  if d.command == "spec" then
    local file = d.parsed.args[2]
    if file == nil then
      io.stderr:write("spec needs a markdown file\n")
      return 1
    end
    local who = session.resolve(d.parsed.values["session"])
    return gitspec.cmd_spec(s, id, file, d.parsed.values["base"] or "", who,
      d.parsed.switches["force"], d.parsed.values["why"] or "")
  end
  if d.command == "take" then
    local pr = math.tointeger(tonumber(d.parsed.values["pr"] or "0")) or 0
    local who = session.resolve(d.parsed.values["session"])
    return verbs.cmd_take(s, id, who, pr,
      d.parsed.switches["force"], d.parsed.values["why"] or "",
      d.parsed.switches["result"])
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
    return vrd.cmd_verdict(s, id, kind, pr, d.parsed.values["head"] or "", who,
      d.parsed.switches["force"], d.parsed.values["why"] or "")
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
