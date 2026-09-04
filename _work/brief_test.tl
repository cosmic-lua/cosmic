#!/usr/bin/env cosmic
-- The brief verb: board facts fill, the spec rides verbatim, what the
-- board cannot answer survives as a placeholder the verdict line
-- names, and the refusals hold — an unknown kind, a spec-less item
-- for the kinds that carry the spec, a review with no PR recorded.

local check = require("cosmic.check")
local env = require("cosmic.env")
local fs = require("cosmic.fs")
local brief = require("_work.brief")
local fixture = require("_work.fixture")
local store = require("_work.store")
local tail = require("_work.tail")
local verbs = require("_work.gitverbs")

local init_state_repo = fixture.init_state_repo
local give_spec = fixture.give_spec
local root_with_leaf = fixture.root_with_leaf

--- Pin the session identity `_work.session` derives for the duration
--- of a test, so a minted label's `<orch8>` is a known, fixed value
--- rather than whatever ambient identity this process happens to
--- carry. `GITBOARD_SESSION` leads the ladder, so setting only it is
--- enough regardless of what else the environment sets.
--- @param id string The session identity to pin
local function pin_session(id: string)
  check.must(env.set("GITBOARD_SESSION", id))
end

--- Undo `pin_session`, restoring the derivation to whatever the
--- ambient environment (if anything) names.
local function unpin_session()
  local _ok, _err = env.unset("GITBOARD_SESSION")
end

