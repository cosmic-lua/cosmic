--- The `friction:` roll-call gate for `new`, split from `_work.gitgraph`
--- (which sits against the file cap): whether a friction log's spec
--- names every agent the filing session claimed work under since the
--- pass began. Reads the board log alone; it never opens a transcript.
local publish = require("_work.publish")
local store = require("_work.store")

--- The label kinds a minted claim can carry — `_work.brief`'s own
--- `LABEL_KIND` values, not exported there, so restated by the words
--- rather than by a shared import that would reach across a public/
--- internal seam for five constant strings.
local LABEL_KINDS < const >: {string: boolean} = {
  build = true, research = true, review = true, refine = true,
  decompose = true,
}

--- The agent one board-log commit's subject names, when it mints or
--- reclaims a claim under a label ending in `orch8` — the session
--- whose own claims a `friction:` filing must account for. "" for a
--- commit that mints no claim, or whose label belongs to a different
--- session. A build/research/refine/decompose claim commits as `take
--- ID by LABEL`; a review claim (`_work.gittake.take_review`) commits
--- as `review ID claimed by LABEL` instead — both are checked, since
--- a claim is minted either way (`_work.brief.mint_label`'s doc).
--- @param subject string One board-log commit subject
--- @param orch8 string This session's own `<orch8>`
--- @return string The label's kind ("build", "review", ...), "" when none
--- @return string The label's handle (the item's bare tail), "" when none
local function claim_agent(subject: string, orch8: string): string, string
  local label = subject:match("^take %S+ by (%S+)")
  or subject:match("^review %S+ claimed by (%S+)")
  if label == nil then
    return "", ""
  end
  local suffix = "-" .. orch8
  if #label <= #suffix or label:sub(-#suffix) ~= suffix then
    return "", ""
  end
  local kind, handle = label:sub(1, #label - #suffix):match("^(%a+)%-(.+)$")
  if kind == nil or handle == nil or not LABEL_KINDS[kind] then
    return "", ""
  end
  return kind, handle
end

--- The refusal a `friction:`-titled filing earns when its spec does
--- not name every agent this orchestrator's own session claimed work
--- under since the pass began — nil when it may proceed.
---
--- "Since the pass began" is the board log, newest first, back to the
--- previous `friction:` item's own `new` commit (the pass boundary —
--- an orchestrator works one board pass at a time, so in the ordinary
--- case that is this same session's own last filing) or the whole log
--- on a first pass. Every `take`/`review` commit in that window whose
--- label ends in this session's `orch8` is a claim to account for;
--- this never opens a transcript, only the log against the board.
--- @param s store.Store The store
--- @param session_id string This session's own identity
--- @param spec_text string The friction log body, as given to `new`
--- @return string | nil The refusal
local function friction_refusal(s: store.Store, session_id: string,
    spec_text: string): string
  local orch8 = session_id:sub(1, 8)
  if orch8 == "" then
    orch8 = "unnamed"
  end
  local events, herr = publish.history(s, nil)
  if events == nil then
    return "REFUSED: could not read the board log: " .. herr
  end
  -- Collected oldest first, so the refusal reads as the pass unfolded.
  local seen: {string: boolean} = {}
  local agents: {{string, string}} = {}
  for _, ev in ipairs(events) do
    if ev.subject:match("^new %S+ friction:") then
      break
    end
    local kind, handle = claim_agent(ev.subject, orch8)
    if kind ~= "" then
      local key = kind .. " " .. handle
      if not seen[key] then
        seen[key] = true
        agents[#agents + 1] = {kind, handle}
      end
    end
  end
  if #agents == 0 then
    return nil
  end
  local missing: {string} = {}
  for i = #agents, 1, -1 do
    local kind, handle = agents[i][1], agents[i][2]
    local heading = "\n##%s+" .. kind .. "%s+" .. handle
    if not ("\n" .. spec_text):find(heading, 1, false) then
      missing[#missing + 1] = kind .. " " .. handle
    end
  end
  if #missing == 0 then
    return nil
  end
  return ("REFUSED: friction log names %d of %d agents — missing %s — name "
    .. "each with a `## <kind> <handle>` heading (run `cosmic "
    .. "_tool/friction.tl <transcript>...` on the ones you still have and "
    .. "paste its block in), or file anyway with --force --why '<why the "
    .. "transcripts are gone>'"):format(#agents - #missing, #agents,
    table.concat(missing, ", "))
end

local record gitfriction
  claim_agent: function(subject: string, orch8: string): string, string
  friction_refusal: function(s: store.Store, session_id: string,
  spec_text: string): string
end

local M: gitfriction = {
  claim_agent = claim_agent,
  friction_refusal = friction_refusal,
}

return M
