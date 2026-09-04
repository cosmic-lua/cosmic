--- One work item as a committed file: `items/<ksuid>.tl` in the state
--- repository, read/written through `cosmic.literal`, with its prose
--- spec (the spec-bar sections) in a markdown sidecar
--- `items/<ksuid>.md`. There is ONE record and no kind field — an
--- item's role emerges from where it sits in the dependency graph,
--- the same way a file's role in cosmic emerges from its position:
---
---   a root
---     with open children is a container being decomposed
---     with none          is untriaged — captured, not yet placed
---   a parented item
---     with open children is a container being decomposed
---     with none          is workable
---
--- A workable item's state is DERIVED from the facts it carries,
--- never declared: open and unclaimed with no PR is `todo`; a claim
--- or a PR makes it `doing`; a non-empty resolution ends it. The
--- derivation lives in `_work.flow` — this file only validates
--- per-item shape (fields, exclusivity rules).
---
--- There is no goal tier either: every item is the same record, and
--- what makes one more important than another is a committed
--- comparison (`beats`), never a field asserting its own rank. The
--- outcome prose that gives the tree its meaning lives in
--- `docs/goals.md` on `main` and is read by people, not by this.
local identity = require("_work.identity")
local ksuid = require("_work.ksuid")
local shape = require("cosmic.shape")

local record Item
  --- The filename stem and the one name other items use: a KSUID.
  id: string
  title: string
  --- The id this item decomposes; "" for roots.
  parent: string
  --- The owner/name the item's PR lands in; "" = the board's origin.
  repo: string
  --- The branch the item's PR targets; "" = ungated — no verb checks
  --- it and no PR is refused for disagreeing. Set it once a non-`board`
  --- (or non-default) target is known; `gitgate.handover_refusal`
  --- compares it against the PR's own base ref.
  base: string
  --- The scheduled workflow file this item repairs; "" for ordinary
  --- items. `_work.lanes.mint`'s idempotency key: at most one OPEN
  --- item may carry a given lane.
  lane: string
  --- Items this one is ranked ABOVE, each by id: the priority
  --- relation, recorded on the winner of a comparison. Stored as one
  --- "id id" string — the literal domain has no lists. Any item may
  --- carry them; the order itself is derived in `_work.priority`.
  beats: {string}
  --- Open items this one waits on. Stored as one "id id" string —
  --- the literal domain has no lists.
  blocked_by: {string}
  --- Why each blocker binds, by blocker id: what concretely cannot
  --- proceed until it ends. A block is one cheap command with
  --- board-wide flow consequences, and the reason is what lets a
  --- later session judge whether the edge still holds. Entries whose
  --- blocker left `blocked_by` are pruned on the next write.
  block_reason: {string: string}
  --- The session that claimed it; "" when unclaimed.
  claim: string
  --- Every session that has held the claim, oldest first. Stored as
  --- one "name name" string — the literal domain has no lists.
  ---
  --- The claim is a LEASE and moves: a drop clears it and the next
  --- take writes a new one, so the claim alone cannot answer "who has
  --- worked this item". This is that answer — the audit record, never
  --- cleared while the item is open, so who built and who took over
  --- stays readable in the committed file and in the log after the
  --- fact. Outside this module nothing reads it: no verb renders it
  --- and none refuses on it.
  --- `decode` expects this field on the wire as a space-joined string, not this array.
  builders: {string}
  --- Every session that has replaced this item's spec sidecar, oldest
  --- first. Stored and validated exactly like `builders` — same
  --- space-joined string, same no-repeats rule — because the
  --- no-self-review guarantee needs authorship of the SPEC recorded
  --- too: a session offered the review of a decision it wrote is the
  --- same hole `builders` closes for the diff.
  speccers: {string}
  --- The session reviewing the item's PR; "" when nobody claimed the
  --- review. A lease like `claim`, on a shorter horizon
  --- (`_work.health`): the claim is pushed BEFORE the reading starts,
  --- the verdict consumes it.
  reviewer: string
  --- The PR under review; 0 when none.
  pr: integer
  --- The research handover: the spec sidecar's revision
  --- (`_work.spec.revision`) as it stood when `take --result` handed
  --- the item over for a verdict; "" when none. The one deliverable
  --- is a diff OR board state, so `pr` and `result` never both stand,
  --- and a handover records work, so `result` never stands with no
  --- `builders`. `verdict` refuses when the sidecar has moved past it.
  result: string
  --- Standing review verdict: "" | "accept" | "request changes".
  --- A reject stands nowhere: it clears the claim and the PR, so the
  --- item is todo again and the learning lives in its spec.
  verdict: string
  --- Head commit the last verdict was written against.
  verdict_head: string
  --- The spec revision the verdict judged (`_work.spec.revision` of
  --- the sidecar as it stood). A review judges a diff AND the spec it
  --- is measured against, so the head alone cannot say whether a
  --- second look has anything new to see. "" on an item verdicted
  --- before the field existed — unknown, which is not the same as
  --- unchanged, and nothing may be concluded from it.
  verdict_spec: string
  --- Why a finished item ended: "completed" | "not-planned"; "" while
  --- open. A non-empty resolution IS what "done" means.
  resolution: string
  --- Whether this root's win condition is verified to hold. A marker,
  --- not an ending: the root stays open and keeps its place in the
  --- order; intake walks past it, and evidence filed under it clears it.
  is_held: boolean
  --- Content problems `decode` found on this item (`problems(it)`,
  --- possibly several), carried alongside a successful decode instead
  --- of failing it — a read-time snapshot, not a stored fact: nil for
  --- an item built directly (never decoded) or freshly re-decoded
  --- clean, and never written back by `encode`. See `decode` and
  --- `is_flagged`.
  decode_problems: {string} | nil
