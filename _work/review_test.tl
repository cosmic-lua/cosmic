#!/usr/bin/env cosmic
-- What a pull request must be before a reviewer is handed it. Pure
-- over a fetched request, so these run with no token and no network —
-- which is the point of splitting the judgment from the fetching.

local review = require("_work.review")

local ID < const > = "3I1J6VKzSO5y7dsunDY7fBwFdUz"

--- An open, non-draft request whose body carries the item; `over`
--- replaces any field.
local function pull(over: {string: any}): review.Pull
  local p: review.Pull = {
    number = 42,
    draft = false,
    body = "Board: " .. ID .. "\n\nthe fix, and how it was run.",
    head_sha = "cafe1234",
    base = "main",
    state = "open",
  }
  for k, v in pairs(over or {}) do
    if k == "number" and v is integer then p.number = v end
    if k == "draft" and v is boolean then p.draft = v end
    if k == "body" and v is string then p.body = v end
    if k == "base" and v is string then p.base = v end
    if k == "state" and v is string then p.state = v end
  end
  return p
end

local function test_a_sound_request_passes()
  assert(review.blocks_check(pull({}), ID) == nil,
    "open, offered, and joined to its item")
end
test_a_sound_request_passes()

local function test_a_draft_is_not_ready_to_read()
  local msg = review.blocks_check(pull({draft = true}), ID)
  assert(msg ~= nil and msg:find("draft", 1, true), "got: " .. tostring(msg))
end
test_a_draft_is_not_ready_to_read()

local function test_a_closed_request_carries_nothing()
  local msg = review.blocks_check(pull({state = "closed"}), ID)
  assert(msg ~= nil and msg:find("closed", 1, true), "got: " .. tostring(msg))
end
test_a_closed_request_carries_nothing()

local function test_a_body_that_names_no_item_is_unjoined()
  local msg = review.blocks_check(pull({body = "a fix"}), ID)
  assert(msg ~= nil and msg:find("Board:", 1, true), "got: " .. tostring(msg))
end
test_a_body_that_names_no_item_is_unjoined()

-- The short form is what a human writes and what the skill's PR
-- convention shows, so it has to join the request too.
local function test_an_eight_character_prefix_joins_it()
  local short = pull({body = "Board: " .. ID:sub(1, 8)})
  assert(review.blocks_check(short, ID) == nil,
    "the prefix names the item as well as the full id does")
end
test_an_eight_character_prefix_joins_it()

