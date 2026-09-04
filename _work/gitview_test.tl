#!/usr/bin/env cosmic
-- The board-wide reads render without mutating: what bare `show`
-- (the status report) says about doing, todo, triage and health, and
-- what `next` names. Their output is what a session reads to decide,
-- so the words are the contract — asserted here on the pure reports
-- the `cmd_*` wrappers print. What `show ID` prints for one item is
-- `_work/gitshow_test.tl`; the one case that spans both, a repo mark
-- rendered by two reports at once, stays here.

local check = require("cosmic.check")
local item = require("_work.item")
local ksuid = require("_work.ksuid")
local fixture = require("_work.fixture")
local gh = require("_work.gh")
local show = require("_work.gitshow")
local store = require("_work.store")
local tail = require("_work.tail")
local verbs = require("_work.gitverbs")
local view = require("_work.gitview")

local counter = 0

--- A deterministic id; later calls sort later.
local function fresh_id(): string
  counter = counter + 1
  return check.must(ksuid.encode(1700000000 + counter, ("\0"):rep(16)))
end

local GOAL < const > = fresh_id()
local CONTAINER < const > = fresh_id()
local LEAF < const > = fresh_id()
local FRESH < const > = fresh_id()
local LESSER < const > = fresh_id()

--- Whether any line matches a Lua pattern.
local function has(lines: {string}, pattern: string): boolean
  for _, line in ipairs(lines) do
    if line:match(pattern) then
      return true
    end
  end
  return false
end

--- Escape a derived value's Lua-pattern metacharacters so it can be
--- spliced into a `has` pattern as literal text. The rendered
--- handle's divider is now `_` and its wrapping guillemets, and
--- neither is Lua-pattern magic — so today there is nothing here to
--- escape — but the helper stays in place as a hedge against a
--- future divider (or other spliced value) that is.
local function lit(s: string): string
  return (s:gsub("%-", "%%-"))
end

--- The standing fixture: a placed root (it outranks LESSER, which is
--- what gives everything beneath it a position), a container under it
--- with one child in flight and one fresh todo leaf.
local function board_items(): {item.Item}
  return {
    check.must(item.decode({id = GOAL, title = "a goal", beats = LESSER})),
    check.must(item.decode({id = CONTAINER, title = "a container",
          parent = GOAL})),
    check.must(item.decode({id = LEAF, title = "a leaf", parent = CONTAINER,
          claim = "session-a", pr = 42})),
    check.must(item.decode({id = FRESH, title = "a fresh leaf",
          parent = GOAL})),
    check.must(item.decode({id = LESSER, title = "a lesser outcome"})),
  }
end

--- A spec map where every open item passes the bar, so `pullable`
--- marks are about state rather than missing sections.
local function full_specs(): {string: string}
  local out: {string: string} = {}
  for _, i in ipairs(board_items()) do
    out[i.id] = fixture.READY_SPEC
  end
  return out
end

local function test_status_renders_doing_against_the_bound()
  local lines, verdict = view.status_report(board_items(), full_specs())
  assert(has(lines, "^doing  1/10$"), table.concat(lines, "\n"))
  assert(has(lines, "%[review%]"), "the substate shows")
  assert(has(lines, "@session%-a"), "so does the claim")
  assert(has(lines, "pr:42"), "and the PR")
  assert(has(lines, "^todo   1 %(1 pullable%)$"),
    "todo renders its depth and its pullable count: "
    .. table.concat(lines, "\n"))
  assert(has(lines, "^  " .. lit(tail.handle(FRESH))
      .. " a fresh leaf %[pullable%]$"),
    "the top of todo shows the wrapped handle and its marks: "
    .. table.concat(lines, "\n"))
  assert(verdict == "doing 1/10", verdict)
end

-- Untriaged roots render item by item under the triage count: with
-- `tree` gone, this is the one list of them anyone gets.
local function test_status_lists_the_triage_queue()
  local items = board_items()
  local capture = fresh_id()
  items[#items + 1] = check.must(item.decode({id = capture,
        title = "a capture"}))
  local lines = view.status_report(items, full_specs())
  assert(has(lines, "^triage 1$"), table.concat(lines, "\n"))
  assert(has(lines, "^  " .. lit(tail.handle(capture)) .. " a capture$"),
    "each untriaged root is listed with its wrapped handle, not the "
    .. "unchunked head-8 prefix: " .. table.concat(lines, "\n"))
