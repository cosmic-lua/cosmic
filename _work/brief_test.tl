#!/usr/bin/env cosmic
-- The brief verb: board facts fill, the spec rides verbatim, what the
-- board cannot answer survives as a placeholder the verdict line
-- names, and the refusals hold — an unknown kind, a spec-less item
-- for the kinds that carry the spec, a review with no PR recorded.

local check = require("cosmic.check")
local fs = require("cosmic.fs")
local brief = require("_work.brief")
local fixture = require("_work.fixture")
local store = require("_work.store")
local tail = require("_work.tail")
local verbs = require("_work.gitverbs")

local init_state_repo = fixture.init_state_repo
local give_spec = fixture.give_spec
local root_with_leaf = fixture.root_with_leaf

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
test_fill_answers_only_what_the_map_holds()

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
test_builder_brief_carries_the_item_and_names_the_rest()

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
test_research_brief_recommends_rather_than_writes()

local function test_review_brief_needs_the_handover()
  local s = init_state_repo("brief-review")
  local _, leaf = root_with_leaf(s)
  give_spec(s, leaf)
  assert(verbs.cmd_take(s, leaf, "session-a", 0, false, "") == 0)
  assert(brief.cmd_brief(s, "review", leaf) ~= 0,
    "no PR recorded, no review brief — the handover is what a review judges")
  assert(verbs.cmd_take(s, leaf, "session-a", 42, false, "") == 0)
  local code, out = brief_and_capture(s, "review", leaf)
  assert(code == 0, "the recorded PR unlocks the review brief")
  assert(out:find("--pr 42", 1, true) ~= nil, "the PR number is filled")
  assert(out:find(fs.absolute_path(s.root), 1, true) ~= nil,
    "the board worktree's absolute path is filled in")
  assert(out:find("<REVIEW_SESSION>", 1, true) ~= nil,
    "the minted review session stays the orchestrator's to fill")
end
test_review_brief_needs_the_handover()

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
test_brief_refusals_and_the_spec_less_decompose()

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
test_refine_brief_carries_the_current_spec_as_base()
