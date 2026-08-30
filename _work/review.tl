--- What a pull request must be before an item may sit in `check`, as
--- pure functions over an already-fetched request. The fetching is
--- `_work.gh`; the judgment is here, so every rule below is testable
--- without a token and without a network.
---
--- These are review PRECONDITIONS, not the review: a planner still
--- reads the diff and gives the verdict. What they enforce is that a
--- reviewer is never handed something there is no point reading yet —
--- a draft, a request that names no item, or one whose CI has already
--- concluded that it fails.
local record Pull
  number: integer
  --- Still a draft: the author has not offered it for review.
  draft: boolean
  body: string
  head_sha: string
  --- The branch the request targets, "" when GitHub reported none.
  base: string
  --- "open" | "closed"
  state: string
  --- Already merged, by any route.
  merged: boolean
  --- The merge commit, "" until the request is merged.
  merge_sha: string
end

--- One CI check on a head commit, reduced to what a gate reads.
local record CheckRun
  name: string
  --- "queued" | "in_progress" | "completed"
  status: string
  --- "success" | "failure" | "cancelled" | ...; "" while running.
  conclusion: string
end

--- Conclusions that mean the head is known bad. A cancelled or skipped
--- run is not a failure, and a run still going is not a verdict — an
--- in-flight check is a reason to come back, never a reason to refuse.
local FAILED: {string: boolean} = {
  ["failure"] = true, ["timed_out"] = true, ["action_required"] = true,
  ["startup_failure"] = true,
}

--- Entity-escape artifacts the MCP transport's HTML sanitizer leaves in
--- a body. Only the numeric forms are checked: this transport emits
--- numeric `&#34;` for quotes, never the named `&quot;`, and `&#39;`
--- (apostrophe) is the one that shows up constantly — in ordinary
--- prose, not just in code.
local ARTIFACTS: {string} = {"&#39;", "&#34;"}

