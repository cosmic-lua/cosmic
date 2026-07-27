#!/usr/bin/env cosmic
--- Coverage ratchet: compare a coverage run against a committed baseline.
---
--- The baseline (`.coverage` at the project root) records covered/total
--- line counts per file plus a total row. The check fails when any
--- file's percentage drops more than a small tolerance below its
--- baseline, when the total percentage declines, or when the file set
--- drifts (a new file missing from the baseline, or a stale baseline
--- entry) — the ratchet only moves up. `cosmic --make coverage` runs the
--- check; `cosmic --make coverage --baseline` rewrites the baseline.
---
--- Dual use: `require`d for the API, or run as a script:
---   cosmic .../baseline.lua write <report paths...>   > baseline.txt
---   cosmic .../baseline.lua check <baseline.txt> <report paths...>
local fs = require("cosmic.fs")
local rep = require("cosmic.coverage.report")

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
--- file plus a final "total" row, sorted, diff-friendly.
---
--- `floor` is the baseline being replaced, and it makes the rewrite
--- **one-way: a row is only ever lowered.** A file this run measures
--- BETTER than its floor keeps the floor's numbers, untouched.
---
--- Because the file is a floor, not a snapshot. Several rows were set
--- by hand to the number the strictest environment produces -- the
--- non-root CI builder, a host without Landlock or namespaces -- and
--- only that environment can measure them. A rewrite from whatever
--- machine is at hand raises them to what THIS machine reaches, the
--- ratchet cannot object (raising a floor is not a decline), and CI
--- fails on a row nobody edited. Ratcheting a floor UP stays a
--- deliberate edit; `--baseline` exists to record that coverage got
--- worse, and it now does only that.
--- @param reports {FileReport} Sorted results from report.compute
--- @param floor {string: Entry} The baseline being replaced, if any
--- @return string
local function render(reports: {FileReport}, floor?: {string: Entry}): string
  local out: {string} = {
    "# coverage ratchet baseline: `cosmic --make coverage --baseline` rewrites this file.",
    "# columns: path covered-lines total-lines",
  }
  local covered_sum = 0
  local total_sum = 0
  for _, r in ipairs(reports) do
    local covered, total = r.covered, r.total
    local was = floor and floor[r.display]
    if was and pct(covered, total) > pct(was.covered, was.total) then
      covered, total = was.covered, was.total
    end
    covered_sum = covered_sum + covered
    total_sum = total_sum + total
    out[#out + 1] = string.format("%s %d %d", r.display, covered, total)
  end
  out[#out + 1] = string.format("total %d %d", covered_sum, total_sum)
  return table.concat(out, "\n") .. "\n"
end

--- Parse baseline text into per-file entries plus the total row.
--- @param text string Baseline file content
--- @return {string: Entry} | nil Entries by path, or nil on a malformed line
--- @return Entry | nil The total row (may be nil when absent)
--- @return string? Error message on malformed input
local function parse(text: string): {string: Entry} | nil, Entry, string
  local entries: {string: Entry} = {}
  local total: Entry = nil
  local lineno = 0
  for line in text:gmatch("[^\n]+") do
    lineno = lineno + 1
    if not line:match("^#") then
      local path, covered, all = line:match("^(%S+) (%d+) (%d+)$")
      if not path then
        return nil, nil, string.format("baseline line %d unparsable: %s", lineno, line)
      end
      local entry: Entry = {
        covered = math.tointeger(tonumber(covered)),
        total = math.tointeger(tonumber(all)),
      }
      if path == "total" then
        total = entry
      else
        entries[path] = entry
      end
    end
  end
  return entries, total
end

--- Compare current results against a parsed baseline.
--- @param reports {FileReport} Sorted results from report.compute
--- @param entries {string: Entry} Baseline rows by path
--- @param total Entry|nil Baseline total row
--- @return {string} Violations (empty when the ratchet holds)
local function compare(reports: {FileReport}, entries: {string: Entry}, total: Entry): {string}
  local problems: {string} = {}
  local seen: {string: boolean} = {}
  local covered_sum = 0
  local total_sum = 0
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
  for path in pairs(entries) do
    if not seen[path] then
      problems[#problems + 1] = string.format(
        "%s: stale baseline entry (file removed? run 'cosmic --make coverage --baseline' and commit)",
        path)
    end
  end
  if total then
    local have = pct(covered_sum, total_sum)
    local want = pct(total.covered, total.total)
    if have < want - total_tolerance_pp then
      problems[#problems + 1] = string.format(
        "total: coverage declined %.1f%% -> %.1f%% (%d/%d, baseline %d/%d)",
        want, have, covered_sum, total_sum, total.covered, total.total)
    end
  end
  table.sort(problems)
  return problems
end

--- Run the ratchet check against a baseline file.
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
  local entries, total, perr = parse(text)
  if not entries then
    io.stderr:write("coverage ratchet: " .. (perr or "malformed baseline") .. "\n")
    return 1
  end
  -- cast: record union after guard
  local problems = compare(reports as {FileReport}, entries as {string: Entry}, total)
  if #problems > 0 then
    for _, p in ipairs(problems) do
      io.stderr:write("coverage ratchet: " .. p .. "\n")
    end
    io.stderr:write(string.format(
        "coverage ratchet: %d problem(s); if the decline is intended, run 'cosmic --make coverage --baseline' and commit the result\n",
        #problems))
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
  if not fs.isfile(baseline_path) then
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
  local floor = previous and parse(previous)
  -- cast: record union after guard
  return render(reports as {FileReport}, floor)
end

--- Which rows a rewrite would LOWER, and by how much.
---
--- A rewrite is not a refresh: `.coverage` is a floor, and several
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
  local old_rows, old_total = parse(before)
  local new_rows, new_total = parse(after)
  if not old_rows or not new_rows then
    return {}
  end
  local olds = old_rows as {string: Entry} -- cast: nil ruled out above
  local news = new_rows as {string: Entry} -- cast: nil ruled out above
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
  if old_total and new_total then
    note("total", old_total, new_total)
  end
  return out
end

local record BaselineModule
  type Entry = Entry
  render: function(reports: {FileReport}, floor?: {string: Entry}): string
  parse: function(text: string): {string: Entry} | nil, Entry, string
  compare: function(reports: {FileReport}, entries: {string: Entry}, total: Entry): {string}
  gate: function(baseline_path: string, only: string, paths: {string}): integer
  text_for: function(paths: {string}, previous?: string): string | nil, string
  lowered: function(before: string, after: string): {string}
end

local M: BaselineModule = {
  render = render,
  parse = parse,
  compare = compare,
  gate = gate,
  text_for = text_for,
  lowered = lowered,
}

return M