end

--- The shape `decode`'s input must have. Every field is optional —
--- the literal domain omits zero values on write (see `encode`), so
--- an absent key is ordinary, not a mismatch — and nothing here is
--- coerced: a wrong-typed field is a refusal, not a silent zero.
--- `blocked_by`, `beats` and `builders` validate as the space-joined
--- strings the file actually carries; splitting them into lists is a
--- transform `decode` still does after validation.
local SPEC < const > = shape.record({
    id = shape.optional(shape.string),
    title = shape.optional(shape.string),
    parent = shape.optional(shape.string),
    repo = shape.optional(shape.string),
    base = shape.optional(shape.string),
    lane = shape.optional(shape.string),
    beats = shape.optional(shape.string),
    blocked_by = shape.optional(shape.string),
    block_reason = shape.optional(shape.map(shape.string)),
    claim = shape.optional(shape.string),
    builders = shape.optional(shape.string),
    speccers = shape.optional(shape.string),
    reviewer = shape.optional(shape.string),
    pr = shape.optional(shape.integer),
    result = shape.optional(shape.string),
    verdict = shape.optional(shape.string),
    verdict_head = shape.optional(shape.string),
    verdict_spec = shape.optional(shape.string),
    resolution = shape.optional(shape.string),
    is_held = shape.optional(shape.boolean),
  })

--- The type `shape.into` hands `decode` back: SPEC typed, with every
--- field still optional since the Spec admits absence. Not `Item` —
--- the space-joined list fields and the zero-value defaults are still
--- raw here; `decode` derives `Item` from this after validation.
local record Raw
  id: string | nil
  title: string | nil
  parent: string | nil
  repo: string | nil
  base: string | nil
  lane: string | nil
  beats: string | nil
  blocked_by: string | nil
  block_reason: {string: string} | nil
  claim: string | nil
  builders: string | nil
  speccers: string | nil
  reviewer: string | nil
  pr: integer | nil
  result: string | nil
  verdict: string | nil
  verdict_head: string | nil
  verdict_spec: string | nil
  resolution: string | nil
  is_held: boolean | nil
end

local VERDICTS: {string: boolean} = {
  [""] = true,
  ["accept"] = true,
  ["request changes"] = true,
}

local RESOLUTIONS: {string: boolean} = {
  [""] = true,
  ["completed"] = true,
  ["not-planned"] = true,
}

--- Whether an item is open: done is nothing more than a recorded
--- resolution.
--- @param it Item The item
--- @return boolean True while resolution is empty
local function is_open(it: Item): boolean
  return (it.resolution or "") == ""
end

--- Whether an item is a root: no parent. A root with open children
--- organizes a subtree; a childless one is awaiting triage.
--- @param it Item The item
--- @return boolean True when parentless
local function is_root(it: Item): boolean
  return (it.parent or "") == ""
end