-- The artifact rides along in ordinary prose constantly (a live
-- measurement of this repo's last 30 PR bodies found it in 28), so
-- outside any code span it is not a signal and must pass clean —
-- otherwise the check refuses nearly every correct handover,
-- including this one's own body.
local function test_a_prose_artifact_outside_code_passes_clean()
  local body = "Board: " .. ID .. "\n\ndon&#39;t merge until CI is green."
  assert(review.blocks_check(pull({body = body}), ID) == nil,
    "a prose artifact outside any code span is not a sanitization signal")
end
test_a_prose_artifact_outside_code_passes_clean()

-- The same artifact inside a backtick span is the one place
-- sanitization corrupts what a reviewer relies on: a reader trusts a
-- code span's exact characters, and this one has been rewritten.
local function test_an_artifact_inside_a_backtick_span_blocks()
  local body = "Board: " .. ID .. "\n\nrun `it&#39;s fine` locally first."
  local msg = review.blocks_check(pull({body = body}), ID)
  assert(msg ~= nil and msg:find("sanitiz", 1, true), "got: " .. tostring(msg))
end
test_an_artifact_inside_a_backtick_span_blocks()

-- Same for a fenced block, and for the numeric quote artifact — this
-- transport emits numeric `&#34;`, never the named `&quot;`, so the
-- numeric form is the one that has to be caught.
local function test_an_artifact_inside_a_fenced_block_blocks()
  local body = "Board: " .. ID .. "\n\n```\nrun &#34;cosmic --make ci&#34;\n```"
  local msg = review.blocks_check(pull({body = body}), ID)
  assert(msg ~= nil and msg:find("sanitiz", 1, true), "got: " .. tostring(msg))
end
test_an_artifact_inside_a_fenced_block_blocks()

-- A plain apostrophe or quote — never entity-escaped — carries no
-- artifact and passes clean, in or out of a code span.
local function test_a_plain_apostrophe_does_not_block()
  local body = "Board: " .. ID .. "\n\n`don't merge` until CI is green."
  assert(review.blocks_check(pull({body = body}), ID) == nil,
    "a literal apostrophe is not a sanitization artifact")
end
test_a_plain_apostrophe_does_not_block()

-- An opening fence with no closing fence must not leak its third
-- backtick into the inline pass: if it did, that backtick would pair
-- with the later, unrelated inline backtick around "real code" and
-- produce a phantom span covering all the ordinary prose in between —
-- including this artifact, which sits in that prose, not in any real
-- code span.
local function test_an_unclosed_fence_does_not_leak_into_inline_pass()
  local body = "Board: " .. ID .. "\n\n"
  .. "```oops i opened a fence and forgot to close it. "
  .. "meanwhile, in unrelated prose way down here, don&#39;t worry, "
  .. "it's fine -- until later someone writes `real code`."
  assert(review.blocks_check(pull({body = body}), ID) == nil,
    "an unclosed fence must not turn intervening prose into a phantom span")
end
test_an_unclosed_fence_does_not_leak_into_inline_pass()

-- An unclosed fence's own remainder is ambiguous — it could be code
-- that never got its closing fence, or prose that merely started with
-- three backticks — so an artifact inside it does not fire either.
-- False positives, not misses, are what bounced this item twice, so
-- the ambiguous case reads as NOT a code span.
local function test_an_unclosed_fence_remainder_artifact_does_not_block()
  local body = "Board: " .. ID .. "\n\n"
  .. "```run &#34;cosmic --make ci&#34; but forgot the closing fence"
  assert(review.blocks_check(pull({body = body}), ID) == nil,
    "an unclosed fence's own content is not treated as a code span")
end
test_an_unclosed_fence_remainder_artifact_does_not_block()

-- An item that names a base is refused when the PR targets something
-- else — the mismatch names both sides and the fix (retarget, or set
-- --base), never one alone.
local function test_a_mismatched_base_blocks()
  local msg = review.blocks_base(pull({base = "release"}), "main")
  assert(msg ~= nil, "a PR targeting the wrong branch is refused")
  assert(msg:find("#42", 1, true), "it names the PR: " .. msg)
  assert(msg:find("release", 1, true), "the PR's actual base: " .. msg)
  assert(msg:find("main", 1, true), "the item's recorded base: " .. msg)
end
test_a_mismatched_base_blocks()

-- A PR whose base matches the item's recorded base passes cleanly.
local function test_a_matching_base_passes()
  assert(review.blocks_base(pull({base = "main"}), "main") == nil,
    "the PR's base agrees with the item's")
end
test_a_matching_base_passes()

-- An item with no base field is UNGATED: today's behavior, and what
-- lets board-machinery items whose PRs target `board` stand without
-- backfill.
local function test_an_absent_base_is_ungated()
  assert(review.blocks_base(pull({base = "some-other-branch"}), "") == nil,
    "no recorded base means nothing is compared")
end
test_an_absent_base_is_ungated()

local function test_a_concluded_failure_blocks()
  local msg = review.blocks_on_ci({
      {name = "ci", status = "completed", conclusion = "success"},
      {name = "build", status = "completed", conclusion = "failure"},
    })
  assert(msg ~= nil and msg:find("build", 1, true), "got: " .. tostring(msg))
end
test_a_concluded_failure_blocks()

-- Silence is not success, but it is not failure either: a run still
-- going is a reason to come back, never a reason to refuse.
local function test_running_and_absent_checks_do_not_block()
  assert(review.blocks_on_ci({}) == nil, "no runs yet")
  assert(review.blocks_on_ci({
        {name = "ci", status = "in_progress", conclusion = ""},
      }) == nil, "a run in flight")
  assert(review.blocks_on_ci({
        {name = "ci", status = "completed", conclusion = "cancelled"},
      }) == nil, "a cancelled run concluded nothing about the code")
end
test_running_and_absent_checks_do_not_block()

-- An accept asserts the work is fit to land, so the one request state
-- it cannot survive is closed with nothing merged: no diff to land,
-- and no `land` step that could produce one. A merged request is the
-- opposite case, not a refusal — and since GitHub reports a merged
-- request as `closed`, the two are told apart by `merged`, never by
-- state alone.
local function test_blocks_accept_refuses_a_closed_unmerged_pr()
  local open_pr: review.Pull = {number = 1, state = "open", merged = false,
    draft = false, body = "", head_sha = "abc", merge_sha = ""}
  assert(review.blocks_accept(open_pr) == nil, "the ordinary path")

  local merged: review.Pull = {number = 2, state = "closed", merged = true,
    draft = false, body = "", head_sha = "abc", merge_sha = "def"}
  assert(review.blocks_accept(merged) == nil,
    "a merged request reads as closed and must not be refused")

  local abandoned: review.Pull = {number = 3, state = "closed",
    merged = false, draft = false, body = "", head_sha = "abc",
    merge_sha = ""}
  local refusal = review.blocks_accept(abandoned)
  assert(refusal ~= nil and refusal:find("nothing to land", 1, true),
    "got: " .. tostring(refusal))
  assert(refusal:find("#3", 1, true), "it names the PR: " .. refusal)
end
test_blocks_accept_refuses_a_closed_unmerged_pr()

-- Landing ends an item over a merge that has already happened, so an
-- unmerged request is refused and the refusal is a work order: merge
-- it, then run the same verb again. Nothing here attempts a merge, so
-- the refusal has to say who does.
local function test_blocks_land_refuses_an_unmerged_request()
  local open_pr: review.Pull = {number = 7, state = "open", merged = false,
    draft = false, body = "", head_sha = "cafe1234567", merge_sha = ""}
  local refusal = review.blocks_land(open_pr, "cafe1234567", ID)
  assert(refusal ~= nil and refusal:find("is not merged", 1, true),
    "got: " .. tostring(refusal))
  assert(refusal:find("#7", 1, true), "it names the PR: " .. refusal)
  assert(refusal:find("Squash-merge", 1, true),
    "it names the act the caller performs: " .. refusal)
  assert(refusal:find("`gitboard land " .. ID:sub(1, 8) .. "`", 1, true),
    "and the verb to re-run, on this item: " .. refusal)
end
test_blocks_land_refuses_an_unmerged_request()

-- A merged request is the whole precondition: `land` reads the merge
-- and ends the item, whatever head carries it. A head that moved past
-- the accept is reported by `head_moved` and cannot be undone, so it
-- is not a second refusal here.
local function test_blocks_land_passes_a_merged_request()
  local merged: review.Pull = {number = 7, state = "closed", merged = true,
    draft = false, body = "", head_sha = "beef7654321",
    merge_sha = "d00d0000"}
  assert(review.blocks_land(merged, "cafe1234567", ID) == nil,
    "a merged request leaves nothing to refuse")
  assert(review.blocks_land(merged, "", ID) == nil,
    "nor does one accepted before the verdict recorded a head")
end
test_blocks_land_passes_a_merged_request()

-- An accept judges one head, and a merge of any other lands a diff no
-- reviewer read. The comparison says so — before the merge, inside
-- the refusal, and after it, in the warning the landing prints. An
-- item accepted before the verdict recorded a head has nothing to
-- compare and must not be stranded.
local function test_head_moved_compares_the_accepted_head()
  local at: review.Pull = {number = 7, state = "open", merged = false,
    draft = false, body = "", head_sha = "cafe1234567", merge_sha = ""}
  assert(review.head_moved(at, "cafe1234567") == false,
    "the head the accept judged is the head in front of us")
  assert(review.head_moved(at, "beef7654321") == true,
    "any other head is a substitution")
  assert(review.head_moved(at, "") == false,
    "an item accepted before the head was recorded is not stranded")

  local refusal = review.blocks_land(at, "beef7654321", ID)
  assert(refusal:find("beef765", 1, true), "the judged head: " .. refusal)
  assert(refusal:find("cafe123", 1, true), "the current head: " .. refusal)
  assert(refusal:find("re-review", 1, true),
    "and what to do before merging it: " .. refusal)
end
test_head_moved_compares_the_accepted_head()

-- A head that is not even the right shape is refused whether or not a
-- PR stands to check it against — everything downstream treats the
-- stored field as an opaque string, and a non-hex value would just
-- make those comparisons silently never match.
local function test_head_refusal_rejects_a_head_too_short()
  local msg = review.head_refusal(nil, "abc123")
  assert(msg ~= nil and msg:find("git sha", 1, true), "got: " .. tostring(msg))
end
test_head_refusal_rejects_a_head_too_short()

local function test_head_refusal_rejects_non_hex()
  local msg = review.head_refusal(nil, "xyz1234")
  assert(msg ~= nil and msg:find("git sha", 1, true), "got: " .. tostring(msg))
end
test_head_refusal_rejects_non_hex()

-- Uppercase hex is not the shape stored elsewhere: git shas are
-- reported and compared lowercase, so an uppercase caller is refused
-- rather than silently normalized.
local function test_head_refusal_rejects_uppercase()
  local msg = review.head_refusal(nil, "ABC1234")
  assert(msg ~= nil and msg:find("git sha", 1, true), "got: " .. tostring(msg))
end
test_head_refusal_rejects_uppercase()

-- A shape-valid head still has to prefix-match the PR's own full
-- head: the caller may hand over a short sha, but nothing shorter
-- than the PR's truth is honest.
local function test_head_refusal_rejects_a_mismatched_prefix()
  local at: review.Pull = {number = 7, state = "open", merged = false,
    draft = false, body = "", head_sha = "cafe1234567", merge_sha = ""}
  local msg = review.head_refusal(at, "beef123")
  assert(msg ~= nil and msg:find("#7", 1, true), "got: " .. tostring(msg))
end
test_head_refusal_rejects_a_mismatched_prefix()

local function test_head_refusal_passes_a_matched_prefix()
  local at: review.Pull = {number = 7, state = "open", merged = false,
    draft = false, body = "", head_sha = "cafe1234567", merge_sha = ""}
  assert(review.head_refusal(at, "cafe123") == nil,
    "a genuine prefix of the PR's head")
  assert(review.head_refusal(at, "cafe1234567") == nil,
    "the PR's full head matches itself")
end
test_head_refusal_passes_a_matched_prefix()

-- No PR read yet — a local-only board, or the shape-only pass before
-- one — means only the shape is judged.
local function test_head_refusal_with_no_pr_judges_shape_only()
  assert(review.head_refusal(nil, "cafe123") == nil,
    "a shape-valid head with nothing to check it against")
end
test_head_refusal_with_no_pr_judges_shape_only()
