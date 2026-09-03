--- Coverage ratchet: compare a coverage run against a committed baseline.
---
--- The baseline (`.cosmic-coverage` at the project root) records covered/total
--- line counts per file, and nothing else: the whole-tree total is
--- summed from those rows rather than written, so two changes touching
--- disjoint files do not collide on a shared line. The check fails when
--- any file's percentage drops more than a small tolerance below its
--- baseline, when the total percentage declines, or when the file set
--- drifts (a new file missing from the baseline, or a stale baseline
--- entry). `cosmic --make coverage` runs the check; `cosmic --make
--- coverage --baseline` rewrites it with the HONEST measurement — every
--- row becomes exactly what this run measured, raises included, and
--- `moved` narrates every row that moved, in either direction, on
--- stderr. The one guard left is on breadth, not direction: a rewrite
--- that would lower more than half the committed floor's rows refuses
--- outright, because that is what a partial or stale run produces (a
--- narrowed test selection, `.cov` files a rebuild left behind), not a
--- real project-wide decline — see `corpus_guard`. The file is a
--- committed floor read and written through `_tool.floor` (the same
--- module `_build/casts.tl` and `_build/public_surface.tl` share), one
--- `["path"] = {["covered"] = C, ["total"] = T},` row per line (the
--- same shape and sort the other two floors use), and `merge=union` in
--- `.gitattributes` means two branches editing the same region produce
--- both rows instead of a conflict; `parse` resolves a repeated path to
--- its lower percentage via the `on_duplicate` resolver `floor.parse`
--- forwards.
---
--- A library module: `require`d for its API (`gate`, `text_for`,
--- `moved`, ...) by the `coverage` verb. There is no standalone CLI here.
local floor = require("_tool.floor")
local fs = require("cosmic.fs")
local rep = require("_tool.coverage.report")
local shape = require("cosmic.shape")

local type FileReport = rep.FileReport

--- One baseline row.
local record Entry
  covered: integer
  total: integer
end

--- Same shape as Entry, for `shape.into` below.
local ENTRY_SPEC < const > = shape.record({
    covered = shape.integer, total = shape.integer,
  })

--- Total-percentage decline tolerated before the check fails, in
--- percentage points; absorbs run-to-run flap in timing-dependent
--- branches without letting a real regression through.
local total_tolerance_pp < const > = 0.2

--- Per-file tolerated decline in percentage points: at least 1.0, and
--- never stricter than two source lines, so tiny files do not fail the
--- ratchet over a single flapping line.
--- @param total integer The file's line universe size
--- @return number Allowed decline in percentage points
local function file_tolerance_pp(total: integer): number
  if total <= 0 then
    return 1.0
  end
  return math.max(1.0, 200.0 / total)
end

local function pct(covered: integer, total: integer): number
  if total <= 0 then
    return 100.0
  end
  return 100.0 * covered / total
end

--- Render reports as baseline text: one "path covered total" row per
--- file, sorted, diff-friendly.
---
--- No whole-tree total row is written. Every regeneration would rewrite
--- it, so it is the one line any two concurrent changes both touch even
--- when their per-file rows are disjoint. `compare` sums the rows
--- instead: the same number, with nothing left to collide on.
---
--- The fresh measurement IS the row. `render` does not read a previous
--- floor and does not clamp — a row this run measures higher than the
--- committed floor raises, and a row it measures lower lowers, exactly
--- like any other edit to a committed file. Saying which rows moved is
--- `moved`'s job, not this one's, and refusing a rewrite that moves too
--- many of them at once is `corpus_guard`'s, called from `text_for`
--- before this function's output ever reaches disk.
--- @param reports {FileReport} Sorted results from report.compute
--- @return string | nil The rendered baseline
--- @return string? Error message when a row falls outside the floor format's domain
local function render(reports: {FileReport}): string | nil, string
  local value: {string: Entry} = {}
  for _, r in ipairs(reports) do
    value[r.display] = {covered = r.covered, total = r.total}
  end
  return floor.format(value)
end

--- A parsed baseline: the per-file rows, and how many repeated paths
--- were resolved, in one record so the error keeps slot 2 — a fallible
--- return has exactly two slots, the value and the error.
local record Baseline
  --- Entries by path.
  rows: {string: Entry}
  --- How many rows named a path an earlier row already claimed. Zero
  --- for a freshly rendered baseline; positive for one a `union` merge
  --- has doubled rows in.
  duplicates: integer
end

