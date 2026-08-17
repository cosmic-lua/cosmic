#!/usr/bin/env cosmic
--- Work board CLI over a state REPOSITORY instead of GitHub labels: a
--- proof of concept of the same board — same phases, same WIP limits,
--- same pull order, decided by the same `_work.model` — with the
--- coordination state held as `cards/<issue>.tl` files in a git
--- checkout (`_work.store`). Issues and PRs stay on GitHub and carry
--- the spec and the fix; what moves between them lives here, so no
--- claim comments, PR-link comments, or verdict comments accumulate on
--- either. Every verb ends with a `gitboard-<verb>:` verdict line.
---
---   cosmic --make run _work/gitboard.tl init [--dir D]
---   cosmic --make run _work/gitboard.tl new 123 "title" [--phase plan]
---   cosmic --make run _work/gitboard.tl status
---   cosmic --make run _work/gitboard.tl next [--role planner]
---   cosmic --make run _work/gitboard.tl move 123 ready [--claim S]
---   cosmic --make run _work/gitboard.tl verdict 123 accept [--pr P]
---   cosmic --make run _work/gitboard.tl done 123 [--reason not-planned]
---   cosmic --make run _work/gitboard.tl show 123
---   cosmic --make run _work/gitboard.tl sync
---
--- Mutations commit locally and publish through `store.publish`, whose
--- rejected-push path rebases onto concurrent state and re-checks the
--- WIP invariant before pushing again — the race the label index turns
--- into a lagged read is here a refused compare-and-swap.
local cards = require("_work.card")
local child = require("cosmic.child")
local flags = require("cosmic.flags")
local fs = require("cosmic.fs")
local model = require("_work.model")
local proc = require("cosmic.proc")
local store = require("_work.store")

local DEFAULT_REPO < const > = "whilp/cosmic"

local function dir_flag(): flags.Flag
  return {long = "dir", arg = "DIR", default = ".",
    help = "state repository checkout"}
end

local function repo_flag(): flags.Flag
  return {long = "repo", arg = "OWNER/NAME", default = DEFAULT_REPO,
    help = "tracked repository, for issue URLs"}
end

local CSPEC: flags.CommandSpec = {
  name = "gitboard",
  summary = "the work kanban over committed card files (proof of concept)",
  commands = {
    {name = "init", summary = "create cards/ (and a git repo if needed)",
      spec = {flags = {dir_flag()}}},
    {name = "new", summary = "open a card for ISSUE titled TITLE (WIP-limited)",
      spec = {usage = "ISSUE TITLE [options]", flags = {dir_flag(), repo_flag(),
          {long = "phase", arg = "PHASE", default = "plan",
            help = "phase the card enters"},
          {long = "epic", help = "mark as a decomposition parent"},
          {long = "enable", help = "mark as enablement work"},
          {long = "finding",
            help = "capture implementer evidence; lands even at the WIP limit"},
          {long = "mandated",
            help = "a countermeasure a verdict required; implies --enable"},
          {long = "force", help = "override the phase WIP limit"}}}},
    {name = "status", summary = "render the board and its WIP verdict",
      spec = {flags = {dir_flag(), repo_flag()}}},
    {name = "next", summary = "the one next action for a role",
      spec = {flags = {dir_flag(), repo_flag(),
          {long = "role", arg = "ROLE", default = "implementer",
            help = "planner or implementer"}}}},
    {name = "move", summary = "move ISSUE to PHASE (WIP-limited)",
      spec = {usage = "ISSUE PHASE [options]", flags = {dir_flag(), repo_flag(),
          {long = "claim", arg = "SESSION", help = "record who took it"},
          {long = "force", help = "override the target WIP limit"}}}},
    {name = "verdict", summary = "record a review verdict; the move it implies follows",
      spec = {usage = "ISSUE KIND [options]", flags = {dir_flag(), repo_flag(),
          {long = "pr", arg = "N", help = "the PR the verdict judges"},
          {long = "head", arg = "SHA", help = "head commit it was written against"}}}},
    {name = "done", summary = "end ISSUE's card, recording why",
      spec = {usage = "ISSUE [options]", flags = {dir_flag(), repo_flag(),
          {long = "reason", arg = "REASON", default = "completed",
            help = "completed or not-planned"},
          {long = "force", help = "end it even from ready/do/land"}}}},
    {name = "show", summary = "print ISSUE's card and its git history",
      spec = {usage = "ISSUE [options]", flags = {dir_flag(), repo_flag()}}},
    {name = "sync", summary = "rebase onto the remote's state",
      spec = {flags = {dir_flag(), repo_flag()}}},
  },
}

