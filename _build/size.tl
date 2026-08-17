#!/usr/bin/env cosmic
--- The tree-size report: G9's per-release half (docs/goals.md) — "the
--- least tree that keeps its promises". A release measures its own
--- size the same way it measures its own speed (see _perf/run.tl):
--- `.tl` file and line counts per tracked tree, AGENTS.md's length, the
--- public module count, and the shipped binary's size.
---
--- This is a report, never a gate: goals.md G9 says growth is
--- surfaced, not refused, so `compare` below has no threshold and no
--- failing exit code — pruning is a decision a human makes from the
--- numbers, not something this script enforces.
---
---   cosmic -- o/_build/size.lua --out FILE [--binary PATH]
---   cosmic -- o/_build/size.lua compare PREV.json CUR.json
---
--- `--out` writes the report as JSON via cosmic.json; `--binary`, when
--- given, is stat'd for `binary_bytes` (absent otherwise — a size
--- report from the tree alone has nothing to stat). `compare` prints
--- one line summarizing the totals and their deltas against a prior
--- report; it exits 0 whether the tree grew, shrank, or stayed put.

local flags = require("cosmic.flags")
local json = require("cosmic.json")
local fs = require("cosmic.fs")
local proc = require("cosmic.proc")
local public_surface = require("_build.public_surface")
local casts = require("_build.casts")

--- One tracked tree's `.tl` footprint.
local record TreeStats
  tl_files: integer
  lines: integer
end

--- A size report, as written to JSON and read back by `compare`.
local record Report
  --- Per-tree stats, keyed by tree name ("cosmic", "_cli", "cmd", ...).
  trees: {string: TreeStats}
  --- AGENTS.md's line count.
  agents_md_lines: integer
  --- The public module count (cosmic.* names; see _build.public_surface).
  public_modules: integer
  --- The stat'd binary's size in bytes; nil when no --binary was given.
  binary_bytes: integer | nil
end

--- The trees this report counts: `_build.casts`'s TREES, the one home
--- for the list of committed-Teal trees (`3p/` is vendored, not one).
local TREES < const >: {string} = casts.TREES

