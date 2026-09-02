--- What each kind of next action MEANS: the two or three facts a
--- session needs to act on what `next` just named — what the action
--- is, the verb that performs it, and the ordering rule that put it
--- ahead of everything else.
---
--- Guidance is data, keyed by `decision.KINDS`, so the tool that
--- chooses an action is also the thing that explains it: a kind
--- cannot be added to the ordering and left without an explanation,
--- because `_work/guidance_test.tl` asks the enumeration for its
--- kinds and demands one for each. One kind reads differently by
--- what the item it names delivers — a review of a research
--- handover (`result`) records its verdict with no PR to cite — so a
--- kind may carry a second note set the item selects.
---
--- Pure — no git, no filesystem, no network — and deliberately
--- terse. `next` is read once a session, so what is here is what the
--- tool can state as FACT; the judgment a person or agent brings to
--- the action stays in the `work` skill.

local item = require("_work.item")

local type Item = item.Item

--- The text width guidance is fitted to: the house 90 columns less
--- the two-space indent `next` prints it under.
local WIDTH < const >: integer = 88

--- What each kind is, one note per idea. The notes are prose, not
--- display lines: `lines` folds them to the width, so an edit here
--- is about the words alone.
local NOTES < const >: {string: {string}} = {
  ["finish"] = {
    "An accepted item awaits its merge: `done ID` verifies the PR its `pr` "
    .. "field names is merged and ends the item — merge first, then done.",
    "A rework carries a `request changes` verdict: address the quoted gaps on "
    .. "the same PR and hand it back with `take ID --pr N`, which re-opens the "
    .. "verdict for the new head.",
    "A build with no PR yet is yours to finish: open the PR ready with "
    .. "`Board: <id>` in its body, then `take ID --pr N` — CI proves the "
    .. "gate, so the body carries no evidence.",
  },
  ["review"] = {
    "Claim it first — `take ID` on an item awaiting a verdict locks the diff "
    .. "before you read a line; a claim idle past the hour lease is anyone's "
    .. "again.",
    "CI proves the gate; judge what it cannot — spec vs diff, a mutation "
    .. "test — then `verdict ID accept|request-changes --pr N --head SHA "
    .. "--session <you>`.",
    "The verdict comes from a fresh-context reviewer that never held the "
    .. "build; no session accepts its own work.",
  },
  ["pull"] = {
    "The highest-placed todo item passing the spec bar with nothing blocking "
    .. "it. `take ID` is the claim and the lock; the lock is a lease, and a "
    .. "claim idle past it is anyone's again.",
    "Then `show ID`: the spec sidecar is the spec; re-run its measured "
    .. "commands before building.",
  },
  ["unblock"] = {
    "Every takeable item waits on an open blocker, so nothing pulls however "
    .. "deep the queue is. The item named is the chain's deepest open one.",
    "Resolving it is whatever its own state calls for. When the reason recorded "
    .. "on the edge no longer binds, drop the edge with `unblock ID BLOCKER`.",
  },
  ["refine"] = {
    "Drive the highest-placed todo item toward the spec bar: `show ID` names "
    .. "the gaps, `spec ID FILE --base BASE` writes the refinement back.",
    "Decompose rather than pad: a spec that needs the word \"and\" between two "
    .. "independent changes is two items (`new \"child\" --parent ID`).",
    "Every tree-fact measured, with its command, so the taker re-runs it in "
    .. "seconds.",
  },
  ["triage"] = {
    "An unplaced capture awaits a decision. `attach ID PARENT` makes it todo "
    .. "under the outcome its evidence serves; `compare ID OTHER` makes it an "
    .. "outcome itself.",
    "No outcome fits? Attach under the lowest-placed one regardless: it outranks "
    .. "nothing, `attach` re-parents freely, and an unplaced item can never be "
    .. "taken.",
    "Or end it: `done ID` when landed work covers it, `--reason not-planned` for "
    .. "a dead end.",
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

--- The notes for a kind when the item it names is a research
--- handover: its deliverable is the spec at the recorded revision,
--- so the verdict cites no PR and no head. A kind absent here reads
--- the same for a handover as for a diff.
local HANDOVER_NOTES < const >: {string: {string}} = {
  ["finish"] = {
    "An accepted handover has no PR to merge: `done ID` ends it directly — "
    .. "no merge to await, unlike a diff.",
    "A rework carries a `request changes` verdict: address the quoted gaps "
    .. "and hand the revision back with `take ID --result`, which re-opens "
    .. "the verdict for the new revision.",
    "A handover with no verdict yet is yours to finish: revise the findings, "
    .. "then `take ID --result` hands the spec over — no PR, so the "
    .. "revision itself is the evidence.",
  },
  ["review"] = {
    "Claim it first — `take ID` on an item awaiting a verdict locks the spec "
    .. "before you read a line; a claim idle past the hour lease is anyone's "
    .. "again.",
    "No diff to gate: judge the spec at the revision `result` records against "
    .. "the evidence it cites, then "
    .. "`verdict ID <accept|request-changes|reject> --session <you>`.",
    "The verdict comes from a fresh-context reviewer that never held the "
    .. "build; no session accepts its own work.",
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
--- none, so a caller renders nothing rather than a blank block. The
--- item the action names selects the handover reading of a kind
--- when it carries a `result`; without an item, the diff reading.
--- @param kind string The action kind
--- @param it item.Item | nil The item the action names, when it names one
--- @return {string} The display lines, empty when the kind is unknown
local function lines(kind: string, it?: Item): {string}
  local notes = NOTES[kind]
  if it ~= nil and (it.result or "") ~= "" and HANDOVER_NOTES[kind] ~= nil then
    notes = HANDOVER_NOTES[kind]
  end
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
  lines: function(kind: string, it?: Item): {string}
end

local M: guidance = {
  WIDTH = WIDTH,
  wrap = wrap,
  lines = lines,
}

return M