--- Print a verb's verdict line and return its exit code.
--- @param verb string The verb
--- @param ok boolean Whether it succeeded
--- @param detail string What happened
--- @return integer 0 on success, 1 otherwise
local function verdict_line(verb: string, ok: boolean, detail: string): integer
  print(("gitboard-%s: %s"):format(verb, detail))
  if ok then
    return 0
  end
  return 1
end

--- The WIP refusal a card's arrival in a phase earns, or nil when it
--- may enter: the target is at its limit and `model.admits_over_limit`
--- does not except the arrival. The one gate `new` and `move` share.
--- @param b model.Board The board
--- @param arriving model.Issue The arrival as the board will see it
--- @param from string Current phase, or nil for an entry
--- @param to string Target phase
--- @param mandated boolean True when a verdict required this filing
--- @return string | nil The refusal
local function wip_refusal(b: model.Board, arriving: model.Issue, from: string,
    to: string, mandated: boolean): string
  local limit = model.LIMITS[to]
  if limit == nil then
    return nil
  end
  local n = model.limited_count(b, to)
  if n < limit then
    return nil
  end
  if model.admits_over_limit(arriving, from, to, mandated) then
    return nil
  end
  return ("%s is at %d/%d — drain it before pulling more"):format(to, n, limit)
end

--- Save a card and publish the commit, re-checking the WIP gate
--- against the merged board when the push loses a race.
--- @param s store.Store The store
--- @param c cards.Card The mutated card
--- @param message string Commit subject
--- @param from string Phase the mutation left, or nil for an entry
--- @param mandated boolean True when a verdict required this filing
--- @return boolean True once committed (and pushed, given a remote)
--- @return string Error message
local function commit_and_publish(s: store.Store, c: cards.Card,
    message: string, from: string, mandated: boolean): boolean, string
  local saved, serr = store.save(s, c, message)
  if not saved then
    return false, serr
  end
  return store.publish(s, function(): string
      local merged = store.board(s)
      if merged == nil then
        return "state repository unreadable after rebase"
      end
      -- The mutated card is already IN the merged board; ask whether the
      -- phase ended up over-limit with an arrival the limit may refuse.
      local limit = model.LIMITS[c.phase]
      if limit ~= nil and model.limited_count(merged, c.phase) > limit
      and not model.admits_over_limit(cards.to_issue(c, s.repo), from,
        c.phase, mandated) then
        return ("%s is over %d after a concurrent move"):format(c.phase, limit)
      end
      return nil
    end)
end

--- Open the store named by the parsed flags.
--- @param values {string: string} Parsed flag values
--- @return store.Store | nil The store
--- @return string Error message
local function open_store(values: {string: string}): store.Store | nil, string
  return store.open(values["dir"] or ".", values["repo"] or DEFAULT_REPO)
end

local function cmd_init(dir: string): integer
  if not fs.is_dir(fs.join(dir, ".git")) then
    local r, err = child.run({"git", "init", "-q", dir})
    if r == nil or not r.ok then
      return verdict_line("init", false, err or (r and r.stderr) or "git init failed")
    end
  end
  local made, merr = fs.make_dirs(fs.join(dir, "cards"))
  if not made then
    return verdict_line("init", false, merr)
  end
  local kept, kerr = fs.write(fs.join(dir, "cards", ".gitkeep"), "")
  if not kept then
    return verdict_line("init", false, kerr)
  end
  return verdict_line("init", true, ("state repository ready at %s"):format(dir))
end

local function cmd_new(s: store.Store, issue: integer, title: string,
    phase: string, epic: boolean, enable: boolean, finding: boolean,
    mandated: boolean, force: boolean): integer
  local existing = store.load(s, issue)
  if existing ~= nil then
    return verdict_line("new", false,
      ("a card for issue %d already exists (%s)"):format(issue, existing.phase))
  end
  local c: cards.Card = {
    issue = issue, title = title, phase = phase, epic = epic,
    finding = finding, enable = enable or mandated,
    blocked_by = {}, claim = "", pr = 0, verdict = "",
    verdict_head = "", resolution = "",
  }
  local b, berr = store.board(s)
  if b == nil then
    return verdict_line("new", false, berr)
  end
  if not force then
    local refusal = wip_refusal(b, cards.to_issue(c, s.repo), nil, phase, mandated)
    if refusal then
      return verdict_line("new", false, "REFUSED: " .. refusal)
    end
  end
  local ok, err = commit_and_publish(s, c,
    ("new #%d %s (%s)"):format(issue, title, phase), nil, mandated)
  if not ok then
    return verdict_line("new", false, err)
  end
  return verdict_line("new", true, ("#%d enters %s"):format(issue, phase))