--- Which of two rows for the same path is the safer floor: the lower
--- percentage. A merge must never silently RAISE a floor, or CI fails
--- on a decline neither side introduced. Ties break on the smaller line
--- universe and then the smaller covered count, so the answer does not
--- depend on the order the rows appear in.
--- @param a Entry One row for the path
--- @param b Entry The other row for the path
--- @return Entry
local function safer_floor(a: Entry, b: Entry): Entry
  local pa, pb = pct(a.covered, a.total), pct(b.covered, b.total)
  if pa ~= pb then
    return pa < pb and a or b
  end
  if a.total ~= b.total then
    return a.total < b.total and a or b
  end
  return a.covered <= b.covered and a or b
end

--- Validate and narrow one parsed row into an Entry.
--- @param path string The row's key, for the error message
--- @param v any The value `floor.parse` stored for that key
--- @return Entry | nil The row, when it has the right shape
--- @return string? Error message when it does not
local function to_entry(path: string, v: any): Entry | nil, string
  local entry, err: Entry | nil, string = shape.into(v, ENTRY_SPEC)
  if not entry then
    return nil, "coverage baseline: " .. path .. ": " .. err
  end
  return entry
end

--- Parse baseline text into per-file entries.
---
--- A path may appear more than once, and that is valid input rather
--- than malformed: `.cosmic-coverage` merges with git's `union`
--- strategy, so a region two branches both edited arrives carrying both
--- versions of every row in it. The `on_duplicate` resolver `floor.parse`
--- forwards calls back here for each repeat, resolving to the lower
--- percentage, and `Baseline.duplicates` counts them so a caller can say
--- the file wants a clean rewrite.
--- @param text string Baseline file content
--- @return Baseline | nil The rows and duplicate count, or nil on malformed input
--- @return string? Error message on malformed input
local function parse(text: string): Baseline | nil, string
  local duplicates = 0
  local function on_duplicate(key: string, first: any, second: any): any
    duplicates = duplicates + 1
    local a, _aerr = to_entry(key, first)
    local b, _berr = to_entry(key, second)
    if a and b then
      return safer_floor(a, b)
    end
    return first
  end
  local data, err = floor.parse(text,
    {noun = "coverage baseline", on_duplicate = on_duplicate})
  if not data then
    return nil, err
  end
  local rows: {string: Entry} = {}
  for path, v in pairs(data) do
    local entry, eerr = to_entry(path, v)
    if not entry then
      return nil, eerr
    end
    rows[path] = entry
  end
  return {rows = rows, duplicates = duplicates}
end

--- Compare current results against a parsed baseline.
---
--- The whole-tree total is summed from `entries` rather than read from
--- a row: the baseline records per-file rows only, and the sum of them
--- is the same number without the line every regeneration rewrites.
--- @param reports {FileReport} Sorted results from report.compute
--- @param entries {string: Entry} Baseline rows by path
--- @return {string} Violations (empty when the ratchet holds)
local function compare(reports: {FileReport}, entries: {string: Entry}): {string}
  local problems: {string} = {}
  local seen: {string: boolean} = {}
  local covered_sum = 0
  local total_sum = 0
  local base_covered_sum = 0
  local base_total_sum = 0
  for _, r in ipairs(reports) do
    seen[r.display] = true
    covered_sum = covered_sum + r.covered
    total_sum = total_sum + r.total
    local base = entries[r.display]
    if not base then
      problems[#problems + 1] = string.format(
        "%s: not in baseline (new file? run 'cosmic --make coverage --baseline' and commit)",
        r.display)
    else
      local have = pct(r.covered, r.total)
      local want = pct(base.covered, base.total)
      local slack = file_tolerance_pp(r.total)
      if have < want - slack then
        problems[#problems + 1] = string.format(
          "%s: coverage declined %.1f%% -> %.1f%% (%d/%d, baseline %d/%d)",
          r.display, want, have, r.covered, r.total, base.covered, base.total)
      end
    end
  end
  for path, base in pairs(entries) do
    base_covered_sum = base_covered_sum + base.covered
    base_total_sum = base_total_sum + base.total
    if not seen[path] then
      problems[#problems + 1] = string.format(
        "%s: stale baseline entry (file removed? run 'cosmic --make coverage --baseline' and commit)",
        path)
    end
  end
  local have = pct(covered_sum, total_sum)
  local want = pct(base_covered_sum, base_total_sum)
  if have < want - total_tolerance_pp then
    problems[#problems + 1] = string.format(
      "total: coverage declined %.1f%% -> %.1f%% (%d/%d, baseline %d/%d)",
      want, have, covered_sum, total_sum, base_covered_sum, base_total_sum)
  end
  table.sort(problems)
  return problems
end