--- Run brief.cmd_brief and capture exactly what it prints via
--- print() — the swap-and-restore pattern the other verb tests use.
--- @param s store.Store The store
--- @param kind string The brief kind
--- @param id string The item id
--- @return integer cmd_brief's exit code
--- @return string Every print()'d line, newline-joined
local function brief_and_capture(s: store.Store, kind: string,
    id: string): integer, string
  local old_print = _G.print
  local lines: {string} = {}
  _G.print = function(...: any)
    local parts: {string} = {}
    for i = 1, select("#", ...) do
      parts[i] = tostring((select(i, ...)))
    end
    lines[#lines + 1] = table.concat(parts, "\t")
  end
  local ok, result = pcall(brief.cmd_brief, s, kind, id)
  _G.print = old_print
  if not ok then
    error(result, 0)
  end
  return result, table.concat(lines, "\n")
end

local function test_fill_answers_only_what_the_map_holds()
  local out = brief.fill("a <ONE> b <TWO> c <lower>", {ONE = "1"})
  assert(out == "a 1 b <TWO> c <lower>", out)
  local left = brief.unfilled(out)
  assert(#left == 1 and left[1] == "<TWO>",
    "lowercase brackets are prose, not placeholders")
end

local function test_builder_brief_carries_the_item_and_names_the_rest()
  local s = init_state_repo("brief-builder")
  local _, leaf = root_with_leaf(s)
  give_spec(s, leaf)
  local code, out = brief_and_capture(s, "builder", leaf)
  assert(code == 0, "a specced item earns its builder brief")
  assert(out:find(leaf, 1, true) ~= nil, "the full id rides the brief")
  assert(out:find(tail.handle(leaf), 1, true) ~= nil, "so does the handle")
  assert(out:find("Do exactly this.", 1, true) ~= nil,
    "the spec sidecar rides verbatim")
  assert(out:find(leaf:sub(1, 8), 1, true) ~= nil,
    "the item branch is the id's first 8 characters")
  assert(out:find("<WORKTREE>", 1, true) ~= nil
    and out:find("<BOUNCE_CONTEXT>", 1, true) ~= nil,
    "what the board cannot answer survives the fill")
  assert(out:find("fill <", 1, true) ~= nil
    and out:find("<WORKTREE>", #out - 400, true) ~= nil,
    "the verdict line names the survivors: " .. out:sub(#out - 200))
end

local function test_research_brief_recommends_rather_than_writes()
  local s = init_state_repo("brief-research")
  local _, leaf = root_with_leaf(s)
  give_spec(s, leaf)
  local code, out = brief_and_capture(s, "research", leaf)
  assert(code == 0, "a specced item earns its research brief")
  assert(out:find(leaf, 1, true) ~= nil, "the full id rides the brief")
  assert(out:find("Do exactly this.", 1, true) ~= nil,
    "the spec sidecar rides verbatim")
  assert(out:find("ignore that instruction", 1, true) ~= nil,
    "the research brief tells the agent to recommend, not to write the board, "
    .. "even when the item's own spec says otherwise")
  assert(out:find("never open a PR", 1, true) ~= nil,
    "the rules say plainly: no PR")
  assert(out:find("Open a PR", 1, true) == nil
    and out:find("git push", 1, true) == nil,
    "a research slice has no diff, so no push/PR step")
  assert(out:find("<WORKTREE>", 1, true) ~= nil,
    "what the board cannot answer survives the fill")
end

local function test_review_brief_needs_the_handover()
  local s = init_state_repo("brief-review")
  local _, leaf = root_with_leaf(s)
  give_spec(s, leaf)
  assert(verbs.cmd_take(s, leaf, "session-a", 0, false, "") == 0)
  assert(brief.cmd_brief(s, "review", leaf) ~= 0,
    "no PR recorded, no review brief — the handover is what a review judges")
  assert(verbs.cmd_take(s, leaf, "session-a", 42, false, "") == 0)
  pin_session("deadbeef1234cafefeed")
  local code, out = brief_and_capture(s, "review", leaf)
  unpin_session()
  assert(code == 0, "the recorded PR unlocks the review brief")
  assert(out:find("--pr 42", 1, true) ~= nil, "the PR number is filled")
  assert(out:find(fs.absolute_path(s.root), 1, true) ~= nil,
    "the board worktree's absolute path is filled in")
  assert(out:find("<REVIEW_SESSION>", 1, true) == nil,
    "the placeholder is gone — the brief mints and fills the label itself")
  local label = ("review-%s-deadbeef"):format(tail.bare(leaf))
  assert(out:find("session `" .. label .. "`", 1, true) ~= nil,
    "the review is told the exact session it is claimed under: " .. out)
  assert(out:find("--session " .. label, 1, true) ~= nil,
    "and records its verdict under the same string")
  assert(out:find("claim it as " .. label, 1, true) ~= nil,
    "the verdict line repeats it, so an orchestrator claims under the "
    .. "identical string before ever spawning the agent")
end

local function test_brief_refusals_and_the_spec_less_decompose()
  local s = init_state_repo("brief-refusals")
  local root, leaf = root_with_leaf(s)
  assert(brief.cmd_brief(s, "pilot", leaf) ~= 0,
    "an unknown kind is refused, not guessed")
  assert(brief.cmd_brief(s, "builder", leaf) ~= 0,
    "a builder brief without a spec would build an interpretation")
  local code, out = brief_and_capture(s, "decompose", root)
  assert(code == 0, "a spec-less outcome still decomposes")
  assert(out:find("(the item has no spec sidecar)", 1, true) ~= nil,
    "and says so in place of the spec")
  local it = check.must(store.load(s, leaf))
  assert(it.claim == "", "brief is a read: no claim moved")
end

local function test_refine_brief_carries_the_current_spec_as_base()
  local s = init_state_repo("brief-refine")
  local _, leaf = root_with_leaf(s)
  give_spec(s, leaf)
  local code, out = brief_and_capture(s, "refine", leaf)
  assert(code == 0)
  assert(out:find("compare-and-swap base", 1, true) ~= nil
    and out:find("Do exactly this.", 1, true) ~= nil,
    "the current spec rides as the CAS base")
  assert(out:find("<GAP>", 1, true) ~= nil,
    "the gap paragraph stays the orchestrator's to fill")
end

-- A research handover earns the review brief too, as the research
-- template: the spec verbatim, no PR to fetch, the probes to re-run
-- and the captures to check, and a verdict command with no --pr/--head.
local function test_review_brief_of_a_research_handover()
  local s = init_state_repo("brief-research-review")
  local _, leaf = root_with_leaf(s)
  give_spec(s, leaf)
  assert(verbs.cmd_take(s, leaf, "session-a", 0, false, "") == 0)
  assert(verbs.cmd_take(s, leaf, "session-a", 0, false, "", true) == 0)
  pin_session("f00dcafe9999beefdead")
  local code, out = brief_and_capture(s, "review", leaf)
  unpin_session()
  assert(code == 0, "the research handover unlocks the review brief")
  assert(out:find("RESEARCH SLICE", 1, true) ~= nil, "the research template")
  assert(out:find("Do exactly this.", 1, true) ~= nil,
    "the spec sidecar rides verbatim")
  assert(out:find("Re-run EVERY probe", 1, true) ~= nil
    and out:find("captures landed", 1, true) ~= nil,
    "the probes are re-run and the captures checked")
  assert(out:find("<PR_", 1, true) == nil
    and out:find("<HEAD_SHA>", 1, true) == nil,
    "no PR placeholder is left to fill: " .. out)
  local label = ("review-%s-f00dcafe"):format(tail.bare(leaf))
  assert(out:find(("verdict %s <accept|request-changes|reject> \\\n"
        .. "  --session %s"):format(leaf, label), 1, true) ~= nil,
    "the verdict command carries neither --pr nor --head, and the "
    .. "minted label filled in: " .. out)
  assert(out:find(fs.absolute_path(s.root), 1, true) ~= nil,
    "the board worktree's absolute path is filled in")
  assert(out:find("<REVIEW_SESSION>", 1, true) == nil,
    "the placeholder is gone — the brief mints and fills the label itself")
end

-- The minted label is `<kind>-<handle>-<orch8>` for every kind, printed
-- on the brief's own verdict line even for the kinds whose template
-- carries no in-body placeholder to fill — so an orchestrator claiming
-- ANY kind of work reads the exact string to `take ID --session` under
-- straight off the brief, rather than inventing one.
local function test_every_kind_prints_its_minted_claim_label()
  local s = init_state_repo("brief-labels")
  local root, leaf = root_with_leaf(s)
  give_spec(s, leaf)
  pin_session("0123456789abcdef")
  local prefixes: {string: string} = {
    builder = "build",
    research = "research",
    refine = "refine",
  }
  for kind, prefix in pairs(prefixes) do
    local code, out = brief_and_capture(s, kind, leaf)
    assert(code == 0, kind .. " brief: " .. out)
    local label = ("%s-%s-01234567"):format(prefix, tail.bare(leaf))
    assert(out:find("claim it as " .. label, 1, true) ~= nil,
      ("%s brief names its own claim label: %s"):format(kind, out))
  end
  local code, out = brief_and_capture(s, "decompose", root)
  assert(code == 0)
  local label = ("decompose-%s-01234567"):format(tail.bare(root))
  assert(out:find("claim it as " .. label, 1, true) ~= nil,
    "decompose brief names its own claim label too: " .. out)
  unpin_session()
end

-- Two orchestrator sessions minting the label for the SAME kind and
-- item differ in exactly the field meant to differ: `<orch8>`. Same
-- kind, same handle, different session identity, different string —
-- the collision the friction log measured cannot happen once brief
-- mints it.
local function test_orch8_differs_by_session_identity_alone()
  local s = init_state_repo("brief-orch8")
  local _, leaf = root_with_leaf(s)
  give_spec(s, leaf)
  assert(verbs.cmd_take(s, leaf, "session-a", 0, false, "") == 0)
  assert(verbs.cmd_take(s, leaf, "session-a", 9, false, "") == 0)
  pin_session("11111111aaaaaaaa")
  local _, out_one = brief_and_capture(s, "review", leaf)
  pin_session("22222222bbbbbbbb")
  local _, out_two = brief_and_capture(s, "review", leaf)
  unpin_session()
  local prefix = ("review-%s-"):format(tail.bare(leaf))
  assert(out_one:find(prefix .. "11111111", 1, true) ~= nil, out_one)
  assert(out_two:find(prefix .. "22222222", 1, true) ~= nil, out_two)
  assert(out_one:find(prefix .. "22222222", 1, true) == nil,
    "the first session's brief never carries the second session's orch8")
end
