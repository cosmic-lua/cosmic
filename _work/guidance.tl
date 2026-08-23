--- What each kind of next action MEANS: the two or three facts a
--- session needs to act on what `next` just named — what the action
--- is, the verb that performs it, and the ordering rule that put it
--- ahead of everything else.
---
--- Guidance is data, keyed by `decision.KINDS`, so the tool that
--- chooses an action is also the thing that explains it: a kind
--- cannot be added to the ordering and left without an explanation,
--- because `_work/guidance_test.tl` asks the enumeration for its
--- kinds and demands one for each.
---
--- Pure — no git, no filesystem, no network — and deliberately
--- terse. `next` is read once a session, so what is here is what the
--- tool can state as FACT; the judgment a person or agent brings to
--- the action stays in the `work` skill.

--- The text width guidance is fitted to: the house 90 columns less
--- the two-space indent `next` prints it under.
local WIDTH < const >: integer = 88

--- What each kind is, one note per idea. The notes are prose, not
--- display lines: `lines` folds them to the width, so an edit here
--- is about the words alone.
local NOTES < const >: {string: {string}} = {
  ["finish"] = {
    "From `land` the item is already judged: `land ID` squash-merges the PR its "
    .. "`pr` field names and ends the item, in that order.",
    "From `do` it is claimed work, or rework a `request changes` verdict sent "
    .. "back — address the quoted gaps on that PR and hand it over again with "
    .. "`move ID check --pr N`.",
  },
  ["review"] = {
    "An item in `check` awaits a verdict. Read the acceptance evidence in the "
    .. "PR description before the diff; it is what the builder owed you.",
    "Record it with `verdict ID accept|request-changes --pr N --session <you>`; "
    .. "the move it implies follows from the verdict.",
  },
  ["pull"] = {
    "A fresh `ready` item, highest-placed of those nothing blocks. Claim it "
    .. "first with `move ID do --claim <you>`: the move is the lock.",
    "The lock is a lease — a claim whose session stops committing to the board "
    .. "reads as stale after a few hours, and `next` offers the item to whoever "
    .. "asks next.",
    "Then `show ID`: the spec sidecar is the spec; `verdict`/`pr` carry the "
    .. "review state so far.",
  },
  ["unblock"] = {
    "Every `ready` item waits on an open blocker, so nothing pulls however deep "
    .. "the queue is. The item named is the chain's deepest open one.",
    "Resolving it is whatever its own state calls for. When the reason recorded "
    .. "on the edge no longer binds, drop the edge with `unblock ID BLOCKER`.",
  },
  ["refine"] = {
    "Take a `plan` item one rung down the ladder: decompose a container's "
    .. "outcome further, or drive a workable leaf to the ready bar.",
    "`check ID` has to pass before `move ID ready`.",
    "Refinement outranks promotion for the reason finishing outranks starting: "
    .. "what is already committed to is nearer `ready`.",
  },
  ["promote"] = {
    "Commit to the highest-placed `backlog` item nothing blocks: `move ID plan`.",
    "`plan` is a small queue, and that is what makes this a decision — read what "
    .. "else sits near the top of the backlog before taking it.",
  },
  ["sweep"] = {
    "The board is saturated and this `backlog` item — the lowest-placed of those "
    .. "untouched for over a week — is the one to settle.",
    "Two answers: `move ID plan`, or `done ID --reason not-planned`. A backlog "
    .. "carrying work nobody will do is a backlog nobody can read.",
  },
  ["triage"] = {
    "An unplaced capture awaits a decision. `attach ID PARENT` puts it under the "
    .. "outcome or container its evidence serves, entering it in `backlog`; "
    .. "`compare ID OTHER` places it as an outcome in its own right.",
    "Or end it: `done ID` when landed work already covers it, `done ID --reason "
    .. "not-planned` for a recorded dead end.",
  },
  ["intake"] = {
    "Decompose the highest-placed root that no live work drives: "
    .. "`new \"an outcome\" --parent ID`.",
    "A child inherits the position of what it hangs under; ordering a NEW "
    .. "outcome against the existing roots takes a `compare`.",
  },
  ["none"] = {
    "Nothing on the board is this session's to move, and the reason above names "
    .. "what is holding.",
    "Stopping here is the answer: work invented to fill the gap lengthens the "
    .. "backlog without moving anything. Report the bottleneck this names and "
    .. "stop.",
  },
}

--- `text` folded at spaces into lines of at most `width` characters.
--- A word longer than the width takes a line to itself rather than
--- being broken mid-word.
--- @param text string The prose to fold
--- @param width integer The greatest line length produced
--- @return {string} The folded lines
local function wrap(text: string, width: integer): {string}
  local out: {string} = {}
  local line = ""
  for word in text:gmatch("%S+") do
    if line == "" then
      line = word
    elseif #line + 1 + #word <= width then
      line = line .. " " .. word
    else
      out[#out + 1] = line
      line = word
    end
  end
  if line ~= "" then
    out[#out + 1] = line
  end
  return out
end

--- The guidance for one action kind, folded to the width `next`
--- prints it at and ready to be indented. Empty for a kind carrying
--- none, so a caller renders nothing rather than a blank block.
--- @param kind string The action kind
--- @return {string} The display lines, empty when the kind is unknown
local function lines(kind: string): {string}
  local notes = NOTES[kind]
  if notes == nil then
    return {}
  end
  local out: {string} = {}
  for _, note in ipairs(notes) do
    for _, line in ipairs(wrap(note, WIDTH)) do
      out[#out + 1] = line
    end
  end
  return out
end

local record guidance
  WIDTH: integer
  wrap: function(text: string, width: integer): {string}
  lines: function(kind: string): {string}
end

local M: guidance = {
  WIDTH = WIDTH,
  wrap = wrap,
  lines = lines,
}

return M
