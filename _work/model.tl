--- The board model: phases, WIP limits, the ready bar, and the
--- right-to-left pull order, as pure functions over already-fetched
--- issues. No network, no subprocess — board.tl fetches through
--- _work.github and decides here, so every flow rule skills/work/ asks
--- an agent to follow has exactly one executable definition, pinned by
--- model_test.tl.

--- One issue as the board sees it, already reduced from the gh JSON.
local record Issue
  number: integer
  title: string
  phase: string
  epic: boolean
  finding: boolean
  enable: boolean
  assignee: string
  url: string
  body: string
end

--- Open issues grouped by phase name ("plan" ... "land").
local type Board = {string: {Issue}}

--- Answers a blocker-state question the model cannot ask itself:
--- true when issue #n in the board's repo is still open.
local type IsOpen = function(n: integer): boolean

--- The tool's one answer to "what should I do now".
local record NextAction
  --- "review" | "refine" | "intake" | "finish" | "pull" | "none"
  kind: string
  --- The issue the action targets; nil for intake and none.
  issue: Issue
  --- The fallback when `issue` is claimed by another live session.
  alt: Issue
  --- The rule that chose this action, stated for the human/agent.
  reason: string
end

--- Phase order, left to right; pull works from the END of this list.
local PHASES: {string} = {"plan", "ready", "do", "check", "land"}