end

local function test_status_names_graph_problems()
  local items = board_items()
  items[#items + 1] = check.must(item.decode({id = fresh_id(),
        title = "an orphan", parent = fresh_id()}))
  local lines, verdict = view.status_report(items, full_specs())
  assert(has(lines, "graph: "),
    "a broken chain is board health: " .. table.concat(lines, "\n"))
  assert(verdict:find("1 graph problem(s)", 1, true), verdict)
end

local function test_status_reports_the_bound_binding()
  local items = board_items()
  for k = 1, 10 do
    items[#items + 1] = check.must(item.decode({id = fresh_id(),
          title = "more", parent = CONTAINER,
          claim = ("wake-%d"):format(k)}))
  end
  local _, verdict = view.status_report(items, full_specs())
  assert(verdict:find("bound: doing is at 11/10", 1, true), verdict)
end

-- The lanes row renders one `lane=conclusion` pair per required lane,
-- in the stable LANES order, beside the doing table — but only when
-- there is a state to report: a fresh board that has never synced
-- has no `lanes_state.tl`, and `show` prints no row rather than one
-- of blanks.
local function test_status_renders_the_lanes_row_when_state_exists()
  local lines = view.status_report(board_items(), full_specs(), nil,
    {["release.yml"] = "success", ["fuzz.yml"] = "failure",
      ["docs.yml"] = "success"})
  assert(has(lines,
      "^lanes  release%.yml=success fuzz%.yml=failure docs%.yml=success$"),
    "the lanes row lists every required lane in stable order: "
    .. table.concat(lines, "\n"))
end

-- A lane with no recorded conclusion (an empty string, the shape a
-- partial or not-yet-observed lane takes) is left out of the row
-- rather than printed as `lane=`.
local function test_the_lanes_row_omits_an_unrecorded_lane()
  local lines = view.status_report(board_items(), full_specs(), nil,
    {["release.yml"] = "success", ["fuzz.yml"] = "", ["docs.yml"] = "success"})
  assert(has(lines, "^lanes  release%.yml=success docs%.yml=success$"),
    "the blank lane is omitted, not printed as lane=: "
    .. table.concat(lines, "\n"))
end

local function test_status_omits_the_lanes_row_when_unsynced()
  local lines = view.status_report(board_items(), full_specs())
  for _, line in ipairs(lines) do
    assert(not line:match("^lanes"),
      "no lanes row prints when the board has never synced: " .. line)
  end
end

