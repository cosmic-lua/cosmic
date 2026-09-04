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

--- Every `## <kind> <handle>` heading a spec names, as `"<kind>
--- <handle>"` keys — how a past filing's own roll call is read back,
--- to tell an already-reported claim from one still outstanding.
--- @param spec_text string A friction log's body
--- @return {string: boolean} The set of headings it names
local function named_headings(spec_text: string): {string: boolean}
  local out: {string: boolean} = {}
  for kind, handle in ("\n" .. spec_text):gmatch("\n##%s+(%a+)%s+(%S+)") do
    out[kind .. " " .. handle] = true
  end
  return out
end

--- The refusal a `friction:`-titled filing earns when its spec does
--- not name every agent this orchestrator's own session ever claimed
--- work under and has not already accounted for — nil when it may
--- proceed.
---
--- There is no session field on a `new` commit, so a past `friction:`
--- filing cannot be attributed to an orchestrator by reading the log
--- alone — the previous design's fix would have been to find "the
--- previous friction item THIS orchestrator filed" and could not: it
--- fell back to the most recent filing by ANYONE, which a concurrent
--- orchestrator's own, unrelated filing (naming its own claims, or
--- correctly naming none) silently satisfied on this one's behalf.
---
--- Instead: a claim is "accounted for" once it has been named as a
--- heading in SOME already-filed `friction:` item, whoever filed it —
--- sound because a filing only ever names its own filer's claims (the
--- same `kind handle` pairs `claim_agent` derives from that filer's
--- own `orch8`), so a heading naming this orchestrator's claim could
--- only have come from this orchestrator's own earlier filing. Every
--- `take`/`review` commit in the WHOLE log whose label ends in this
--- session's `orch8` is a claim to weigh against that; this never
--- opens a transcript, only the log and past specs, both on the board.
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
  -- The board log is newest first; walk it oldest to newest so the
  -- claims list reads as the pass unfolded and past filings are
  -- gathered in the order they were filed.
  local seen: {string: boolean} = {}
  local agents: {{string, string}} = {}
  local past_filing_ids: {string} = {}
  for i = #events, 1, -1 do
    local ev = events[i]
    local filed = ev.subject:match("^new (%S+) friction:")
    if filed then
      past_filing_ids[#past_filing_ids + 1] = filed
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
  local accounted_for: {string: boolean} = {}
  for _, short_id in ipairs(past_filing_ids) do
    local full_id = store.resolve(s, short_id)
    if full_id then
      for key in pairs(named_headings(store.read_spec(s, full_id))) do
        accounted_for[key] = true
      end
    end
  end
  -- Outstanding: this orchestrator's own claims no past filing has
  -- already named. Only these are weighed against THIS filing.
  local outstanding: {string} = {}
  for i = 1, #agents do
    local key = agents[i][1] .. " " .. agents[i][2]
    if not accounted_for[key] then
      outstanding[#outstanding + 1] = key
    end
  end
  if #outstanding == 0 then
    return nil
  end
  local this_filing = named_headings(spec_text)
  local missing: {string} = {}
  for _, key in ipairs(outstanding) do
    if not this_filing[key] then
      missing[#missing + 1] = key
    end
  end
  if #missing == 0 then
    return nil
  end
  return ("REFUSED: friction log names %d of %d agents — missing %s — name "
    .. "each with a `## <kind> <handle>` heading (run `cosmic "
    .. "_tool/friction.tl <transcript>...` on the ones you still have and "
    .. "paste its block in), or file anyway with --force --why '<why the "
    .. "transcripts are gone>'"):format(#outstanding - #missing, #outstanding,
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
