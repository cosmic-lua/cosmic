--- Pure rendering helpers for the board's status line: the exempt-class
--- suffix (e.g. "(+7 epics, +9 findings)") and the finding-pressure
--- line that stands in for a WIP limit on a class the limit no longer
--- counts. No network, no printing — `verbs.cmd_status` calls these
--- and prints the result, keeping `_work.model` free of display logic
--- and `verbs.tl` free of the counting logic `_work.model` already
--- owns.

local model = require("_work.model")
local time = require("cosmic.time")

local type Issue = model.Issue

--- The exempt-class suffix for a phase's occupancy line, naming every
--- exempt class actually present in a fixed epics-then-findings order.
--- Empty when the phase exempts nothing — every phase but `plan` today,
--- and `plan` itself once it holds neither. Classifies only the issues
--- `counts_against_limit` already skips, so a phase whose exemption
--- rule changes needs no new branch here.
--- @param list {Issue} Every issue in the phase
--- @param phase string Phase name
--- @return string The suffix, e.g. " (+7 epics, +9 findings)", or ""
local function exempt_suffix(list: {Issue}, phase: string): string
  local epics = 0
  local findings = 0
  for _, i in ipairs(list) do
    if not model.counts_against_limit(i, phase) then
      if i.epic then
        epics = epics + 1
      else
        findings = findings + 1
      end
    end
  end
  local parts: {string} = {}
  if epics > 0 then
    parts[#parts + 1] = ("+%d epics"):format(epics)
  end
  if findings > 0 then
    parts[#parts + 1] = ("+%d findings"):format(findings)
  end
  if #parts == 0 then
    return ""
  end
  return " (" .. table.concat(parts, ", ") .. ")"
end

--- The finding-pressure line for `plan`: the count and the age in days
--- of the oldest one, e.g. "  findings: 9 (oldest 4d old)", or
--- "  findings: 0" when none are held. An untriaged finding does not
--- self-drain the way an epic does when its children close, so this
--- line is the signal that replaces the WIP limit for that class.
--- @param list {Issue} Every issue in `plan`, oldest first
--- @return string The line to print
local function finding_pressure(list: {Issue}): string
  local count = 0
  local oldest: Issue = nil
  for _, i in ipairs(list) do
    if i.finding then
      count = count + 1
      oldest = oldest or i
    end
  end
  if count == 0 then
    return "  findings: 0"
  end
  local age_days = 0
  if oldest.created_at then
    local created = time.parse_iso8601(oldest.created_at)
    if created then
      age_days = math.floor((time.now() - created) / 86400)
    end
  end
  return ("  findings: %d (oldest %dd old)"):format(count, age_days)
end

local record render
  exempt_suffix: function(list: {Issue}, phase: string): string
  finding_pressure: function(list: {Issue}): string
end

local M: render = {
  exempt_suffix = exempt_suffix,
  finding_pressure = finding_pressure,
}

return M