--- The code spans of a markdown body: fenced ``` blocks first — so
--- their own backtick delimiters are spent before the inline pass sees
--- them, rather than pairing into bogus one-character spans — then
--- inline `...` spans over what is left.
--- @param body string The body to scan
--- @return {string} Each span's inner text, in no particular order
local function code_spans(body: string): {string}
  local spans: {string} = {}
  local rest = body
  while true do
    local s = rest:find("```", 1, true)
    if not s then break end
    local e = rest:find("```", s + 3, true)
    if not e then break end
    spans[#spans + 1] = rest:sub(s + 3, e - 1)
    rest = rest:sub(1, s - 1) .. rest:sub(e + 3)
  end
  local pos = 1
  while true do
    local s = rest:find("`", pos, true)
    if not s then break end
    local e = rest:find("`", s + 1, true)
    if not e then break end
    spans[#spans + 1] = rest:sub(s + 1, e - 1)
    pos = e + 1
  end
  return spans
end

--- Whether an entity-escape artifact appears inside a code span of a
--- markdown body — the one place sanitization corrupts the meaning a
--- reviewer relies on. Live measurement (30 PR bodies on this repo)
--- found the artifact in ordinary prose 28 times out of 30 — an
--- any-artifact-anywhere check would refuse nearly every correct
--- handover, so only a code-span occurrence is worth a refusal.
--- @param body string The body to scan
--- @return boolean True when an artifact appears inside a code span
local function has_sanitized_code(body: string): boolean
  for _, span in ipairs(code_spans(body)) do
    for _, needle in ipairs(ARTIFACTS) do
      if span:find(needle, 1, true) then
        return true
      end
    end
  end
  return false
end

--- The refusal a pull request earns before it may carry an item into
--- `check`, or nil when it may.
---
--- One of these findings is not about the request's shape but about
--- its transport: the MCP transport that authors PR bodies HTML-
--- sanitizes them, entity-escaping quotes even inside code blocks and
--- deleting tag-shaped text. That is detected here, never fixed —
--- decoding or rewriting the body is out of scope, and so is stopping
--- the sanitizer, which lives upstream. Flagging it before handover is
--- what keeps a reviewer from trusting a quoted command or string the
--- transport already garbled. The check is narrowed to code spans (see
--- `has_sanitized_code`) because the same artifact rides along in
--- ordinary prose far too often to be a signal there.
--- @param p Pull The fetched pull request
--- @param id string The item's id
--- @return string | nil The refusal
local function blocks_check(p: Pull, id: string): string
  if p.state ~= "open" then
    return ("PR #%d is %s — a closed request carries nothing to review")
    :format(p.number, p.state)
  end
  if p.draft then
    return ("PR #%d is a draft — offer it for review before handing it over")
    :format(p.number)
  end
  local body = p.body or ""
  if not body:find("Board: " .. id, 1, true)
  and not body:find("Board: " .. id:sub(1, 8), 1, true) then
    return ("PR #%d's body does not carry `Board: %s`, so nothing joins the "
      .. "request to its item"):format(p.number, id:sub(1, 8))
  end
  if has_sanitized_code(body) then
    return ("PR #%d's body carries an entity-escape artifact inside a code "
      .. "span — the MCP transport HTML-sanitized it in transit, so a "
      .. "quoted command or string there may not be reliable"):format(p.number)
  end
  return nil
end

--- The refusal a pull request's base branch earns against what the
--- item's `base` field records, or nil when they agree or the item
--- names none.
---
--- The field is opt-in: an item with no `base` is UNGATED, which is
--- what lets board-machinery items whose PRs target `board` (not
--- `main`) stand without ever setting the field, and what an item
--- filed before this gate existed keeps meaning.
--- @param p Pull The fetched pull request
--- @param base string The item's base field, "" when it names none
--- @return string | nil The refusal
local function blocks_base(p: Pull, base: string): string
  local want = base or ""
  if want == "" then
    return nil
  end
  if (p.base or "") == want then
    return nil
  end
  return ("PR #%d targets %s, the item says %s — retarget the PR or set "
    .. "--base"):format(p.number, p.base, want)
end

--- The refusal a head's CI earns, or nil when nothing has concluded
--- failure. Silence is not success and is not refused here: a head
--- with no runs yet, or runs still going, passes this gate and meets
--- the planner's own reading instead, which asks for a green run on
--- the CURRENT head.
--- @param runs {CheckRun} The head's check runs
--- @return string | nil The refusal
local function blocks_on_ci(runs: {CheckRun}): string
  local failed: {string} = {}
  for _, r in ipairs(runs) do
    if r.status == "completed" and FAILED[r.conclusion or ""] then
      failed[#failed + 1] = r.name
    end
  end
  if #failed == 0 then
    return nil
  end
  return ("CI has already concluded failure on this head (%s) — fix it "
    .. "before asking for a verdict"):format(table.concat(failed, ", "))
end

--- The refusal an ACCEPT earns from the state of its pull request, or
--- nil when the accept may proceed.
---
--- An accept asserts that the work is fit to land, so the one state it
--- cannot survive is a request that is closed with nothing merged:
--- there is no diff to land and no `land` step that could produce one.
--- Routing such an item onward puts it in `land` carrying an accept,
--- where the merge PUT is refused and `next` re-answers the same
--- finish forever.
---
--- A merged request is NOT refused — it is the opposite case, where
--- the landing has already happened; the caller reads `merged` and
--- ends the item. Open is the ordinary path.
--- @param p Pull The request the accept judges
--- @return string The refusal, nil when the accept may proceed
local function blocks_accept(p: Pull): string
  if p.state ~= "open" and not p.merged then
    return ("PR #%d is %s and unmerged — there is nothing to land; reopen "
      .. "it, or reject the item"):format(p.number, p.state)
  end
  return nil
end

--- Whether a pull request's head is not the head an accept judged.
---
--- An accept is a judgment of one head. A request that has moved
--- since — the builder pushed again after the verdict — carries a
--- diff no reviewer read, which is worth saying before the merge and
--- worth recording after it.
---
--- An empty `verdict_head` is not a move: an item accepted before the
--- verdict recorded a head has nothing to compare.
--- @param p Pull The request
--- @param verdict_head string The head the accept judged
--- @return boolean True when the request's head is not the judged one
local function head_moved(p: Pull, verdict_head: string): boolean
  local judged = verdict_head or ""
  return judged ~= "" and judged ~= (p.head_sha or "")
end

--- The refusal a LANDING earns from its pull request, or nil when the
--- item may be ended.
---
--- Landing is two acts by two hands: the merge, performed by whoever
--- runs the board, and the item's end, performed by `land` once it
--- has read the merge. So the one state a landing cannot survive is a
--- request that is not merged — there is nothing to end the item
--- over, and the repair is to merge it and run `land` again, which
--- finds it merged and finishes.
---
--- A head that has moved past the accept is named in the same
--- refusal, because that merge is still ahead: merging as it stands
--- lands a diff no reviewer read.
--- @param p Pull The request the item names
--- @param verdict_head string The head the accept judged
--- @param id string The item being landed
--- @return string The refusal, nil when the request is merged
local function blocks_land(p: Pull, verdict_head: string, id: string): string
  if p.merged then
    return nil
  end
  local msg = ("PR #%d is not merged — `land` ends an item whose merge is "
    .. "done, it does not merge. Squash-merge PR #%d, then re-run "
    .. "`gitboard land %s`, which reads the merge and ends the item.")
  :format(p.number, p.number, id:sub(1, 8))
  if head_moved(p, verdict_head) then
    msg = msg .. (" The accept judged %s and the head is now %s — re-review "
      .. "before merging."):format((verdict_head or ""):sub(1, 7),
      (p.head_sha or ""):sub(1, 7))
  end
  return msg
end

--- The refusal a verdict's `--head` earns, or nil when it may be
--- recorded.
---
--- The shape half applies whether or not a request stands to check
--- against: everything downstream (the pair guard, `head_moved`)
--- treats the stored field as an opaque string, and a non-hex value
--- would just make those silently never match instead of refusing
--- where the mistake is legible. The PR half applies only when `p` is
--- given: the caller may pass a short sha, so the true test is a
--- PREFIX match against the PR's own full head — nothing shorter is
--- honest, and nothing here trusts the caller past that.
--- @param p Pull | nil The PR to verify against, when one was read
--- @param head string The head the caller wants recorded
--- @return string | nil The refusal
local function head_refusal(p: Pull | nil, head: string): string
  local h = head or ""
  if not h:match("^[0-9a-f]+$") or #h < 7 or #h > 40 then
    return ("--head %q is not a git sha — 7 to 40 lowercase hex characters")
    :format(h)
  end
  if p ~= nil then
    local full = p.head_sha or ""
    if full:sub(1, #h) ~= h then
      return ("--head %s does not match PR #%d's head %s"):format(
        h, p.number, full:sub(1, 7))
    end
  end
  return nil
end

local record review
  type Pull = Pull
  type CheckRun = CheckRun
  blocks_check: function(p: Pull, id: string): string
  blocks_base: function(p: Pull, base: string): string
  blocks_accept: function(p: Pull): string
  head_moved: function(p: Pull, verdict_head: string): boolean
  blocks_land: function(p: Pull, verdict_head: string, id: string): string
  blocks_on_ci: function(runs: {CheckRun}): string
  head_refusal: function(p: Pull | nil, head: string): string
end

local M: review = {
  blocks_check = blocks_check,
  blocks_base = blocks_base,
  blocks_accept = blocks_accept,
  head_moved = head_moved,
  blocks_land = blocks_land,
  blocks_on_ci = blocks_on_ci,
  head_refusal = head_refusal,
}

return M
