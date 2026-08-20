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
--- coverage --baseline` rewrites it, lowering only the rows this run
--- would have failed on and leaving every other row exactly as
--- committed — a floor moves down by a deliberate rewrite and up only
--- by hand. The file is a `cosmic.literal` table, one `["path"] =
--- {["covered"] = C, ["total"] = T},` row per line (the same shape and
--- sort the other two committed floors use), and `merge=union` in
--- `.gitattributes` means two branches editing the same region produce
--- both rows instead of a conflict; `parse` resolves a repeated path to
--- its lower percentage via `literal.parse`'s `on_duplicate`.
---
--- A library module: `require`d for its API (`gate`, `text_for`,
--- `lowered`, ...) by the `coverage` verb. There is no standalone CLI
--- here.
local fs = require("cosmic.fs")
local literal = require("cosmic.literal")
local rep = require("_tool.coverage.report")

local type FileReport = rep.FileReport

--- One baseline row.
local record Entry
  covered: integer
  total: integer
end

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
--- `floor` is the baseline being replaced, and a row is rewritten ONLY
--- when this run would fail the ratchet against it -- the same
--- `pct < floor_pct - file_tolerance_pp` test `compare` raises a problem
--- on. Every other row keeps the floor's numbers byte for byte: an
--- improvement, a flat percentage over a grown line universe, and a
--- decline sitting inside the per-file slack all leave the row alone.
---
--- Two consequences of that rule:
---
--- A decline inside the tolerance does not lower the floor, so a run of
--- them cannot accumulate into a slow slide downward. The floor holds
--- where it was set until a check actually fails against it.
---
--- A file whose line universe grew at a flat percentage keeps its old
--- absolute counts, so a row's numbers can lag the file's current size.
--- Improved rows already behave that way, which makes the whole-tree
--- sum `compare` derives an approximation of the same kind.
---
--- The narrowness earns two things. The file is a floor, not a
--- snapshot: several rows were set by hand to the number the strictest
--- environment produces -- the non-root CI builder, a host without
--- Landlock or namespaces -- and only that environment can measure
--- them. A rewrite from whatever machine is at hand would raise them to
--- what THIS machine reaches, the ratchet cannot object (raising a
--- floor is not a decline), and CI fails on a row nobody edited. And a
--- rewrite that touches only the failing rows leaves the rest of the
--- file still, so two changes landing near each other have almost no
--- lines in common to conflict on.
--- @param reports {FileReport} Sorted results from report.compute
--- @param floor {string: Entry} The baseline being replaced, if any
--- @return string | nil The rendered baseline
--- @return string? Error message when a row falls outside `literal.format`'s domain
local function render(reports: {FileReport}, floor?: {string: Entry}): string | nil, string
  local value: {string: Entry} = {}
  for _, r in ipairs(reports) do
    local covered, total = r.covered, r.total
    local was = floor and floor[r.display]
    if was then
      local slack = file_tolerance_pp(total)
      local fails = pct(covered, total) < pct(was.covered, was.total) - slack
      if not fails then
        covered, total = was.covered, was.total
      end
    end
    value[r.display] = {covered = covered, total = total}
  end
  return literal.format(value)
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
--- @param v any The value `literal.parse` stored for that key
--- @return Entry | nil The row, when it has the right shape
--- @return string? Error message when it does not
local function to_entry(path: string, v: any): Entry | nil, string
  if type(v) ~= "table" then
    return nil, "coverage baseline: " .. path .. ": row must be a table"
  end
  local t = v as {string: any} -- cast: runtime-checked table above
  local covered, total = t.covered, t.total
  if math.type(covered) ~= "integer" or math.type(total) ~= "integer" then
    return nil, "coverage baseline: " .. path ..
    ": row must be {covered = <int>, total = <int>}"
  end
  return {covered = covered as integer, total = total as integer} -- cast: math.type checked above
end

--- Parse baseline text into per-file entries.
---
--- A path may appear more than once, and that is valid input rather
--- than malformed: `.cosmic-coverage` merges with git's `union`
--- strategy, so a region two branches both edited arrives carrying both
--- versions of every row in it. `literal.parse`'s `on_duplicate` calls
--- back here for each repeat, resolving to the lower percentage, and
--- `Baseline.duplicates` counts them so a caller can say the file wants
--- a clean rewrite.
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
  local data, err = literal.parse(text,
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

--- A fresh baseline for the given report inputs, as text.
---
--- Split from `write` below when the `coverage` verb needed the bytes
--- rather than a stream: the verb owns the file it writes (the build
--- has no redirect), while the recipe path captures stdout.
--- @param paths {string} Report inputs (see report.compute)
--- @param previous string The baseline being replaced, for the floor rule
--- @return string|nil The baseline text, or nil on failure
--- @return string The error message
local function text_for(paths: {string},
    previous?: string): string | nil, string
  local reports, cerr = rep.compute(paths)
  if not reports then
    return nil, cerr or "coverage: no data"
  end
  local floor: {string: Entry} = nil
  if previous then
    local prev = parse(previous)
    if prev then
      floor = prev.rows
    end
  end
  return render(reports, floor)
end

--- Which rows a rewrite would LOWER, and by how much.
---
--- A rewrite is not a refresh: `.cosmic-coverage` is a floor, and several
--- files' floors were measured on a machine that is not this one. The
--- ratchet is silent about it -- lowering a row is exactly what
--- `--baseline` is for -- so the only thing standing between an
--- environment-sensitive floor and being quietly re-baselined onto the
--- nearest laptop is that somebody reads the diff. This names the rows
--- so the reading happens whether or not the diff is opened.
--- @param before string The existing baseline text
--- @param after string The text about to replace it
--- @return {string} One message per lowered row, in path order
local function lowered(before: string, after: string): {string}
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
  local out: {string} = {}
  local function note(path: string, was: Entry, now: Entry)
    local before_pct = pct(was.covered, was.total)
    local after_pct = pct(now.covered, now.total)
    if after_pct < before_pct then
      out[#out + 1] = string.format("%s %.1f%% -> %.1f%% (%d/%d -> %d/%d)",
        path, before_pct, after_pct, was.covered, was.total,
        now.covered, now.total)
    end
  end
  for _, path in ipairs(paths) do
    if news[path] then
      note(path, olds[path], news[path])
    end
  end
  return out
end

local record BaselineModule
  type Entry = Entry
  type Baseline = Baseline
  render: function(reports: {FileReport}, floor?: {string: Entry}): string | nil, string
  parse: function(text: string): Baseline | nil, string
  compare: function(reports: {FileReport}, entries: {string: Entry}): {string}
  check: function(baseline_path: string, paths: {string}): integer
  gate: function(baseline_path: string, only: string, paths: {string}): integer
  text_for: function(paths: {string}, previous?: string): string | nil, string
  lowered: function(before: string, after: string): {string}
end

local M: BaselineModule = {
  render = render,
  parse = parse,
  compare = compare,
  check = check,
  gate = gate,
  text_for = text_for,
  lowered = lowered,
}

return M