-- A flagged record `list` read past rather than aborting on gets ONE
-- board-level summary line beside `lanes`/`todo`, not a per-item mark
-- lost among many — and a clean board prints no such line at all.
local function test_status_prints_one_summary_line_for_flagged_items()
  local items = board_items()
  local bad = check.must(item.decode({id = fresh_id(),
        title = "broken\ntitle", parent = CONTAINER}))
  items[#items + 1] = bad
  local lines = view.status_report(items, full_specs())
  assert(has(lines, "^1 unreadable/flagged: " .. lit(bad.id:sub(1, 8))
      .. " \u{2014} title must be one line"),
    "one summary line names the flagged record: "
    .. table.concat(lines, "\n"))

  local clean_lines = view.status_report(board_items(), full_specs())
  for _, line in ipairs(clean_lines) do
    assert(not line:match("unreadable/flagged"),
      "no flagged records, no summary line: " .. line)
  end
end

local function test_next_names_one_action_and_its_rule()
  local report = view.next_report(board_items(), full_specs())
  assert(report:find("review", 1, true)
    and report:find(tail.handle(LEAF), 1, true),
    "a PR awaiting a verdict is judged before anything is pulled: "
    .. report)
  assert(report:find("—", 1, true),
    "and the rule that chose it is stated: " .. report)
  -- The `or:` alternate line's full rendered format, pinned directly:
  -- a prior review found no test covered it, and reverting that
  -- line's format left every render test green.
  assert(report:find("or: pull " .. tail.handle(FRESH) .. " a fresh leaf",
      1, true),
    "the alternate names its kind, wrapped handle, and title: " .. report)
end

-- A drop's subject carries its why; `next`'s offer surfaces it so the
-- next session sees which side stopped before claiming. A
-- reviewer-release drop is not a bounce, and neither is a take.
local function test_bounce_note_reads_a_drops_why()
  local note = view.bounce_note(
    "drop 3Ib4mK2b: wave agent died with no PR")
  assert(note == " (last drop: wave agent died with no PR)",
    note)
end

local function test_bounce_note_is_silent_on_a_reviewer_release()
  assert(view.bounce_note("drop 3Ib4mK2b review: not this build's gap")
    == "", "a reviewer's release is not a bounce")
end

local function test_bounce_note_is_silent_on_a_take()
  assert(view.bounce_note("take 3Ib4mK2b by session-a") == "",
    "a take names no reason")
end

-- Cross-repo work is visible exactly where it was invisible: `show ID`
-- prints a `repo:` line, and the status report appends
-- ` [owner/name]` to the item's line. The default (empty `repo`) is
-- silent — a same-repo item reads the same as it did before this field
-- existed.
local function test_repo_is_rendered_in_show_and_status()
  local all = board_items()
  local scoped = check.must(item.decode({
        id = fresh_id(), title = "a cosmopolitan-side slice",
        parent = CONTAINER, claim = "session-b",
        repo = "whilp/cosmopolitan"}))
  all[#all + 1] = scoped

  local show_lines = show.show_report(scoped, all, "", {}, {})
  assert(has(show_lines, "^repo: whilp/cosmopolitan$"),
    "show prints a repo line: " .. table.concat(show_lines, "\n"))

  local status_lines = view.status_report(all, full_specs())
  assert(has(status_lines, "%[whilp/cosmopolitan%]"),
    "status marks the item with its repo: " .. table.concat(status_lines, "\n"))
  local leaf_line = ""
  for _, line in ipairs(status_lines) do
    if line:find("pr:42", 1, true) then
      leaf_line = line
    end
  end
  assert(leaf_line ~= "", "the LEAF's status line is there to check")
  assert(not leaf_line:find("whilp/cosmopolitan", 1, true),
    "the same-repo LEAF is unmarked: " .. leaf_line)

  local default_show = show.show_report(all[3], all, "", {}, {})
  assert(not has(default_show, "^repo:"),
    "an item with no repo prints no repo line: "
    .. table.concat(default_show, "\n"))
end

-- A research handover in flight is marked with its digest's seven hex
-- where a diff's `pr:N` goes, so the board line says what awaits the
-- verdict without a `show`.
local function test_status_marks_a_research_handover_with_its_digest()
  local all = board_items()
  local handed = check.must(item.decode({id = fresh_id(), title = "a handover",
        parent = CONTAINER, claim = "session-b", builders = "session-b",
        result = ("abcdef0123456789"):rep(4)}))
  all[#all + 1] = handed
  local lines = view.status_report(all, full_specs())
  local line = ""
  for _, l in ipairs(lines) do
    if l:find("a handover", 1, true) then
      line = l
    end
  end
  assert(line ~= "", "the handover is listed under doing: "
    .. table.concat(lines, "\n"))
  assert(line:find("[review] @session-b result:abcdef0", 1, true),
    "marked with its substate, claim and digest: " .. line)
  assert(not line:find("pr:", 1, true), "and no PR mark: " .. line)
end

--- Stand `gh.head_checks` in for a fixed state for the duration of
--- `f`, restoring the real function even when `f` fails an assertion
--- — the same swap-and-restore `gitreview_test.tl`'s `with_ci_state`
--- uses, sized to the two states this file actually exercises.
--- @param state string The state `head_checks` reports
--- @param f function(): boolean The test body; returns true when done
local function with_ci_state(state: string, f: function(): boolean)
  local real = gh.head_checks
  gh.head_checks = function(_s: store.Store, _pr: integer, _repo: string | nil):
    gh.HeadChecks | nil, string
    return {state = state, head_sha = "", runs = {}}, ""
  end
  local ok, err = pcall(f)
  gh.head_checks = real
  if not ok then
    error(err, 0)
  end
end

--- Run `view.cmd_next` and capture exactly what it prints via
--- `print()` -- the same swap-and-restore pattern `gitboard_test.tl`'s
--- `gitboard_and_capture` uses to pin a CLI's exact console output.
--- @param s store.Store The store
--- @param session string This session's name
--- @return integer cmd_next's exit code
--- @return string Every print()'d line, newline-joined
local function cmd_next_and_capture(s: store.Store, session: string):
  integer, string
  local old_print = _G.print
  local lines: {string} = {}
  _G.print = function(...: any)
    local parts: {string} = {}
    for i = 1, select("#", ...) do
      parts[i] = tostring((select(i, ...)))
    end
    lines[#lines + 1] = table.concat(parts, "\t")
  end
  local ok, result = pcall(view.cmd_next, s, session)
  _G.print = old_print
  if not ok then
    error(result, 0)
  end
  return result, table.concat(lines, "\n")
end

-- A reviewable item taken and handed over carrying a PR. The initial
-- claim is forced: the leaf's root is deliberately left unplaced (see
-- `unplaced_root_with_leaf`), and an unplaced item's own spec bar
-- normally refuses `take` — `--force` is only how this fixture skips
-- straight to "in review", not a claim about the real gate.
local function handed_over(s: store.Store, leaf: string, builder: string,
    pr: integer)
  fixture.give_spec(s, leaf)
  assert(verbs.cmd_take(s, leaf, builder, 0, true,
      "test fixture: skip the position gate") == 0)
  assert(verbs.cmd_take(s, leaf, builder, pr, false, "") == 0)
end

--- A deliberately UNPLACED root with one workable leaf under it — the
--- same shape `_work/action_ci_test.tl`'s
--- `test_a_running_head_is_not_offered` uses: it has a child (not
--- triage) and is not a placed root (nothing to decompose), so no
--- intake rung has anything to offer instead and the CI-blocked
--- review below is the only candidate `next` has to weigh.
--- @param s store.Store The store
--- @return string The workable leaf's id
local function unplaced_root_with_leaf(s: store.Store): string
  local root = fixture.file_item(s, "an outcome", "")
  return fixture.file_item(s, "a workable slice", root)
end

-- The wiring this item adds: `next` (through `gitview.cmd_next`, the
-- actual entry `gitboard next` reaches) reads live CI state for a
-- reviewable item carrying a PR and steps it out of the offer exactly
-- as `_work/action_ci_test.tl` proves `action.tl` alone can — proof
-- that a real `gitboard next` invocation now builds and passes the
-- `CiStates` map, not only that `next_action` honors one when handed
-- one directly.
local function test_live_next_skips_a_reviewable_item_with_ci_running()
  local s = fixture.init_state_repo("next-ci-running")
  local leaf = unplaced_root_with_leaf(s)
  handed_over(s, leaf, "builder-a", 9)
  with_ci_state("running", function(): boolean
      local code, printed = cmd_next_and_capture(s, "")
      assert(code == 0, printed)
      assert(printed:find("ci running", 1, true) ~= nil,
        "a running head is not offered by a live next: " .. printed)
      return true
    end)
end

-- Same wiring, the red case: already decided, but the move is the
-- builder's, not a reviewer's — and the live path renders that
-- distinctly from "running", the same as the pure layer already does.
local function test_live_next_skips_a_reviewable_item_with_ci_red()
  local s = fixture.init_state_repo("next-ci-red")
  local leaf = unplaced_root_with_leaf(s)
  handed_over(s, leaf, "builder-a", 9)
  with_ci_state("red", function(): boolean
      local code, printed = cmd_next_and_capture(s, "")
      assert(code == 0, printed)
      assert(printed:find("ci red — builder's", 1, true) ~= nil,
        "a red head reads as the builder's move on a live next: " .. printed)
      return true
    end)
end
