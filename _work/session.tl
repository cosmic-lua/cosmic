--- The identity a session presents to the board: what `--session` and
--- `--claim` mean when nobody passes them.
---
--- The board's review distance rests entirely on distinct sessions
--- carrying distinct names — `next --session NAME` withholds a verdict
--- on work NAME built, and `built_by` (`_work.action`) consults the
--- durable `builders` list, so a name reused across runs makes every
--- item those runs produced unreviewable forever. Nothing made the
--- names distinct: each session chose its own string, and a session
--- asked for a name reaches for the readable half of whatever it was
--- given.
---
--- So the name is DERIVED rather than invented. An explicit flag still
--- wins — fixtures, tests and a human at a terminal all need to say
--- who they are — but the ordinary path passes nothing and gets an
--- identity from the environment that is already unique per session
--- and already stable across the many processes one session runs.
---
--- Nothing here refuses: an unnamed session remains legal (it collides
--- with nobody and is offered no verdict on anything), which is what a
--- checkout with none of these variables set still gets.
local os_getenv = os.getenv

--- The environment a session is read from, in order. Each entry is a
--- list of variable names: the FIRST must be set for the source to
--- apply, and any of the rest that are set join onto it with "-", so a
--- runner whose per-run id needs more than one variable to be unique
--- says so by listing them rather than by growing a special case.
---
--- The ladder is ordered by how specific the identity is. A runner's
--- own per-session id beats a per-job id, which beats the person at
--- the keyboard — and `GITBOARD_SESSION` precedes all of them so any
--- runtime this list does not know can name itself without a change
--- here.
---
--- Values are used verbatim. Truncating an id to something prettier is
--- how two sessions start sharing a prefix, which is the whole failure
--- this module exists to prevent.
local SOURCES < const >: {{string}} = {
  -- Any runner, set by hand: the escape hatch that needs no new entry.
  {"GITBOARD_SESSION"},
  -- Claude Code, local or remote: one UUID per session, exported into
  -- every process the session runs.
  {"CLAUDE_CODE_SESSION_ID"},
  -- The remote half alone, for a runner that exports only that one.
  {"CLAUDE_CODE_REMOTE_SESSION_ID"},
  -- GitHub Actions: the run id repeats across the jobs of one workflow
  -- and across re-runs, so the attempt and job name are what make it
  -- one identity per actual run.
  {"GITHUB_RUN_ID", "GITHUB_RUN_ATTEMPT", "GITHUB_JOB"},
  -- A person at a terminal. Stable across days ON PURPOSE: a human
  -- reviewing their own work is exactly what the distance forbids, and
  -- two people on one host still differ.
  {"USER", "HOSTNAME"},
  {"LOGNAME", "HOSTNAME"},
}

--- `s` with surrounding whitespace removed.
--- @param s string The raw value
--- @return string The trimmed value
local function trim(s: string): string
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- One source's value: its lead variable, plus whichever of its
--- companions are set, joined with "-". "" when the lead is unset.
--- @param names {string} The source's variable names, lead first
--- @return string The joined value, "" when this source does not apply
local function value_of(names: {string}): string
  local lead = trim(os_getenv(names[1]) or "")
  if lead == "" then
    return ""
  end
  local parts = {lead}
  for n = 2, #names do
    local extra = trim(os_getenv(names[n]) or "")
    if extra ~= "" then
      parts[#parts + 1] = extra
    end
  end
  return table.concat(parts, "-")
end

--- The identity to record, and where it came from.
---
--- `explicit` is whatever the flag carried — "" or nil when it was not
--- passed. The returned source is for the caller to report: a session
--- that does not know which name it is using cannot notice it is the
--- wrong one.
--- @param explicit string | nil The `--session`/`--claim` value, if any
--- @return string The identity, "" when nothing named this session
--- @return string Where it came from: "flag", a variable name, or "none"
local function resolve(explicit: string | nil): string, string
  local given = trim(explicit or "")
  if given ~= "" then
    return given, "flag"
  end
  for _, names in ipairs(SOURCES) do
    local value = value_of(names)
    if value ~= "" then
      return value, names[1]
    end
  end
  return "", "none"
end

--- One line naming the identity in play, for `status` to print.
---
--- This line is the whole user manual for session identity: a session
--- reads who the board thinks it is and where that came from, instead
--- of a skill telling it what to type. The unnamed case is the one
--- that needs an instruction, so it carries one.
--- @param identity string The resolved identity
--- @param source string The source `resolve` reported
--- @return string The line to print
local function note(identity: string, source: string): string
  if identity == "" then
    return "session: unnamed — nothing here names this run, so its claims "
    .. "carry no builder and it is offered a verdict on anything. Export "
    .. "GITBOARD_SESSION=<unique per run> to fix that."
  end
  if source == "flag" then
    return ("session: %s (passed)"):format(identity)
  end
  return ("session: %s (from %s)"):format(identity, source)
end

local record session
  SOURCES: {{string}}
  resolve: function(explicit: string | nil): (string, string)
  note: function(identity: string, source: string): string
end

local M: session = {
  SOURCES = SOURCES,
  resolve = resolve,
  note = note,
}

return M
