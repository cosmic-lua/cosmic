--- The board's close verb: the end of an issue's life when there is
--- no PR to close it through — a finding triaged away, an epic whose
--- outcome now holds, a research slice accepted on its comment, a
--- slice rejected outright. A landing closes its issue through the
--- merge instead, so `land` owns that path and this verb never
--- touches a PR. Same shape as `_work/verbs.tl` — cmd_close takes
--- plain arguments, prints its own output including the trailing
--- `work-close:` verdict line, and returns the process exit code.
--- Argument parsing and dispatch live in board.tl.

local gh = require("_work.github")
local model = require("_work.model")

--- The `state_reason` GitHub records for each spelling the verb
--- accepts. `completed` is work that happened: an epic whose outcome
--- was verified, a research slice accepted. `not-planned` is a
--- recorded dead end, kept forever: a finding triaged away, a slice
--- rejected because the work should not happen at all.
local REASONS: {string: string} = {
  completed = "completed",
  ["not-planned"] = "not_planned",
}

--- The phases a close may be issued from. `plan` is where shaping
--- decides an issue will not be worked and where an epic waits out its
--- children; `check` is where a verdict lands on a deliverable that
--- has nothing to merge. The other three hold work someone is
--- carrying — `ready` is queued, `do` is claimed, `land` is accepted
--- and awaiting its merge — and closing from them would make a card
--- vanish mid-flow. The way out of those is a move, which is leftward
--- and therefore never refused: `move N plan`, then close.
local CLOSABLE: {string: boolean} = {plan = true, check = true}

--- Pure: the GitHub `state_reason` a flag value names, or nil when the
--- value is not one the verb accepts.
--- @param reason string Flag value: "completed" or "not-planned"
--- @return string | nil The API's spelling of it
local function state_reason(reason: string): string
  return REASONS[reason]
end

--- Pure: whether the phase a label set places an issue in admits a
--- close. An issue on no phase carries no card to lose, so it always
--- does.
--- @param labels {string} Label names on the issue
--- @return boolean True when a close is admissible from that phase
local function admits_close(labels: {string}): boolean
  local phase = model.phase_of(labels)
  return phase == nil or CLOSABLE[phase] == true
end

--- close: close an issue, recording whether the work happened. Labels
--- are left alone — the board lists open issues only, so a closed card
--- leaves the board by being closed, and its phase label stays as the
--- history the flow stats replay. The phase gate is the one refusal:
--- an issue still in `ready`, `do` or `land` is work in flight, and
--- the way to end it is `move N plan` first, so the departure is
--- recorded as a move rather than a disappearance.
--- @param repo string "owner/name"
--- @param number integer Issue number
--- @param reason string "completed" or "not-planned"
--- @return integer Exit code
local function cmd_close(repo: string, number: integer, reason: string): integer
  local state = state_reason(reason)
  if state == nil then
    io.stderr:write(("unknown reason: %s (expected completed or not-planned)\n")
      :format(reason))
    print("work-close: ERROR")
    return 1
  end
  local raw, err = gh.get_issue(repo, number)
  if raw == nil then
    io.stderr:write(err .. "\n")
    print("work-close: ERROR")
    return 1
  end
  if (raw.state or ""):upper() == "CLOSED" then
    print(("work-close: REFUSED (#%d is already closed)"):format(number))
    return 1
  end
  local names: {string} = {}
  for _, l in ipairs(raw.labels or {}) do
    names[#names + 1] = l.name
  end
  if not admits_close(names) then
    print(("work-close: REFUSED (#%d is in %s; a close there loses a card "
        .. "mid-flow — move it to plan first)"):format(
        number, model.phase_of(names)))
    return 1
  end
  local closed, cerr = gh.close_issue(repo, number, state)
  if closed == nil then
    io.stderr:write(cerr .. "\n")
    print("work-close: ERROR")
    return 1
  end
  print("  " .. closed.html_url)
  print(("work-close: #%d %s"):format(number, reason))
  return 0
end

local record close
  state_reason: function(reason: string): string
  admits_close: function(labels: {string}): boolean
  cmd_close: function(repo: string, number: integer, reason: string): integer
end

local M: close = {
  state_reason = state_reason,
  admits_close = admits_close,
  cmd_close = cmd_close,
}

return M