--- Count of logical lines in `content`: a trailing newline does not
--- count as an extra blank line, and a file with no trailing newline
--- still counts its last line. Same technique as `_cli/lint.tl`'s file-
--- length check, so the two agree on what "a line" is.
--- @param content string The file's bytes
--- @return integer The line count
local function count_lines(content: string): integer
  if content == "" then
    return 0
  end
  local lines: {string} = {}
  for line in (content .. "\n"):gmatch("([^\n]*)\n") do
    lines[#lines + 1] = line
  end
  local n = #lines
  if n > 0 and lines[n] == "" then
    n = n - 1
  end
  return n
end

--- One tree's `.tl` file and line counts, skipping `testdata/` — a
--- fixture's lines are not the tree's, same rule as `_build.casts`.
--- A tree missing under `root` counts as empty rather than an error:
--- the report is a measurement of what is there.
--- @param root string The project root
--- @param tree string The tree name, e.g. "cosmic"
--- @return TreeStats The file and line counts
local function tree_stats(root: string, tree: string): TreeStats
  local out: TreeStats = {tl_files = 0, lines = 0}
  local dir = fs.join(root, tree)
  if not fs.is_dir(dir) then
    return out
  end
  local found = fs.find(dir, {glob = "*.tl"})
  if found then
    for _, path in ipairs(found) do
      local rest = path:sub(#dir + 2)
      if not ("/" .. rest):find("/testdata/", 1, true) then
        local text = fs.read(path)
        if text then
          out.tl_files = out.tl_files + 1
          out.lines = out.lines + count_lines(text)
        end
      end
    end
  end
  return out
end

--- Build a size report for the tree at `root`.
--- @param root string The project root to measure
--- @param binary_path string|nil A built binary to stat for binary_bytes
--- @return Report The report
local function report(root: string, binary_path?: string): Report
  local trees: {string: TreeStats} = {}
  for _, tree in ipairs(TREES) do
    trees[tree] = tree_stats(root, tree)
  end
  local agents_lines = 0
  local agents_text = fs.read(fs.join(root, "AGENTS.md"))
  if agents_text then
    agents_lines = count_lines(agents_text)
  end
  local rep: Report = {
    trees = trees,
    agents_md_lines = agents_lines,
    public_modules = #public_surface.modules(root),
  }
  if binary_path then
    local st = fs.stat(binary_path)
    if st then
      rep.binary_bytes = st:size()
    end
  end
  return rep
end

--- Sum a report's per-tree counts into totals.
--- @param rep Report The report
--- @return integer Total lines across every tracked tree
--- @return integer Total .tl files across every tracked tree
local function totals(rep: Report): integer, integer
  local lines, files = 0, 0
  for _, tree in ipairs(TREES) do
    local t = rep.trees and rep.trees[tree]
    if t then
      lines = lines + (t.lines or 0)
      files = files + (t.tl_files or 0)
    end
  end
  return lines, files
end

--- The one-line summary `compare` prints: totals from `cur`, with each
--- delta against `prev` signed (`%+d`, so a zero delta reads `+0` and
--- the direction of a nonzero one is never ambiguous).
--- @param prev Report The prior report
--- @param cur Report The current report
--- @return string The summary line
local function format_compare(prev: Report, cur: Report): string
  local plines, pfiles = totals(prev)
  local clines, cfiles = totals(cur)
  local pbin = prev.binary_bytes or 0
  local cbin = cur.binary_bytes or 0
  local pmod = prev.public_modules or 0
  local cmod = cur.public_modules or 0
  return string.format(
    "size: lines %d (%+d), files %d (%+d), binary %d (%+d), public modules %d (%+d)",
    clines, clines - plines,
    cfiles, cfiles - pfiles,
    cbin, cbin - pbin,
    cmod, cmod - pmod)
end

--- Load a report JSON file written by `--out`.
--- @param path string Path to the report file
--- @return Report|nil The decoded report
--- @return string Error message on failure
local function load_report(path: string): Report | nil, string
  local data, rerr = fs.read(path)
  if data == nil then
    return nil, path .. ": " .. tostring(rerr)
  end
  local decoded, jerr = json.decode(data)
  if decoded == nil then
    return nil, path .. ": " .. tostring(jerr)
  end
  return decoded as Report -- cast: from any
end

local USAGE = [[
usage: size.lua --out FILE [--binary PATH]
       size.lua compare PREV.json CUR.json
]]

local SPEC: flags.Spec = {
  name = "size.lua",
  flags = {
    {long = "out", arg = "FILE", required = true, help = "write the size report here"},
    {long = "binary", arg = "PATH", help = "a built binary to stat for binary_bytes"},
  },
}

--- Write mode: measure the tree at "." and write the report as JSON.
--- @param argv {string} Arguments after the mode is decided (no "compare")
--- @return integer Exit code: 0 on success, 1 on a write/encode failure
local function run_report(argv: {string}): integer
  local parsed, perr = flags.parse(SPEC, argv)
  if not parsed then
    io.stderr:write("argument parse failed: " .. tostring(perr) .. "\n" .. USAGE)
    return 1
  end
  if parsed.help then
    print(USAGE)
    return 0
  end
  local rep = report(".", parsed.values["binary"])
  local encoded, eerr = json.encode(rep)
  if encoded == nil then
    io.stderr:write("encode report: " .. tostring(eerr) .. "\n")
    return 1
  end
  local out = parsed.values["out"]
  local outdir = fs.dirname(out)
  if outdir ~= "" and not fs.is_dir(outdir) then
    local mok, mkerr = fs.make_dirs(outdir)
    if not mok then
      io.stderr:write("write " .. out .. ": " .. tostring(mkerr) .. "\n")
      return 1
    end
  end
  local wok, werr = fs.write(out, encoded)
  if not wok then
    io.stderr:write("write " .. out .. ": " .. tostring(werr) .. "\n")
    return 1
  end
  print("wrote " .. out)
  return 0
end

--- Compare mode: load two report files and print the one-line summary.
--- Never gates (see the module doc comment): once both files load, this
--- always returns 0 regardless of what the deltas say. A file that
--- fails to load is a script-usage error, not a size delta, so that
--- case alone returns 1.
--- @param prev_path string The prior report's path
--- @param cur_path string The current report's path
--- @return integer Exit code: 0 once both reports load, 1 on a load failure
local function run_compare(prev_path: string, cur_path: string): integer
  local prev, perr = load_report(prev_path)
  if prev == nil then
    io.stderr:write(tostring(perr) .. "\n")
    return 1
  end
  local cur, cerr = load_report(cur_path)
  if cur == nil then
    io.stderr:write(tostring(cerr) .. "\n")
    return 1
  end
  print(format_compare(prev, cur))
  return 0
end

--- CLI entry point.
--- @param ... string Command-line arguments
--- @return integer Exit code
local function main(...: string): integer
  local argv = {...}
  if argv[1] == "compare" then
    if #argv < 3 then
      io.stderr:write(USAGE)
      return 2
    end
    return run_compare(argv[2], argv[3])
  end
  return run_report(argv)
end

if proc.is_main() then
  os.exit(main(...))
end

local record SizeModule
  type TreeStats = TreeStats
  type Report = Report
  TREES: {string}
  report: function(root: string, binary_path?: string): Report
  totals: function(rep: Report): integer, integer
  format_compare: function(prev: Report, cur: Report): string
  load_report: function(path: string): Report | nil, string
  main: function(...: string): integer
end

local M: SizeModule = {
  TREES = TREES,
  report = report,
  totals = totals,
  format_compare = format_compare,
  load_report = load_report,
  main = main,
}

return M
