#!/usr/bin/env cosmic
--- Coverage ratchet: compare a coverage run against a committed baseline.
---
--- The baseline (`.coverage` at the project root) records covered/total
--- line counts per file plus a total row. The check fails when any
--- file's percentage drops more than a small tolerance below its
--- baseline, when the total percentage declines, or when the file set
--- drifts (a new file missing from the baseline, or a stale baseline
--- entry) — the ratchet only moves up. `bin/make coverage` runs the
--- check; `bin/make coverage-baseline` rewrites the baseline.
---
--- Dual use: `require`d for the API, or run as a script:
---   cosmic .../baseline.lua write <report paths...>   > baseline.txt
---   cosmic .../baseline.lua check <baseline.txt> <report paths...>
local fs = require("cosmic.fs")
local proc = require("cosmic.proc")
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
--- @param reports {FileReport} Sorted results from report.compute
--- @return string
local function render(reports: {FileReport}): string
  local out: {string} = {
    "# coverage ratchet baseline: `bin/make coverage-baseline` rewrites this file.",
    "# columns: path covered-lines total-lines",
  }
  local covered_sum = 0
  local total_sum = 0
  for _, r in ipairs(reports) do
    covered_sum = covered_sum + r.covered
    total_sum = total_sum + r.total
    out[#out + 1] = string.format("%s %d %d", r.display, r.covered, r.total)
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
        "%s: not in baseline (new file? run 'bin/make coverage-baseline' and commit)",
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
        "%s: stale baseline entry (file removed? run 'bin/make coverage-baseline' and commit)",
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
        "coverage ratchet: %d problem(s); if the decline is intended, run 'bin/make coverage-baseline' and commit the result\n",
        #problems))
    return 1
  end
  io.write("coverage ratchet ok\n")
  return 0
end

--- Gate mode for the coverage-summary recipe (shell-free, #756 item 1):
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
      "; run 'bin/make coverage-baseline' to start it\n")
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
--- @return string|nil The baseline text, or nil on failure
--- @return string The error message
local function text_for(paths: {string}): string | nil, string
  local reports, cerr = rep.compute(paths)
  if not reports then
    return nil, cerr or "coverage: no data"
  end
  return render(reports as {FileReport}) -- cast: record union after guard
end

--- Write a fresh baseline for the given report inputs to stdout.
--- @param paths {string} Report inputs (see report.compute)
--- @return integer Exit code: 0 on success
local function write(paths: {string}): integer
  local out, err = text_for(paths)
  if not out then
    io.stderr:write((err or "coverage: no data") .. "\n")
    return 1
  end
  io.write(out as string) -- cast: scalar narrowing after the guard
  return 0
end

local function main(argv: {string}): integer
  local mode = argv[1]
  if mode == "write" and argv[2] then
    local paths: {string} = {}
    for i = 2, #argv do
      paths[#paths + 1] = argv[i]
    end
    return write(paths)
  elseif mode == "check" and argv[2] and argv[3] then
    local paths: {string} = {}
    for i = 3, #argv do
      paths[#paths + 1] = argv[i]
    end
    return check(argv[2], paths)
  elseif mode == "gate" and argv[2] and argv[3] and argv[4] then
    -- --only=<str> stays one argv token even when the filter is empty,
    -- so the no-shell recipe needs no quoting
    local only = argv[3]:match("^%-%-only=(.*)$")
    if only then
      local paths: {string} = {}
      for i = 4, #argv do
        paths[#paths + 1] = argv[i]
      end
      return gate(argv[2], only, paths)
    end
  end
  io.stderr:write("usage: baseline.lua write <paths...>" ..
    " | check <baseline> <paths...>" ..
    " | gate <baseline> --only=<str> <paths...>\n")
  return 2
end

if proc.is_main() then
  os.exit(main(arg))
end

local record BaselineModule
  type Entry = Entry
  render: function(reports: {FileReport}): string
  parse: function(text: string): {string: Entry} | nil, Entry, string
  compare: function(reports: {FileReport}, entries: {string: Entry}, total: Entry): {string}
  check: function(baseline_path: string, paths: {string}): integer
  gate: function(baseline_path: string, only: string, paths: {string}): integer
  text_for: function(paths: {string}): string | nil, string
  write: function(paths: {string}): integer
end

local M: BaselineModule = {
  render = render,
  parse = parse,
  compare = compare,
  check = check,
  gate = gate,
  text_for = text_for,
  write = write,
}

return M