--- Run the ratchet check against a baseline file.
---
--- A baseline carrying repeated paths — what a `union` merge of two
--- branches produces — is checked against the resolved rows and the
--- repetition is named on stderr, so a merged-but-untidied file is
--- visible rather than silent. `--baseline` rewrites it clean.
--- @param baseline_path string Path to the committed baseline
--- @param paths {string} Report inputs (see report.compute)
--- @return integer Exit code: 0 when the ratchet holds, 1 otherwise
local function check(baseline_path: string, paths: {string}): integer
  local text, rerr = fs.read(baseline_path)
  if not text then
    io.stderr:write("coverage ratchet: " .. (rerr or "cannot read baseline") .. "\n")
    return 1
  end
  local reports, cerr = rep.compute(paths)
  if not reports then
    io.stderr:write((cerr or "coverage: no data") .. "\n")
    return 1
  end
  local parsed, perr = parse(text)
  if not parsed then
    io.stderr:write("coverage ratchet: " .. (perr or "malformed baseline") .. "\n")
    return 1
  end
  if parsed.duplicates > 0 then
    io.stderr:write(string.format(
        "coverage ratchet: %s carries %d duplicate row(s), resolved to the lower coverage; run 'cosmic --make coverage --baseline' to rewrite it clean\n",
        baseline_path, parsed.duplicates))
  end
  local problems = compare(reports, parsed.rows)
  if #problems > 0 then
    local names: {string} = {}
    for _, p in ipairs(problems) do
      io.stderr:write("coverage ratchet: " .. p .. "\n")
      names[#names + 1] = (p:match("^([^:]+):")) or p
    end
    io.stderr:write(string.format(
        "coverage ratchet: %d problem(s); if the decline is intended, run 'cosmic --make coverage --baseline' and commit the result\n",
        #problems))
    -- And once more in ONE line, naming every file, LAST.
    --
    -- The per-file lines above are the useful form and the one nobody
    -- can read: a failing gate ends with 166 test results, a stage
    -- verdict, and whatever the CI runner prints after that, so the
    -- lines saying WHICH rows moved are hundreds back and fall out of
    -- any truncated view. Three CI cycles here ended with a verdict and
    -- no visible cause, each costing a full run to re-ask.
    --
    -- Same principle the gate verdict already follows: the record that
    -- has to survive truncation goes last and fits on one line.
    io.stderr:write("coverage ratchet: declined: " ..
      table.concat(names, " ") .. "\n")
    return 1
  end
  io.write("coverage ratchet ok\n")
  return 0
end

--- Gate mode for the coverage-summary recipe (shell-free item 1):
--- skip under a test filter (partial data would read as a huge decline)
--- or when no baseline is committed; otherwise run the ratchet check.
--- @param baseline_path string Path to the committed baseline
--- @param only string The active only= filter ("" when unset)
--- @param paths {string} Report inputs (see report.compute)
--- @return integer Exit code: 0 when skipped or the ratchet holds
local function gate(baseline_path: string, only: string, paths: {string}): integer
  if only ~= "" then
    io.write("coverage ratchet skipped (only=" .. only .. ")\n")
    return 0
  end
  if not fs.is_file(baseline_path) then
    io.write("coverage ratchet skipped: no " .. baseline_path ..
      "; run 'cosmic --make coverage --baseline' to start it\n")
    return 0
  end
  return check(baseline_path, paths)
end

--- One row a rewrite moved, in either direction.
local record Move
  path: string
  raised: boolean -- true when `after` covers more than `before`
  message: string -- the rendered "path before% -> after% (c/t -> c/t)" line
end

--- Which rows a rewrite MOVED, and by how much — in either direction.
--- `render` writes the fresh measurement verbatim (see above), so a
--- rewrite can raise a row that was wrongly low, lower one a partial
--- run under-measured, or leave a row untouched. The direction rides
--- alongside each message: `write_baseline` (`_make/policy.tl`) must
--- not print a raise as though it were a drop. `corpus_guard` needs
--- drops only, not this — see `dropped_count`.
--- @param before string The existing baseline text
--- @param after string The text about to replace it
--- @return {Move} One entry per row that moved, in path order
local function moved(before: string, after: string): {Move}
  local old_parsed = parse(before)
  local new_parsed = parse(after)
  if not old_parsed or not new_parsed then
    return {}
  end
  local olds = old_parsed.rows
  local news = new_parsed.rows
  local paths: {string} = {}
  for path in pairs(olds) do
    paths[#paths + 1] = path
  end
  table.sort(paths)
  local out: {Move} = {}
  local function note(path: string, was: Entry, now: Entry)
    local before_pct = pct(was.covered, was.total)
    local after_pct = pct(now.covered, now.total)
    if after_pct ~= before_pct then
      out[#out + 1] = {
        path = path,
        raised = after_pct > before_pct,
        message = string.format("%s %.1f%% -> %.1f%% (%d/%d -> %d/%d)",
          path, before_pct, after_pct, was.covered, was.total,
          now.covered, now.total),
      }
    end
  end
  for _, path in ipairs(paths) do
    if news[path] then
      note(path, olds[path], news[path])
    end
  end
  return out
end

--- How many of `before`'s rows would strictly LOWER in `after` — drops
--- only, never raises. Kept separate from `moved` above: `moved` finds
--- every row that moved in EITHER direction, so its count is not what
--- `corpus_guard` means by "dropped" — a raised row is not a drop no
--- matter how many others moved alongside it.
--- @param before string The existing baseline text
--- @param after string The text about to replace it
--- @return integer How many rows strictly lowered
local function dropped_count(before: string, after: string): integer
  local old_parsed = parse(before)
  local new_parsed = parse(after)
  if not old_parsed or not new_parsed then
    return 0
  end
  local olds = old_parsed.rows
  local news = new_parsed.rows
  local count = 0
  for path, was in pairs(olds) do
    local now = news[path]
    if now then
      local before_pct = pct(was.covered, was.total)
      local after_pct = pct(now.covered, now.total)
      if after_pct < before_pct then
        count = count + 1
      end
    end
  end
  return count
end

--- Refuse a rewrite that would lower more than half the committed
--- floor's rows.
---
--- Breadth, not magnitude: nothing here judges how far any one row
--- fell, only how many of the floor's rows this rewrite would drop at
--- once. A majority-lowering rewrite is what a partial or stale run
--- produces — a narrowed test selection, `.cov` files a rebuild left
--- behind — not a real project-wide decline, so it is a measurement
--- problem to fix and rerun rather than a floor to accept. No
--- tolerance knob, no magic percentage: the count is exact and the line
--- is "more than half". A genuine, deliberate decline across most of
--- the tree is not blocked — deleting `.cosmic-coverage` and starting
--- the floor again is the explicit, diff-visible way around this
--- guard, and the refusal message says so.
--- @param before string The existing baseline text
--- @param after string The text about to replace it
--- @return boolean True when the rewrite may proceed
--- @return string Refusal message when it may not (empty otherwise)
local function corpus_guard(before: string, after: string): boolean, string
  local parsed = parse(before)
  if not parsed then
    return true, ""
  end
  local total = 0
  for _ in pairs(parsed.rows) do
    total = total + 1
  end
  if total == 0 then
    return true, ""
  end
  local dropped = dropped_count(before, after)
  if dropped * 2 <= total then
    return true, ""
  end
  return false, string.format(
    "coverage --baseline REFUSED: this run would lower %d of %d floor rows" ..
    " — that is a measurement problem, not a decision. Run 'bin/cosmic" ..
    " --make test' first so every .cov is fresh; a genuine project-wide" ..
    " decline is accepted by deleting .cosmic-coverage and starting the" ..
    " floor again.",
    dropped, total)
end

--- A fresh baseline for the given report inputs, as text.
---
--- Split from `write` below when the `coverage` verb needed the bytes
--- rather than a stream: the verb owns the file it writes (the build
--- has no redirect), while the recipe path captures stdout.
---
--- `previous`, when given, plays no part in the row values any more
--- (see `render`) — its only job here is `corpus_guard`: when more
--- than half of `previous`'s rows would lower in this rewrite,
--- `text_for` refuses and returns the refusal message instead of the
--- text, because that is what a partial or stale run looks like, not a
--- real decline.
--- @param paths {string} Report inputs (see report.compute)
--- @param previous string The baseline being replaced, for the corpus guard
--- @return string|nil The baseline text, or nil on failure or refusal
--- @return string The error or refusal message
local function text_for(paths: {string},
    previous?: string): string | nil, string
  local reports, cerr = rep.compute(paths)
  if not reports then
    return nil, cerr or "coverage: no data"
  end
  local text, rerr = render(reports)
  if not text then
    return nil, rerr
  end
  if previous then
    local ok, refusal = corpus_guard(previous, text)
    if not ok then
      return nil, refusal
    end
  end
  return text
end

local record BaselineModule
  type Entry = Entry
  type Baseline = Baseline
  type Move = Move
  render: function(reports: {FileReport}): string | nil, string
  parse: function(text: string): Baseline | nil, string
  compare: function(reports: {FileReport}, entries: {string: Entry}): {string}
  check: function(baseline_path: string, paths: {string}): integer
  gate: function(baseline_path: string, only: string, paths: {string}): integer
  text_for: function(paths: {string}, previous?: string): string | nil, string
  moved: function(before: string, after: string): {Move}
  corpus_guard: function(before: string, after: string): boolean, string
end

local M: BaselineModule = {
  render = render,
  parse = parse,
  compare = compare,
  check = check,
  gate = gate,
  text_for = text_for,
  moved = moved,
  corpus_guard = corpus_guard,
}

return M
