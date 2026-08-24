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

--- The environment variables consulted, in order, for a session that
--- passed no name. `GITBOARD_SESSION` is the one this tool defines, so
--- any runner can set it; the rest are well-known ids belonging to
--- runtimes that already mint one per session. A value is used
--- verbatim — truncating an id to something prettier is how two
--- sessions start sharing a prefix.
local SOURCES < const >: {string} = {
  "GITBOARD_SESSION",
  "CLAUDE_CODE_SESSION_ID",
}

--- `s` with surrounding whitespace removed.
--- @param s string The raw value
--- @return string The trimmed value
local function trim(s: string): string
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- The identity to record, and where it came from.
---
--- `explicit` is whatever the flag carried — "" or nil when it was not
--- passed. The returned source is for the caller to report: a session
--- that does not know which name it is using cannot notice it is the
--- wrong one.
--- @param explicit string | nil The `--session`/`--claim` value, if any
--- @return string The identity, "" when nothing named this session
--- @return string Where it came from: "flag", an env var name, or "none"
local function resolve(explicit: string | nil): string, string
  local given = trim(explicit or "")
  if given ~= "" then
    return given, "flag"
  end
  for _, name in ipairs(SOURCES) do
    local value = trim(os_getenv(name) or "")
    if value ~= "" then
      return value, name
    end
  end
  return "", "none"
end

--- One line naming the identity in play, for a verb that acts on it,
--- or "" when the identity was passed explicitly (the caller already
--- knows) or nothing named the session at all. Derivation is the case
--- worth printing: it is the only one where the name in the commit is
--- not the name the session typed.
--- @param identity string The resolved identity
--- @param source string The source `resolve` reported
--- @return string The note, or "" when there is nothing to say
local function note(identity: string, source: string): string
  if identity == "" or source == "flag" or source == "none" then
    return ""
  end
  return ("session %s (from %s)"):format(identity, source)
end

local record session
  SOURCES: {string}
  resolve: function(explicit: string | nil): (string, string)
  note: function(identity: string, source: string): string
end

local M: session = {
  SOURCES = SOURCES,
  resolve = resolve,
  note = note,
}

return M