--- WIP limits are policy, and policy is committed: tune them here, in
--- a reviewed change, never ad hoc per session. Empirical basis (the
--- 2026-08-16 flow review: 468 min of board history, 52 issues, 13
--- merged PRs, reconstructed from label events):
--- plan's 12 is the binding constraint — it spent 222 min (47% of the
--- session) at or over limit, and every refusal incident on record
--- traces to it; the number stays and epics are exempted instead (see
--- `counts_against_limit`), since they occupied an average 4.8 of the
--- 12 slots (45% of the phase's item-minutes) without being work in
--- progress.
--- ready's 12 is a tightening from 20: it peaked at 16 only during
--- initial fill and never came within 4 of 20 afterward, with a floor
--- of 6, while median ready->do pickup latency was 81 min (p75: 278) —
--- long enough that queue inventory measurably went stale. A tighter
--- cap forces staler entries to drain instead of sitting.
--- do's 5 and check's 10 are healthy: do peaked 5/5 for 17 min, check
--- peaked 7/10 and never bound.
--- land's 3 measures a different thing. An accepted PR is finished
--- work in waiting, not work in progress, so the limit is not there to
--- cap effort — it is there to make a broken merge path loud: three
--- accepts sitting unmerged mean merging itself is what needs
--- attention. 3 is a starting value, not a measurement.
--- Tripwires: revisit land once a full week of flow data exists;
--- revisit check only if its peak ever exceeds 8.
local LIMITS: {string: integer} = {
  plan = 12,
  ready = 12,
  ["do"] = 5,
  check = 10,
  land = 3,
}

local PHASE_SET: {string: boolean} = {}
local PHASE_INDEX: {string: integer} = {}
for idx, c in ipairs(PHASES) do
  PHASE_SET[c] = true
  PHASE_INDEX[c] = idx
end

--- Whether moving from one phase to another is a return: leftward
--- motion between two known phases. WIP limits gate rightward motion
--- and planner intake only. Returns are never refused, even over the
--- limit; an over-limit phase blocks further pull until it drains. A
--- bounce back to plan and a rework send-back are the system
--- correcting itself, so nothing may refuse them. Anything else — an
--- unknown `from` (an issue not on the board, which is an entry), the
--- same phase, or rightward motion — is not a return.
--- @param from string Current phase name, or nil when not on the board
--- @param to string Target phase name
--- @return boolean True when the move is leftward between known phases
local function is_return(from: string, to: string): boolean
  local a = PHASE_INDEX[from]
  local b = PHASE_INDEX[to]
  return a ~= nil and b ~= nil and b < a
end

--- Whether an issue occupies a WIP-limit slot in a phase: false
--- exactly for an epic sitting in plan, true otherwise. An epic is a
--- container that lives in plan until every child closes — not work in
--- progress — and counting it against the limit starves the phase
--- (measured: epics permanently occupied an average 4.8 of plan's 12
--- slots).
--- @param issue Issue The issue
--- @param phase string Phase the issue is being counted in
--- @return boolean True when the issue counts against the phase's limit
local function counts_against_limit(issue: Issue, phase: string): boolean
  return not (phase == "plan" and issue.epic)
end

--- Whether a phase's WIP limit lets an arrival in while that phase is
--- already at the limit — the one rule both `move` and `new` ask, so
--- an issue that moves and an issue that is filed are refused on the
--- same terms. `issue` is the arrival as the board will see it: the
--- issue being moved, or the one about to be created, whose `from` is
--- nil because an entry comes from nowhere. Four admissions:
--- an arrival the phase would not count occupies no slot there, so the
--- limit has nothing to measure — an epic in plan is a container, not
--- work in progress, and refusing to file one is the limit binding
--- something it does not count; captured evidence is never dropped for
--- a full board; `mandated` is a filing a verdict already required —
--- the feedback half's second-occurrence countermeasure — which no
--- label shows, so the filing asserts it; and a return or a move into
--- `land` is the system correcting itself or an accept, both decisions
--- already made. The landing queue's own limit gates PULLS out of
--- ready instead, so a full landing queue stops new work from starting
--- rather than stranding work that is already done.
--- @param issue Issue The arrival, as the board will see it
--- @param from string Current phase name, or nil for an entry
--- @param to string Target phase name
--- @param mandated boolean True when a verdict already required the filing
--- @return boolean True when the target's WIP limit does not bind it
local function admits_over_limit(issue: Issue, from: string, to: string,
    mandated: boolean): boolean
  return not counts_against_limit(issue, to)
  or issue.finding
  or mandated
  or to == "land"
  or is_return(from, to)
end

--- Occupancy of one phase, counting only issues that count against its
--- limit (an epic in plan does not). The one counting path every WIP
--- check and display shares, so the epic exemption applies everywhere
--- at once.
--- @param board Board The board
--- @param phase string Phase name
--- @return integer Filtered occupancy
local function counted(board: Board, phase: string): integer
  local n = 0
  for _, i in ipairs(board[phase] or {}) do
    if counts_against_limit(i, phase) then
      n = n + 1
    end
  end
  return n
end

--- The phase each older `plan:<phase>` label spelling names. The
--- flow-stats replay reads historical label events, and renaming a
--- label on GitHub does not rewrite the name recorded in an event that
--- already happened, so both spellings are read. Drop this table and
--- its branch in `phase_of` once no `plan:` label appears in any
--- timeline the tool still reads.
local LEGACY_PHASE: {string: string} = {
  shaping = "plan",
  ready = "ready",
  doing = "do",
  review = "check",
}

--- The phase a label set places an issue in, or nil when it carries
--- neither a `work:<phase>` label nor a `plan:<phase>` one.
--- @param labels {string} Label names on the issue
--- @return string | nil Phase name
local function phase_of(labels: {string}): string
  for _, l in ipairs(labels) do
    local phase = l:match("^work:(%l+)$")
    if phase and PHASE_SET[phase] then
      return phase
    end
    local legacy = l:match("^plan:(%l+)$")
    if legacy and LEGACY_PHASE[legacy] then
      return LEGACY_PHASE[legacy]
    end
  end
  return nil
end

--- Whether a label set carries a given marker label (epic, enable,
--- finding).
--- @param labels {string} Label names on the issue
--- @param marker string Marker name without the work: prefix
--- @return boolean True when present
local function has_marker(labels: {string}, marker: string): boolean
  for _, l in ipairs(labels) do
    if l == "work:" .. marker then
      return true
    end
  end
  return false
end

--- Issue numbers named on "blocked by" lines of a body. Any line
--- containing the phrase contributes every #N it mentions; same-repo
--- references only.
--- @param body string Issue body markdown
--- @return {integer} Blocker issue numbers, in order of appearance
local function blockers(body: string): {integer}
  local out: {integer} = {}
  for line in (body .. "\n"):gmatch("([^\n]*)\n") do
    if line:lower():find("blocked by", 1, true) then
      for n in line:gmatch("#(%d+)") do
        out[#out + 1] = math.tointeger(tonumber(n))
      end
    end
  end
  return out
end

--- Issues of one phase, oldest (lowest number) first. Returns a new
--- sorted copy; the board is data, not scratch.
--- @param board Board The board
--- @param phase string Phase name
--- @return {Issue} Sorted issues, possibly empty
local function oldest_first(board: Board, phase: string): {Issue}
  local list: {Issue} = {}
  for _, i in ipairs(board[phase] or {}) do
    list[#list + 1] = i
  end
  table.sort(list, function(a: Issue, b: Issue): boolean
      return a.number < b.number
    end)
  return list
end

--- WIP-limit violations, one line each ("do 6/5 over limit").
--- @param board Board The board
--- @return {string} Violations, left-to-right phase order
local function wip_violations(board: Board): {string}
  local out: {string} = {}
  for _, phase in ipairs(PHASES) do
    local n = counted(board, phase)
    if n > LIMITS[phase] then
      out[#out + 1] = ("%s %d/%d over limit"):format(phase, n, LIMITS[phase])
    end
  end
  return out
end

--- The oldest ready issue an implementer may pull: not an epic, and
--- with no open blocker.
--- @param board Board The board
--- @param is_open IsOpen Blocker-state oracle
--- @return Issue | nil The pullable issue, or nil when none qualifies
local function first_pullable(board: Board, is_open: IsOpen): Issue
  for _, i in ipairs(oldest_first(board, "ready")) do
    if not i.epic then
      local open_blocker = false
      for _, b in ipairs(blockers(i.body or "")) do
        if is_open(b) then
          open_blocker = true
          break
        end
      end
      if not open_blocker then
        return i
      end
    end
  end
  return nil
end

--- The implementer's next action, right to left: whatever is closest
--- to completion moves first. Land leads: its issues are accepted,
--- awaiting merge, and one merge finishes them. Then do —
--- which holds both fresh claims and rework a check verdict sent back
--- — oldest first, with the pullable ready issue as the fallback for a
--- second concurrent session. Then the oldest unblocked ready issue,
--- except while the landing queue is at its limit, when draining it
--- rather than starting more work is the action. Otherwise there is
--- nothing to pull and a planner session is the answer (check-phase
--- items wait on a planner, never on more implementation).
--- @param board Board The board
--- @param is_open IsOpen Blocker-state oracle
--- @return NextAction The decision
local function next_for_implementer(board: Board, is_open: IsOpen): NextAction
  local landing = oldest_first(board, "land")
  local pullable = first_pullable(board, is_open)
  if #landing > 0 then
    return {
      kind = "finish",
      issue = landing[1],
      alt = pullable,
      reason = ("land holds %d/%d — #%d is accepted, awaiting merge"):format(
        #landing, LIMITS["land"], landing[1].number),
    }
  end
  local doing = oldest_first(board, "do")
  if #doing > 0 then
    local reason = ("do holds %d/%d — finish before pulling"):format(
      #doing, LIMITS["do"])
    if pullable then
      reason = reason .. ("; if #%d is another live session's claim, pull #%d")
      :format(doing[1].number, pullable.number)
    end
    return {kind = "finish", issue = doing[1], alt = pullable, reason = reason}
  end
  if pullable then
    local landed = counted(board, "land")
    if landed >= LIMITS["land"] then
      return {
        kind = "none",
        reason = ("the landing queue holds %d/%d — land the accepted work "
          .. "before pulling more"):format(landed, LIMITS["land"]),
      }
    end
    return {
      kind = "pull",
      issue = pullable,
      reason = "oldest ready issue with no open blocker",
    }
  end
  local waiting = #(board["check"] or {})
  local bottleneck = ""
  if waiting > 0 then
    bottleneck = ("; %d issue(s) await a planner verdict — that verdict is "
      .. "the bottleneck"):format(waiting)
  end
  if #(board["ready"] or {}) > 0 then
    return {
      kind = "none",
      reason = "every ready issue is an epic or has an open blocker — "
      .. "a planner session must unblock or refine" .. bottleneck,
    }
  end
  return {
    kind = "none",
    reason = "no ready work — a planner session must refine or intake"
    .. bottleneck,
  }
end

--- The planner's next action, right to left: check waiting work first
--- (land is the implementer's phase, so the planner's rightmost is
--- check); then refine plan into ready while ready has slack; then
--- intake from the goals while plan has slack; else nothing.
--- @param board Board The board
--- @return NextAction The decision
local function next_for_planner(board: Board): NextAction
  local checking = oldest_first(board, "check")
  if #checking > 0 then
    return {
      kind = "review",
      issue = checking[1],
      reason = "check is the rightmost planner phase — verdicts first",
    }
  end
  local planning = oldest_first(board, "plan")
  if #planning > 0 and #(board["ready"] or {}) < LIMITS["ready"] then
    return {
      kind = "refine",
      issue = planning[1],
      reason = ("ready holds %d/%d — refine a plan issue toward the bar")
      :format(#(board["ready"] or {}), LIMITS["ready"]),
    }
  end
  local plan_count = counted(board, "plan")
  if plan_count < LIMITS["plan"] then
    return {
      kind = "intake",
      reason = ("plan holds %d/%d — work backwards from docs/goals.md")
      :format(plan_count, LIMITS["plan"]),
    }
  end
  return {
    kind = "none",
    reason = "plan and ready are at limit with nothing to check — "
    .. "implementation has to catch up before planning adds more",
  }
end

--- The next action for a role.
--- @param board Board The board
--- @param role string "planner" or "implementer"
--- @param is_open IsOpen Blocker-state oracle
--- @return NextAction | nil The decision
--- @return string Error message for an unknown role
local function next_action(board: Board, role: string,
    is_open: IsOpen): NextAction, string
  if role == "implementer" then
    return next_for_implementer(board, is_open)
  end
  if role == "planner" then
    return next_for_planner(board)
  end
  return nil, "unknown role: " .. tostring(role) ..
  " (expected planner or implementer)"
end

local record model
  type Issue = Issue
  type Board = Board
  type NextAction = NextAction
  type IsOpen = IsOpen
  PHASES: {string}
  LIMITS: {string: integer}
  phase_of: function(labels: {string}): string
  has_marker: function(labels: {string}, marker: string): boolean
  is_return: function(from: string, to: string): boolean
  admits_over_limit: function(issue: Issue, from: string, to: string,
  mandated: boolean): boolean
  counts_against_limit: function(issue: Issue, phase: string): boolean
  limited_count: function(board: Board, phase: string): integer
  blockers: function(body: string): {integer}
  oldest_first: function(board: Board, phase: string): {Issue}
  wip_violations: function(board: Board): {string}
  next_action: function(board: Board, role: string, is_open: IsOpen):
  NextAction, string
end

local M: model = {
  PHASES = PHASES,
  LIMITS = LIMITS,
  phase_of = phase_of,
  has_marker = has_marker,
  is_return = is_return,
  admits_over_limit = admits_over_limit,
  counts_against_limit = counts_against_limit,
  limited_count = counted,
  blockers = blockers,
  oldest_first = oldest_first,
  wip_violations = wip_violations,
  next_action = next_action,
}

return M