end

local function cmd_status(s: store.Store): integer
  local b, berr = store.board(s)
  if b == nil then
    return verdict_line("status", false, berr)
  end
  for _, phase in ipairs(model.PHASES) do
    local issues = model.oldest_first(b, phase)
    print(("%-6s %d/%d"):format(phase, model.limited_count(b, phase),
        model.LIMITS[phase]))
    for _, i in ipairs(issues) do
      local marks = ""
      if i.epic then marks = marks .. " [epic]" end
      if i.finding then marks = marks .. " [finding]" end
      if i.enable then marks = marks .. " [enable]" end
      if i.assignee ~= "" then marks = marks .. " @" .. i.assignee end
      print(("  #%-5d %s%s"):format(i.number, i.title, marks))
    end
  end
  local violations = model.wip_violations(b)
  if #violations > 0 then
    return verdict_line("status", true, "WIP: " .. table.concat(violations, "; "))
  end
  return verdict_line("status", true, "WIP ok")
end

local function cmd_next(s: store.Store, role: string): integer
  local b, berr = store.board(s)
  if b == nil then
    return verdict_line("next", false, berr)
  end
  local action, aerr = model.next_action(b, role, store.is_open_fn(s))
  if action == nil then
    return verdict_line("next", false, aerr)
  end
  local target = ""
  if action.issue then
    target = (" #%d %s"):format(action.issue.number, action.issue.title)
  end
  return verdict_line("next", true,
    ("%s%s — %s"):format(action.kind, target, action.reason))
end

local function cmd_move(s: store.Store, issue: integer, target: string,
    claim: string, force: boolean): integer
  if not cards.is_phase(target) or target == cards.DONE then
    return verdict_line("move", false, ("unknown phase: %s (done is the "
        .. "done verb's)"):format(target))
  end
  local c, lerr = store.load(s, issue)
  if c == nil then
    return verdict_line("move", false, lerr)
  end
  local from = c.phase
  if from == target then
    return verdict_line("move", false, ("#%d is already in %s"):format(issue, target))
  end
  local b, berr = store.board(s)
  if b == nil then
    return verdict_line("move", false, berr)
  end
  c.phase = target
  if claim ~= nil and claim ~= "" then
    c.claim = claim
  end
  if model.is_return(from, target) then
    c.claim = ""
  end
  if not force then
    local refusal = wip_refusal(b, cards.to_issue(c, s.repo), from, target, false)
    if refusal then
      return verdict_line("move", false, "REFUSED: " .. refusal)
    end
  end
  local ok, err = commit_and_publish(s, c,
    ("move #%d %s -> %s"):format(issue, from, target), from, false)
  if not ok then
    return verdict_line("move", false, err)
  end
  return verdict_line("move", true, ("#%d %s -> %s"):format(issue, from, target))
end

--- The phase each verdict sends a card to: review.md's three
--- directions out of check.
local VERDICT_MOVES: {string: string} = {
  ["accept"] = "land",
  ["request changes"] = "do",
  ["reject"] = "plan",
}

local function cmd_verdict(s: store.Store, issue: integer, kind: string,
    pr: integer, head: string): integer
  local target = VERDICT_MOVES[kind]
  if target == nil then
    return verdict_line("verdict", false, ("unknown verdict: %s"):format(kind))
  end
  local c, lerr = store.load(s, issue)
  if c == nil then
    return verdict_line("verdict", false, lerr)
  end
  local from = c.phase
  c.verdict = kind
  c.verdict_head = head or ""
  if pr ~= nil and pr ~= 0 then
    c.pr = pr
  end
  c.phase = target
  -- A verdict is a decision already made: an accept enters land and a
  -- send-back is a return, so no WIP gate applies in any direction.
  local ok, err = commit_and_publish(s, c,
    ("verdict #%d %s (%s -> %s)"):format(issue, kind, from, target), from, false)
  if not ok then
    return verdict_line("verdict", false, err)
  end
  return verdict_line("verdict", true,
    ("%s on #%d: %s -> %s"):format(kind, issue, from, target))
end

--- Phases `done` refuses to end a card from without --force: the
--- mid-flow phases where an ending would make a card vanish mid-work.
--- `land` is different — completing from land IS the landing — but a
--- not-planned ending there would discard an accept, so only
--- "completed" passes.
local NO_DONE: {string: boolean} = {ready = true, ["do"] = true}

