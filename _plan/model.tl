--- The board model: columns, WIP limits, the ready bar, and the
--- right-to-left pull order, as pure functions over already-fetched
--- issues. No network, no subprocess — board.tl fetches through
--- _plan.gh and decides here, so every flow rule skills/plan/ asks an
--- agent to follow has exactly one executable definition, pinned by
--- model_test.tl.

--- One issue as the board sees it, already reduced from the gh JSON.
local record Issue
  number: integer
  title: string
  column: string
  epic: boolean
  finding: boolean
  enable: boolean
  assignee: string
  url: string
  body: string
end

--- Open issues grouped by column name ("shaping" ... "review").
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

--- Column order, left to right; pull works from the END of this list.
local COLUMNS: {string} = {"shaping", "ready", "doing", "review"}

--- WIP limits are policy, and policy is committed: tune them here, in
--- a reviewed change, never ad hoc per session. Empirical basis (the
--- 2026-08-16 flow review: 468 min of board history, 52 issues, 13
--- merged PRs, reconstructed from label events):
--- shaping's 12 is the binding constraint — it spent 222 min (47% of
--- the session) at or over limit, and every refusal incident on record
--- traces to it; the number stays and epics are exempted instead (see
--- `counts_against_limit`), since they occupied an average 4.8 of the
--- 12 slots (45% of the column's item-minutes) without being work in
--- progress.
--- ready drops from 20 to 12 — it peaked at 16 only during initial
--- fill and never came within 4 of 20 afterward, with a floor of 6,
--- while median ready->doing pickup latency was 81 min (p75: 278) —
--- long enough that queue inventory measurably went stale (tree-facts
--- drift on #1115; three regenerated-baseline conflict reworks). A
--- tighter cap forces staler entries to drain instead of sitting.
--- doing's 5 and review's 10 are unchanged and healthy: doing peaked
--- 5/5 for 17 min, review peaked 7/10 and never bound.
--- Tripwires: revisit doing if its time-at-limit grows once the `land`
--- verb exists (finished work awaiting landing then occupies claim
--- slots too); revisit review only if its peak ever exceeds 8.
local LIMITS: {string: integer} = {
  shaping = 12,
  ready = 12,
  doing = 5,
  review = 10,
}

--- Headings a plan:ready issue body must carry (the ready bar; the
--- meaning of each section is skills/plan/decompose.md).
local READY_SECTIONS: {string} = {
  "Goal", "Change", "Non-goals", "Acceptance", "Enablement",
}

local COLUMN_SET: {string: boolean} = {}
local COLUMN_INDEX: {string: integer} = {}
for idx, c in ipairs(COLUMNS) do
  COLUMN_SET[c] = true
  COLUMN_INDEX[c] = idx
end

--- Whether moving from one column to another is a return: leftward
--- motion between two known columns. WIP limits gate rightward motion
--- and planner intake only. Returns always land, even over the limit;
--- an over-limit column blocks further pull until it drains. A bounce
--- back to shaping and a rework send-back are the system correcting
--- itself, so nothing may refuse them. Anything else — an unknown
--- `from` (an issue not on the board, which is an entry), the same
--- column, or rightward motion — is not a return.
--- @param from string Current column name, or nil when not on the board
--- @param to string Target column name
--- @return boolean True when the move is leftward between known columns
local function is_return(from: string, to: string): boolean
  local a = COLUMN_INDEX[from]
  local b = COLUMN_INDEX[to]
  return a ~= nil and b ~= nil and b < a
end

--- Whether an issue occupies a WIP-limit slot in a column: false
--- exactly for an epic sitting in shaping, true otherwise. An epic is
--- a container that lives in shaping until every child closes — not
--- work in progress — and counting it against the limit starves the
--- column (measured: epics permanently occupied an average 4.8 of
--- shaping's 12 slots).
--- @param issue Issue The issue
--- @param column string Column the issue is being counted in
--- @return boolean True when the issue counts against the column's limit
local function counts_against_limit(issue: Issue, column: string): boolean
  return not (column == "shaping" and issue.epic)
end

--- Occupancy of one column, counting only issues that count against its
--- limit (an epic in shaping does not). The one counting path every WIP
--- check and display shares, so the epic exemption applies everywhere
--- at once.
--- @param board Board The board
--- @param column string Column name
--- @return integer Filtered occupancy
local function counted(board: Board, column: string): integer
  local n = 0
  for _, i in ipairs(board[column] or {}) do
    if counts_against_limit(i, column) then
      n = n + 1
    end
  end
  return n
end

--- The column a label set places an issue in, or nil when it carries
--- no plan:<column> label.
--- @param labels {string} Label names on the issue
--- @return string | nil Column name
local function column_of(labels: {string}): string
  for _, l in ipairs(labels) do
    local col = l:match("^plan:(%l+)$")
    if col and COLUMN_SET[col] then
      return col
    end
  end
  return nil
end

--- Whether a label set carries a given marker label.
--- @param labels {string} Label names on the issue
--- @param marker string Marker name without the plan: prefix
--- @return boolean True when present
local function has_marker(labels: {string}, marker: string): boolean
  for _, l in ipairs(labels) do
    if l == "plan:" .. marker then
      return true
    end
  end
  return false
end

--- Ready-bar lint: the required sections a body is missing or has
--- left empty. A heading counts at any level ("## Goal", "# goal"),
--- matched on the heading text alone, case-insensitively — and only
--- when at least one non-blank line follows it before the next
--- heading, so a pasted template with hollow sections still fails.
--- A thematic break (---) ends the current section: trailing footers
--- appended below one are nobody's content.
--- @param body string Issue body markdown
--- @return {string} Missing/empty section names, in READY_SECTIONS order
local function ready_gaps(body: string): {string}
  local filled: {string: boolean} = {}
  local current: string = nil
  for line in (body .. "\n"):gmatch("([^\n]*)\n") do
    local text = line:match("^#+%s+(.-)%s*$")
    if text then
      current = text:lower()
      if filled[current] == nil then
        filled[current] = false
      end
    elseif line:match("^%s*%-%-%-+%s*$") then
      current = nil
    elseif current and line:match("%S") then
      filled[current] = true
    end
  end
  local missing: {string} = {}
  for _, name in ipairs(READY_SECTIONS) do
    if not filled[name:lower()] then
      missing[#missing + 1] = name
    end
  end
  return missing
end

--- One measurable claim parsed from a ```facts fenced block: a shell
--- command and the stdout it must produce.
local record Fact
  command: string
  expected: string
end

--- Measurable claims parsed from every ```facts fenced block in a body.
--- Inside such a block, a line starting "$ " begins a command; the
--- following non-"$ " lines, up to the next "$ " line or the fence
--- close, are its expected stdout (joined with "\n", no trailing
--- newline). A block with no facts block returns an empty list. A
--- non-empty line before the first "$ " in a block, or a facts block
--- left unclosed at end of body, is malformed and returns nil plus a
--- message naming the problem and its line.
--- @param body string Issue body markdown
--- @return {Fact} | nil Parsed facts, possibly empty
--- @return string Error message naming the problem and its line
local function facts(body: string): {Fact} | nil, string
  local normalized = body:gsub("\r\n", "\n")
  local out: {Fact} = {}
  local state = "none" -- "none" | "facts" | "fence"
  local open_line = 0
  local cur: Fact = nil
  local expected: {string} = {}
  local lineno = 0
  for line in (normalized .. "\n"):gmatch("([^\n]*)\n") do
    lineno = lineno + 1
    if state == "none" then
      local info = line:match("^```(%S*)%s*$")
      if info == "facts" then
        state = "facts"
        open_line = lineno
      elseif info ~= nil then
        state = "fence"
      end
    elseif state == "fence" then
      if line:match("^```%s*$") then
        state = "none"
      end
    else -- state == "facts"
      if line:match("^```%s*$") then
        if cur then
          cur.expected = table.concat(expected, "\n")
          out[#out + 1] = cur
        end
        state = "none"
        cur = nil
      else
        local command = line:match("^%$%s+(.-)%s*$")
        if command then
          if cur then
            cur.expected = table.concat(expected, "\n")
            out[#out + 1] = cur
          end
          cur = {command = command}
          expected = {}
        elseif cur then
          expected[#expected + 1] = line
        elseif line:match("%S") then
          return nil, ("facts: line %d: content before first $ command"):format(lineno)
        end
      end
    end
  end
  if state == "facts" then
    return nil, ("facts: line %d: unclosed block"):format(open_line)
  end
  return out
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

--- Issues of one column, oldest (lowest number) first. Returns a new
--- sorted copy; the board is data, not scratch.
--- @param board Board The board
--- @param column string Column name
--- @return {Issue} Sorted issues, possibly empty
local function oldest_first(board: Board, column: string): {Issue}
  local list: {Issue} = {}
  for _, i in ipairs(board[column] or {}) do
    list[#list + 1] = i
  end
  table.sort(list, function(a: Issue, b: Issue): boolean
      return a.number < b.number
    end)
  return list
end

--- WIP-limit violations, one line each ("doing 3/2 over limit").
--- @param board Board The board
--- @return {string} Violations, left-to-right column order
local function wip_violations(board: Board): {string}
  local out: {string} = {}
  for _, col in ipairs(COLUMNS) do
    local n = counted(board, col)
    if n > LIMITS[col] then
      out[#out + 1] = ("%s %d/%d over limit"):format(col, n, LIMITS[col])
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
--- to completion moves first. Doing — which holds both fresh claims
--- and rework a review verdict sent back — comes before pulling
--- (oldest first, with the pullable ready issue as the fallback for a
--- second concurrent session); then the oldest unblocked ready issue;
--- otherwise there is nothing to pull and a planner session is the
--- answer (review-column items wait on a planner, never on more
--- implementation).
--- @param board Board The board
--- @param is_open IsOpen Blocker-state oracle
--- @return NextAction The decision
local function next_for_implementer(board: Board, is_open: IsOpen): NextAction
  local doing = oldest_first(board, "doing")
  local pullable = first_pullable(board, is_open)
  if #doing > 0 then
    local reason = ("doing holds %d/%d — finish before pulling"):format(
      #doing, LIMITS["doing"])
    if pullable then
      reason = reason .. ("; if #%d is another live session's claim, pull #%d")
      :format(doing[1].number, pullable.number)
    end
    return {kind = "finish", issue = doing[1], alt = pullable, reason = reason}
  end
  if pullable then
    return {
      kind = "pull",
      issue = pullable,
      reason = "oldest ready issue with no open blocker",
    }
  end
  local waiting = #(board["review"] or {})
  local bottleneck = ""
  if waiting > 0 then
    bottleneck = ("; %d issue(s) await planner review — that verdict is "
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

--- The planner's next action, right to left: review waiting work
--- first; then refine shaping into ready while ready has slack; then
--- intake from the goals while shaping has slack; else nothing.
--- @param board Board The board
--- @return NextAction The decision
local function next_for_planner(board: Board): NextAction
  local review = oldest_first(board, "review")
  if #review > 0 then
    return {
      kind = "review",
      issue = review[1],
      reason = "review is the rightmost occupied column — verdicts first",
    }
  end
  local shaping = oldest_first(board, "shaping")
  if #shaping > 0 and #(board["ready"] or {}) < LIMITS["ready"] then
    return {
      kind = "refine",
      issue = shaping[1],
      reason = ("ready holds %d/%d — refine shaping toward the bar"):format(
        #(board["ready"] or {}), LIMITS["ready"]),
    }
  end
  local shaping_count = counted(board, "shaping")
  if shaping_count < LIMITS["shaping"] then
    return {
      kind = "intake",
      reason = ("shaping holds %d/%d — work backwards from docs/goals.md")
      :format(shaping_count, LIMITS["shaping"]),
    }
  end
  return {
    kind = "none",
    reason = "shaping and ready are at limit with nothing to review — "
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
  type Fact = Fact
  COLUMNS: {string}
  LIMITS: {string: integer}
  READY_SECTIONS: {string}
  column_of: function(labels: {string}): string
  has_marker: function(labels: {string}, marker: string): boolean
  is_return: function(from: string, to: string): boolean
  counts_against_limit: function(issue: Issue, column: string): boolean
  ready_gaps: function(body: string): {string}
  blockers: function(body: string): {integer}
  facts: function(body: string): {Fact} | nil, string
  oldest_first: function(board: Board, column: string): {Issue}
  wip_violations: function(board: Board): {string}
  next_action: function(board: Board, role: string, is_open: IsOpen):
  NextAction, string
end

local M: model = {
  COLUMNS = COLUMNS,
  LIMITS = LIMITS,
  READY_SECTIONS = READY_SECTIONS,
  column_of = column_of,
  has_marker = has_marker,
  is_return = is_return,
  counts_against_limit = counts_against_limit,
  ready_gaps = ready_gaps,
  blockers = blockers,
  facts = facts,
  oldest_first = oldest_first,
  wip_violations = wip_violations,
  next_action = next_action,
}

return M