--- The problems an item has on its own, empty when it is valid. One
--- list rather than first-failure, so a hand-edited file reports
--- everything wrong with it at once.
--- @param it Item The item
--- @return {string} Problems, possibly empty
local function problems(it: Item): {string}
  local out: {string} = {}
  if not ksuid.is_id(it.id or "") then
    out[#out + 1] = ("id must be a ksuid: %s"):format(tostring(it.id))
  end
  if it.title == nil or it.title == "" then
    out[#out + 1] = "title must be non-empty"
  elseif it.title:find("[\n\r]") ~= nil then
    out[#out + 1] = "title must be one line: no newlines"
  elseif it.title ~= it.title:match("^%s*(.-)%s*$") then
    out[#out + 1] = "title must not have leading or trailing whitespace"
  end
  if not VERDICTS[it.verdict or ""] then
    out[#out + 1] = ("unknown verdict: %s"):format(tostring(it.verdict))
  end
  if not RESOLUTIONS[it.resolution or ""] then
    out[#out + 1] = ("unknown resolution: %s"):format(tostring(it.resolution))
  end
  if not is_open(it) and ((it.claim or "") ~= "" or (it.reviewer or "") ~= "") then
    out[#out + 1] = "a done item holds no claim and no review"
  end
  if is_root(it) and ((it.claim or "") ~= "" or (it.reviewer or "") ~= ""
    or (it.pr or 0) ~= 0
    or (it.verdict or "") ~= "" or (it.repo or "") ~= ""
    or (it.base or "") ~= "") then
    out[#out + 1] =
    "claim/reviewer/pr/verdict/repo/base belong to worked items, not roots"
  end
  if not is_root(it) and it.is_held then
    out[#out + 1] = "is_held marks an outcome root; a parented item is never held"
  end
  if not is_open(it) and it.is_held then
    out[#out + 1] = "is_held marks an open root; a done item never carries it"
  end
  if (it.pr or 0) ~= 0 and (it.result or "") ~= "" then
    out[#out + 1] = "pr and result never both stand: a deliverable is a diff "
    .. "or board state, never both"
  end
  if (it.result or "") ~= "" and #(it.builders or {}) == 0 then
    out[#out + 1] = "result records a handover, and an item nobody built has "
    .. "no work to hand over"
  end
  if (it.repo or "") ~= "" and not it.repo:match("^[%w%-%.]+/[%w%-%._]+$") then
    out[#out + 1] = ("repo must be owner/name: %s"):format(it.repo)
  end
  if (it.base or "") ~= "" and not it.base:match("^[%w%-%._/]+$") then
    out[#out + 1] = ("base must be a branch name: %s"):format(it.base)
  end
  local blocked_seen: {string: boolean} = {}
  for _, b in ipairs(it.blocked_by or {}) do
    if not ksuid.is_id(b) then
      out[#out + 1] = ("blocked_by names a non-id: %s"):format(tostring(b))
    elseif b == it.id then
      out[#out + 1] = "blocked_by names the item itself; nothing waits on itself"
    elseif blocked_seen[b] then
      out[#out + 1] = ("blocked_by repeats %s"):format(b)
    else
      blocked_seen[b] = true
    end
  end
  local built_seen: {string: boolean} = {}
  for _, name in ipairs(it.builders or {}) do
    if built_seen[name] then
      out[#out + 1] = ("builders repeats %s"):format(name)
    else
      built_seen[name] = true
    end
  end
  local specced_seen: {string: boolean} = {}
  for _, name in ipairs(it.speccers or {}) do
    if specced_seen[name] then
      out[#out + 1] = ("speccers repeats %s"):format(name)
    else
      specced_seen[name] = true
    end
  end
  local beats_seen: {string: boolean} = {}
  for _, b in ipairs(it.beats or {}) do
    if not ksuid.is_id(b) then
      out[#out + 1] = ("beats names a non-id: %s"):format(tostring(b))
    elseif b == it.id then
      out[#out + 1] = "beats names the item itself; nothing outranks itself"
    elseif beats_seen[b] then
      out[#out + 1] = ("beats repeats %s"):format(b)
    else
      beats_seen[b] = true
    end
  end
  return out
end

--- An item from the table `cosmic.literal` parsed, with zero values
--- filled in and every field shape-checked. Unknown keys are ignored,
--- so a file carrying retired fields still reads — and sheds them on
--- its next write.
---
--- This fails hard only on genuine corruption: an unparseable literal
--- (the caller's `literal.parse_file`) or a field of the wrong type
--- (`shape.into` against `SPEC`, below). A CONTENT problem —
--- `problems(it)` non-empty: a multiline title, a claimed root, a
--- repeated blocker, and so on — does not fail the decode; the
--- constructed `Item` comes back with `problems(it)` attached at
--- `.decode_problems` instead (`is_flagged` reads it). A store with
--- one such record, written by an older or less careful writer, still
--- decodes every item, and the bad one can still be corrected in
--- place (`gitboard set --title ...` loads through this same decode).
--- The write path is unaffected: `store.stage` and `cmd_new` call
--- `problems(it)` directly and refuse there, before a bad record is
--- ever committed.
--- @param t {string: any} Parsed literal table
--- @return Item | nil The item, present even with content problems
--- @return string Error message; set only when the literal is corrupt
local function decode(t: {string: any}): Item | nil, string
  local raw, err: Raw | nil, string = shape.into(t, SPEC)
  if not raw then
    return nil, err
  end
  local blocked: {string} = {}
  for ref in (raw.blocked_by or ""):gmatch("%S+") do
    blocked[#blocked + 1] = ref
  end
  local reasons: {string: string} = {}
  for k, v in pairs(raw.block_reason or {}) do
    reasons[k] = v
  end
  local beats: {string} = {}
  for ref in (raw.beats or ""):gmatch("%S+") do
    beats[#beats + 1] = ref
  end
  local builders: {string} = {}
  for name in (raw.builders or ""):gmatch("%S+") do
    builders[#builders + 1] = name
  end
  local speccers: {string} = {}
  for name in (raw.speccers or ""):gmatch("%S+") do
    speccers[#speccers + 1] = name
  end
  local it: Item = {
    id = raw.id or "",
    title = raw.title or "",
    parent = raw.parent or "",
    repo = raw.repo or "",
    base = raw.base or "",
    lane = raw.lane or "",
    beats = beats,
    blocked_by = blocked,
    block_reason = reasons,
    claim = raw.claim or "",
    builders = builders,
    speccers = speccers,
    reviewer = raw.reviewer or "",
    pr = raw.pr or 0,
    result = raw.result or "",
    verdict = raw.verdict or "",
    verdict_head = raw.verdict_head or "",
    verdict_spec = raw.verdict_spec or "",
    resolution = raw.resolution or "",
    is_held = raw.is_held or false,
  }
  local bad = problems(it)
  if #bad > 0 then
    it.decode_problems = bad
  end
  return it
end

--- Whether `decode` flagged content problems on this item. Read-path
--- tolerance only: a freshly `decode`d item that is actually clean
--- reports false the same as one built directly and never decoded.
--- @param it Item The item
--- @return boolean True when `.decode_problems` names at least one
local function is_flagged(it: Item): boolean
  return #(it.decode_problems or {}) > 0
end

--- The literal table an item writes: zero values omitted, so the file
--- carries only what is set and a diff shows only what moved.
--- @param it Item The item
--- @return {string: any} Table for `cosmic.literal.format_file`
local function encode(it: Item): {string: any}
  local t: {string: any} = {
    id = it.id,
    title = it.title,
  }
  if (it.parent or "") ~= "" then t.parent = it.parent end
  if (it.repo or "") ~= "" then t.repo = it.repo end
  if (it.base or "") ~= "" then t.base = it.base end
  if (it.lane or "") ~= "" then t.lane = it.lane end
  if #(it.beats or {}) > 0 then
    t.beats = table.concat(it.beats, " ")
  end
  if #(it.blocked_by or {}) > 0 then
    t.blocked_by = table.concat(it.blocked_by, " ")
    -- Reasons ride only for blockers still named, so an entry whose
    -- edge was dropped heals on the next write, the way a duplicate
    -- blocker does.
    local reasons: {string: string} = {}
    local any_reason = false
    for _, b in ipairs(it.blocked_by) do
      local why = (it.block_reason or {})[b]
      if why ~= nil and why ~= "" then
        reasons[b] = why
        any_reason = true
      end
    end
    if any_reason then
      t.block_reason = reasons
    end
  end
  if (it.claim or "") ~= "" then t.claim = it.claim end
  if #(it.builders or {}) > 0 then
    t.builders = table.concat(it.builders, " ")
  end
  if #(it.speccers or {}) > 0 then
    t.speccers = table.concat(it.speccers, " ")
  end
  if (it.reviewer or "") ~= "" then t.reviewer = it.reviewer end
  if (it.pr or 0) ~= 0 then t.pr = it.pr end
  if (it.result or "") ~= "" then t.result = it.result end
  if (it.verdict or "") ~= "" then t.verdict = it.verdict end
  if (it.verdict_head or "") ~= "" then t.verdict_head = it.verdict_head end
  if (it.verdict_spec or "") ~= "" then t.verdict_spec = it.verdict_spec end
  if (it.resolution or "") ~= "" then t.resolution = it.resolution end
  if it.is_held then t.is_held = true end
  return t
end

local record item
  type Item = Item
  is_open: function(it: Item): boolean
  is_root: function(it: Item): boolean
  is_flagged: function(it: Item): boolean
  problems: function(it: Item): {string}
  identity_refusal: function(session: string): string
  record_involvement: function(list: {string}, session: string): boolean, string
  decode: function(t: {string: any}): Item | nil, string
  encode: function(it: Item): {string: any}
end

local M: item = {
  is_open = is_open,
  is_root = is_root,
  is_flagged = is_flagged,
  problems = problems,
  identity_refusal = identity.identity_refusal,
  record_involvement = identity.record_involvement,
  decode = decode,
  encode = encode,
}

return M
