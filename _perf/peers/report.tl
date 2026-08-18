--- Pure rendering of a peers.Report: a markdown table for the release
--- notes, a one-line summary for `tail -n1`, and the verdict grammar.
--- No I/O here -- _perf/peers/run.tl owns writing files and printing.

local harness = require("_perf.harness")
local peersmod = require("_perf.peers.peers")

local type Report = peersmod.Report
local type Row = peersmod.Row

local REGEN_CMD < const > =
"bin/cosmic --make run _perf/peers/run.tl --bin %s --out o/perf/peers.json --md o/perf/peers.md"
local RERUN_CMD < const > =
"bin/cosmic --make run _perf/peers/run.tl --bin %s --only %s --out o/perf/cell.json --md o/perf/cell.md"

--- One measured or absent table row.
--- @param r Row The row to render
--- @return string A single markdown table row
local function row_line(r: Row): string
  if r.kind ~= "measured" then
    return ("| %s | absent | - | - | - | - | - |"):format(r.label)
  end
  return ("| %s | %s | %s (%d bytes) | `%s` | %s | ±%.1f%% | %d |"):format(
    r.label, r.version, r.exe, r.exe_bytes, table.concat(r.argv, " "),
    harness.format_ns(r.wall_ns), r.spread_pct, r.iterations)
end

--- The one-line summary the release notes carry (`tail -n1` of the
--- rendered markdown).
--- @param rep Report The table
--- @return string For example "startup: cosmic-lua 1.23 ms | go absent"
local function summary_line(rep: Report): string
  local parts: {string} = {}
  for _, r in ipairs(rep.rows) do
    if r.kind == "measured" then
      parts[#parts + 1] = r.label .. " " .. harness.format_ns(r.wall_ns)
    else
      parts[#parts + 1] = r.label .. " absent"
    end
  end
  return "startup: " .. table.concat(parts, " | ")
end

--- Verdict grammar. An absent peer is a pass -- only an empty row set
--- (no peer selected) fails, and it fails empty: this table never
--- gates on speed.
--- @param rep Report The table
--- @return string "peers: OK n/n measured", "... (absent: id, id)", or
--- "peers: FAIL ()"
local function verdict(rep: Report): string
  local total = #rep.rows
  if total == 0 then
    return "peers: FAIL ()"
  end
  local measured = 0
  local absent: {string} = {}
  for _, r in ipairs(rep.rows) do
    if r.kind == "measured" then
      measured = measured + 1
    else
      absent[#absent + 1] = r.id
    end
  end
  if #absent == 0 then
    return "peers: OK " .. measured .. "/" .. total .. " measured"
  end
  return "peers: OK " .. measured .. "/" .. total .. " measured (absent: " ..
  table.concat(absent, ", ") .. ")"
end

--- Render the full table as markdown. Ends with summary_line(rep) as its
--- last line, so `tail -n1` on the file carries the release-notes line.
--- @param rep Report The table
--- @return string The rendered markdown
local function format_markdown(rep: Report): string
  local bin = rep.meta.cosmic_bin
  local lines: {string} = {
    "# cosmic peer table",
    "",
    "Task: " .. rep.task,
    "",
    "Regenerate the full table:",
    "",
    "    " .. REGEN_CMD:format(bin),
    "",
    ("Host: %s/%s, %d cpu(s), runner=%s, %d samples >= %.2fs each"):format(
      rep.meta.os, rep.meta.isa, math.tointeger(rep.meta.nproc) or 0, rep.meta.runner,
      rep.meta.samples, rep.meta.min_sample_secs),
    "",
    "| runtime | version | artifact | argv | ns/op | ±spread | iters |",
    "|---|---|---|---|---|---|---|",
  }
  for _, r in ipairs(rep.rows) do
    lines[#lines + 1] = row_line(r)
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] =
  "Every row runs the identical task: a script FILE that prints exactly " ..
  '"perf-hello", spawned through the same child.run capture path, timed ' ..
  "by the same _perf.harness.run_scenario, and checked by the same " ..
  "exact-stdout rule. Go's compile (`go build -o hello hello.go`) runs " ..
  "in setup, outside the timed region -- cosmic's binary is prebuilt " ..
  "too, so compiling is never part of any row's timed task."

  local any_absent = false
  for _, r in ipairs(rep.rows) do
    if r.kind ~= "measured" then
      any_absent = true
    end
  end
  if any_absent then
    lines[#lines + 1] = ""
    for _, r in ipairs(rep.rows) do
      if r.kind ~= "measured" then
        lines[#lines + 1] = "- " .. r.label .. " absent: " .. tostring(r.reason)
      end
    end
  end

  lines[#lines + 1] = ""
  for _, r in ipairs(rep.rows) do
    lines[#lines + 1] = ("re-run %s: `%s`"):format(r.id, RERUN_CMD:format(bin, r.id))
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = summary_line(rep)
  return table.concat(lines, "\n")
end

local record report
  format_markdown: function(rep: Report): string
  summary_line: function(rep: Report): string
  verdict: function(rep: Report): string
end

local M: report = {
  format_markdown = format_markdown,
  summary_line = summary_line,
  verdict = verdict,
}

return M