local function cmd_done(s: store.Store, issue: integer, reason: string,
    force: boolean): integer
  if reason ~= "completed" and reason ~= "not-planned" then
    return verdict_line("done", false, ("unknown reason: %s"):format(reason))
  end
  local c, lerr = store.load(s, issue)
  if c == nil then
    return verdict_line("done", false, lerr)
  end
  local refused = NO_DONE[c.phase]
  or (c.phase == "land" and reason ~= "completed")
  if refused and not force then
    return verdict_line("done", false,
      ("REFUSED: #%d is mid-flow in %s — move it left first"):format(issue, c.phase))
  end
  local from = c.phase
  c.phase = cards.DONE
  c.resolution = reason
  local ok, err = commit_and_publish(s, c,
    ("done #%d %s (from %s)"):format(issue, reason, from), from, false)
  if not ok then
    return verdict_line("done", false, err)
  end
  return verdict_line("done", true, ("#%d %s (%s)"):format(issue, reason, from))
end

local function cmd_show(s: store.Store, issue: integer): integer
  local c, lerr = store.load(s, issue)
  if c == nil then
    return verdict_line("show", false, lerr)
  end
  print(("#%d %s"):format(c.issue, c.title))
  print(("phase: %s"):format(c.phase))
  if c.claim ~= "" then print(("claim: %s"):format(c.claim)) end
  if c.pr ~= 0 then print(("pr: #%d"):format(c.pr)) end
  if c.verdict ~= "" then
    print(("verdict: %s (head %s)"):format(c.verdict, c.verdict_head))
  end
  if #c.blocked_by > 0 then
    local refs: {string} = {}
    for _, b in ipairs(c.blocked_by) do
      refs[#refs + 1] = ("#%d"):format(b)
    end
    print("blocked by: " .. table.concat(refs, " "))
  end
  if c.resolution ~= "" then print(("resolution: %s"):format(c.resolution)) end
  local events = store.history(s, issue)
  if events then
    for _, e in ipairs(events) do
      print(("  %s %s %s"):format(e.at, e.sha, e.subject))
    end
  end
  return verdict_line("show", true, ("#%d in %s"):format(c.issue, c.phase))
end

local function cmd_sync(s: store.Store): integer
  local ok, err = store.sync(s)
  if not ok then
    return verdict_line("sync", false, err)
  end
  return verdict_line("sync", true, "state is current")
end

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
    return cmd_init(d.parsed.values["dir"] or ".")
  end
  local s, serr = open_store(d.parsed.values)
  if s == nil then
    io.stderr:write(tostring(serr) .. "\n")
    return 1
  end
  if d.command == "status" then
    return cmd_status(s)
  end
  if d.command == "next" then
    return cmd_next(s, d.parsed.values["role"] or "implementer")
  end
  if d.command == "sync" then
    return cmd_sync(s)
  end
  local n = math.tointeger(tonumber(d.parsed.args[1] or ""))
  if n == nil then
    io.stderr:write(d.command .. " needs an issue number\n")
    return 1
  end
  if d.command == "new" then
    local title = d.parsed.args[2]
    if title == nil or title == "" then
      io.stderr:write("new needs a title after the issue number\n")
      return 1
    end
    local phase = d.parsed.values["phase"] or "plan"
    if not cards.is_phase(phase) or phase == cards.DONE then
      io.stderr:write("unknown entry phase: " .. phase .. "\n")
      return 1
    end
    return cmd_new(s, n, title, phase, d.parsed.switches["epic"],
      d.parsed.switches["enable"], d.parsed.switches["finding"],
      d.parsed.switches["mandated"], d.parsed.switches["force"])
  end
  if d.command == "move" then
    local target = d.parsed.args[2]
    if target == nil then
      io.stderr:write("move needs a phase\n")
      return 1
    end
    return cmd_move(s, n, target, d.parsed.values["claim"],
      d.parsed.switches["force"])
  end
  if d.command == "verdict" then
    local kind = d.parsed.args[2]
    if kind == nil then
      io.stderr:write("verdict needs a kind: accept, request changes, reject\n")
      return 1
    end
    local pr = math.tointeger(tonumber(d.parsed.values["pr"] or "0")) or 0
    return cmd_verdict(s, n, kind, pr, d.parsed.values["head"] or "")
  end
  if d.command == "done" then
    return cmd_done(s, n, d.parsed.values["reason"] or "completed",
      d.parsed.switches["force"])
  end
  return cmd_show(s, n)
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
