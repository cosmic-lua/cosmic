--- Planner-lane board verbs: status, next, check, move, new and edit.
--- Each cmd_* takes plain arguments, prints its own output including
--- the trailing `work-<verb>:` verdict line, and returns the process
--- exit code. Argument parsing and dispatch live in board.tl, and
--- `init` lives beside the label vocabulary it creates, in labels.tl.

local fs = require("cosmic.fs")
local facts = require("_work.facts")
local gh = require("_work.github")
local labels = require("_work.labels")
local model = require("_work.model")
local render = require("_work.render")
local verdict = require("_work.verdict")

local type Issue = model.Issue
local type Board = model.Board

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
    phase = model.phase_of(names),
    epic = model.has_marker(names, "epic"),
    finding = model.has_marker(names, "finding"),
    enable = model.has_marker(names, "enable"),
    assignee = assignee,
    url = raw.html_url,
    body = raw.body or "",
    created_at = raw.created_at,
  }
end

--- Fetch the whole board, one list call per phase.
--- @param repo string "owner/name"
--- @return Board | nil The board
--- @return string Error message on failure
local function fetch_board(repo: string): Board, string
  local board: Board = {}
  for _, phase in ipairs(model.PHASES) do
    local raw, err = gh.list_issues(repo, "work:" .. phase)
    if raw == nil then
      return nil, ("listing %s: %s"):format(phase, err)
    end
    local list: {Issue} = {}
    for _, r in ipairs(raw) do
      list[#list + 1] = to_issue(r)
    end
    board[phase] = list
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

--- One board line: "#123 title [epic] [finding] [enable] (assignee)".
--- @param i Issue The issue
--- @return string The rendered line
local function issue_line(i: Issue): string
  local tags = ""
  if i.epic then
    tags = tags .. " [epic]"
  end
  if i.finding then
    tags = tags .. " [finding]"
  end
  if i.enable then
    tags = tags .. " [enable]"
  end
  if i.assignee then
    tags = tags .. " (" .. i.assignee .. ")"
  end
  return ("  #%d %s%s"):format(i.number, i.title, tags)
end

--- The note an arrival over the WIP limit prints, or nil when the
--- phase still has slack. `count` is the phase's occupancy BEFORE the
--- arrival; the note names the occupancy after it — the number that
--- has to come back down before anything is pulled in — so an arrival
--- the phase does not count leaves the figure where it was.
--- @param phase string Phase the issue enters
--- @param count integer Occupancy before the arrival
--- @param occupies boolean True when the arrival takes one of the slots
--- @return string | nil The note line, nil when the phase has slack
local function over_limit_note(phase: string, count: integer,
    occupies: boolean): string
  if count < model.LIMITS[phase] then
    return nil
  end
  local after = occupies and count + 1 or count
  return ("note: %s %d/%d over limit — drain before intake"):format(
    phase, after, model.LIMITS[phase])
end

--- status: render the board right to left and verdict on WIP.
--- @param repo string "owner/name"
--- @return integer Exit code
local function cmd_status(repo: string): integer
  local board, err = fetch_board(repo)
  if board == nil then
    io.stderr:write(err .. "\n")
    print("work-board: ERROR")
    return 1
  end
  print("work board — " .. repo .. " (pull right to left)")
  for idx = #model.PHASES, 1, -1 do
    local phase = model.PHASES[idx]
    local list = model.oldest_first(board, phase)
    local counted = model.limited_count(board, phase)
    print(("%s %d/%d%s"):format(phase, counted, model.LIMITS[phase],
        render.exempt_suffix(list, phase)))
    if phase == "plan" then
      print(render.finding_pressure(list))
    end
    for _, i in ipairs(list) do
      print(issue_line(i))
    end
  end
  local violations = model.wip_violations(board)
  if #violations > 0 then
    print("work-board: ATTENTION (" .. table.concat(violations, "; ") .. ")")
    return 1
  end
  print("work-board: OK")
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
    print("work-next: ERROR")
    return 1
  end
  local action, aerr = model.next_action(board, role, open_oracle(repo))
  if action == nil then
    io.stderr:write(aerr .. "\n")
    print("work-next: ERROR")
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
    print(("work-next: %s #%d"):format(action.kind, action.issue.number))
  else
    print("work-next: " .. action.kind)
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
    print("work-check: ERROR")
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
  for _, f in ipairs(facts.problems(issue.body)) do
    problems[#problems + 1] = f
  end
  if issue.epic then
    problems[#problems + 1] = "is an epic (never marked ready; decompose it)"
  end
  if #problems > 0 then
    print("work-check: FAIL (" .. table.concat(problems, "; ") .. ")")
    return 1
  end
  print("work-check: PASS")
  return 0
end

--- move: change an issue's phase, refusing to overfill the target —
--- except for the arrivals `model.admits_over_limit` admits: a return
--- (the system correcting itself), a move into `land` (an accept
--- already given), and an issue the target would not count anyway (an
--- epic arriving in plan). Landing one over the limit prints a note naming the
--- phase to drain before more work is pulled into it. The landing
--- queue binds the other end instead: a pull (ready -> do) is refused
--- while land is at its limit, so accepted work merges before more
--- work starts. An issue on no phase is an entry, not a return, and
--- the limit binds it.
--- A move into `check` asks for a verdict, so it is refused while one
--- already stands unanswered: a `work-verdict: request changes` on the
--- issue's PR with no commit after it means there is nothing new to
--- review. A verdict read that fails refuses too — a move that cannot
--- see the review state is the wrong turn this gate exists to stop.
--- @param repo string "owner/name"
--- @param number integer Issue number
--- @param target string Target phase
--- @param force boolean True to override the WIP limit, the pull gate,
--- and the standing-verdict gate
--- @return integer Exit code
local function cmd_move(repo: string, number: integer, target: string,
    force: boolean): integer
  local known = false
  for _, c in ipairs(model.PHASES) do
    if c == target then
      known = true
    end
  end
  if not known then
    io.stderr:write("unknown phase: " .. target .. " (expected "
      .. table.concat(model.PHASES, ", ") .. ")\n")
    print("work-move: ERROR")
    return 1
  end
  local board, berr = fetch_board(repo)
  if board == nil then
    io.stderr:write(berr .. "\n")
    print("work-move: ERROR")
    return 1
  end
  local raw, gerr = gh.get_issue(repo, number)
  if raw == nil then
    io.stderr:write(gerr .. "\n")
    print("work-move: ERROR")
    return 1
  end
  local issue = to_issue(raw)
  local count = model.limited_count(board, target)
  local at_limit = count >= model.LIMITS[target]
  local admitted = model.admits_over_limit(issue, issue.phase, target, false)
  if at_limit and not force and not admitted then
    print(("work-move: REFUSED (%s %d/%d at limit; work right to left "
        .. "to drain it, or --force)"):format(
        target, count, model.LIMITS[target]))
    return 1
  end
  if issue.phase == "ready" and target == "do" and not force then
    local landed = model.limited_count(board, "land")
    if landed >= model.LIMITS["land"] then
      print(("work-move: REFUSED (the landing queue holds %d/%d; land the "
          .. "accepted work before pulling more, or --force)"):format(
          landed, model.LIMITS["land"]))
      return 1
    end
  end
  if target == "check" and not force then
    local state, serr = verdict.standing(repo, number)
    if state == nil then
      print(("work-move: REFUSED (cannot read the PR's verdict: %s; "
          .. "--force to move anyway)"):format(serr))
      return 1
    end
    local blocked = verdict.blocks_check(state)
    if blocked then
      print("work-move: REFUSED (" .. blocked .. ")")
      return 1
    end
  end
  if target == "ready" and not force then
    local problems: {string} = {}
    local gaps = model.ready_gaps(issue.body)
    if #gaps > 0 then
      problems[#problems + 1] = "missing or empty: " .. table.concat(gaps, ", ")
    end
    if issue.epic then
      problems[#problems + 1] = "is an epic (decompose it instead)"
    end
    for _, f in ipairs(facts.problems(issue.body)) do
      problems[#problems + 1] = f
    end
    if #problems > 0 then
      print("work-move: REFUSED (ready bar: "
        .. table.concat(problems, "; ") .. ")")
      return 1
    end
  end
  local remove: {string} = {}
  for _, c in ipairs(model.PHASES) do
    if c ~= target then
      remove[#remove + 1] = "work:" .. c
    end
  end
  local ok, err = gh.edit_labels(repo, number, {"work:" .. target}, remove)
  if not ok then
    io.stderr:write(err .. "\n")
    print("work-move: ERROR")
    return 1
  end
  local note = over_limit_note(target, count,
    model.counts_against_limit(issue, target))
  if note then
    print(note)
  end
  print(("work-move: #%d -> %s"):format(number, target))
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

--- new: open an issue on the board. The entry is WIP-limited on the
--- same terms a move is, through `model.admits_over_limit` over the
--- issue this is about to create: a finding is captured evidence and
--- is never refused, an epic entering plan occupies no slot there so
--- the limit does not measure it, and `mandated` names a filing a
--- verdict already required. An admitted entry over the limit prints
--- the same note a return does. A mandated filing is enablement work
--- by construction, so it carries `work:enable` whether or not
--- `enable` was passed; a finding is neither a decomposition parent
--- nor a planner's countermeasure, so it refuses both.
--- @param repo string "owner/name"
--- @param title string Issue title
--- @param body_file string Path to a body markdown file; nil for the template
--- @param phase string Target phase; ignored for a finding (always plan)
--- @param epic boolean Mark as a decomposition parent
--- @param enable boolean Mark as enablement work
--- @param finding boolean Capture implementer evidence, past the WIP limit
--- @param mandated boolean File a countermeasure a verdict already required
--- @param force boolean True to override the phase WIP limit
--- @return integer Exit code
local function cmd_new(repo: string, title: string, body_file: string,
    phase: string, epic: boolean, enable: boolean, finding: boolean,
    mandated: boolean, force: boolean): integer
  if finding and (epic or mandated) then
    print("work-new: REFUSED (--finding conflicts with --epic and --mandated; "
      .. "a finding is captured evidence, not a decomposition parent and not "
      .. "a countermeasure a verdict already required)")
    return 1
  end
  if finding then
    phase = "plan"
  end
  local entry: Issue = {title = title, phase = phase, epic = epic,
    finding = finding, enable = enable or mandated}
  local body = TEMPLATE
  if body_file then
    local data, rerr = fs.read(body_file)
    if data == nil then
      io.stderr:write(rerr .. "\n")
      print("work-new: ERROR")
      return 1
    end
    body = data
  end
  local board, berr = fetch_board(repo)
  if board == nil then
    io.stderr:write(berr .. "\n")
    print("work-new: ERROR")
    return 1
  end
  local count = model.limited_count(board, phase)
  local admitted = model.admits_over_limit(entry, nil, phase, mandated)
  if count >= model.LIMITS[phase] and not force and not admitted then
    local detour = ""
    if phase == "plan" then
      detour = " evidence can be captured now with --finding, adopted at triage later;"
    end
    print(("work-new: REFUSED (%s %d/%d at limit;%s drain the board "
        .. "right to left first, or --force)"):format(
        phase, count, model.LIMITS[phase], detour))
    return 1
  end
  local raw, err = gh.create_issue(repo, title, body, labels.labels_of(entry))
  if raw == nil then
    io.stderr:write(err .. "\n")
    print("work-new: ERROR")
    return 1
  end
  print("  " .. raw.html_url)
  local note = over_limit_note(phase, count,
    model.counts_against_limit(entry, phase))
  if note then
    print(note)
  end
  print(("work-new: #%d %s"):format(raw.number, phase))
  return 0
end

--- edit: rewrite an issue's title and/or body in place. Labels are
--- untouched — phases move through `move`, which owns the WIP limits.
--- An edit that leaves a work:ready issue below the bar still lands;
--- the verdict names the gaps, visible now not at the next `check`.
--- @param repo string "owner/name"
--- @param number integer Issue number
--- @param body_file string Path to a body markdown file; nil to keep the body
--- @param title string Replacement title; nil to keep the title
--- @return integer Exit code
local function cmd_edit(repo: string, number: integer, body_file: string,
    title: string): integer
  local body: string = nil
  if body_file then
    local data, rerr = fs.read(body_file)
    if data == nil then
      io.stderr:write(rerr .. "\n")
      print("work-edit: ERROR")
      return 1
    end
    body = data
  end
  local raw, err = gh.update_issue(repo, number, title, body)
  if raw == nil then
    io.stderr:write(err .. "\n")
    print("work-edit: ERROR")
    return 1
  end
  local issue = to_issue(raw)
  print("  " .. issue.url)
  if issue.phase == "ready" then
    local gaps = model.ready_gaps(issue.body)
    if #gaps > 0 then
      print(("work-edit: #%d (ready-bar gaps: %s)"):format(
          number, table.concat(gaps, ", ")))
      return 0
    end
  end
  print(("work-edit: #%d"):format(number))
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
  phase: string, epic: boolean, enable: boolean, finding: boolean,
  mandated: boolean, force: boolean): integer
  cmd_edit: function(repo: string, number: integer, body_file: string,
  title: string): integer
end

local M: verbs = {
  to_issue = to_issue,
  cmd_status = cmd_status,
  cmd_next = cmd_next,
  cmd_check = cmd_check,
  cmd_move = cmd_move,
  cmd_new = cmd_new,
  cmd_edit = cmd_edit,
}

return M
