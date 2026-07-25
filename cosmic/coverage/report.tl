--- Coverage reporting: merge .cov files and render per-file line coverage.
--- Sources recorded by the collector are normalized to repo-relative
--- paths, compiled artifacts (o/X.lua) map back to their X.tl source,
--- and the denominator comes from static executable-line analysis of
--- each file unioned with the lines actually hit.
local codec = require("cosmic.codec")
local fs = require("cosmic.fs")
local types = require("cosmic.fs.types")
local cov_lines = require("cosmic.coverage.lines")

--- One source file's merged coverage state.
local record FileEntry
  display: string -- repo-relative path shown in the report
  parse: string -- path whose text is analyzed for executable lines
  hits: {integer: integer}
end

--- One source file's computed coverage result.
local record FileReport
  display: string
  covered: integer
  total: integer
  missing: {integer} -- sorted executable lines with no hits
  note: string -- analysis caveat (e.g. parse failure), or nil
end

--- Check whether a path is excluded from coverage reporting.
--- Tests and examples measure themselves by running; type declaration
--- files carry no executable code.
--- @param path string A source path
--- @return boolean
local function is_excluded(path: string): boolean
  if path:match("_test%.tl$") or path:match("_test%.lua$") then
    return true
  end
  if path:match("_example%.tl$") or path:match("_example%.lua$") then
    return true
  end
  if path:match("%.d%.tl$") then
    return true
  end
  return false
end

--- Normalize a collector source string to report paths.
--- Returns nil for chunks that are not repo source files: strings,
--- stdin, absolute paths outside the working tree (like the binary's
--- own /zip modules), and excluded files.
--- @param src string A chunk source as recorded by the collector (e.g. "@o/lib/x.lua")
--- @param cwd string The working directory to relativize against
--- @return string | nil The display path, or nil to skip this chunk
--- @return string? The path to analyze for executable lines
local function normalize(src: string, cwd: string): string | nil, string
  if src:sub(1, 1) ~= "@" then
    return nil
  end
  local p = src:sub(2)
  if cwd ~= "" and p:sub(1, #cwd + 1) == cwd .. "/" then
    p = p:sub(#cwd + 2)
  end
  while p:sub(1, 2) == "./" do
    p = p:sub(3)
  end
  if p:sub(1, 1) == "/" then
    return nil
  end
  if is_excluded(p) then
    return nil
  end
  if p:match("^o/") and p:match("%.lua$") then
    local tl_path = p:sub(3):gsub("%.lua$", ".tl")
    if fs.isfile(tl_path) then
      return tl_path, p
    end
    return nil
  end
  if (p:match("%.tl$") or p:match("%.lua$")) and fs.isfile(p) then
    return p, p
  end
  return nil
end

--- Scan a directory for .cov data files and .tl source files.
--- Source files found this way join the report with zero hits, so
--- entirely untested modules show up instead of vanishing.
--- @param dir string Directory to scan recursively
--- @param cov_files {string} Collects .cov file paths
--- @param src_files {string} Collects .tl source paths
local function scan_dir(dir: string, cov_files: {string}, src_files: {string})
  fs.walk(dir, function(path: string, _name: string, st: types.WalkStat, _ctx: {boolean})
      if st:is_dir() then
        return
      end
      if path:match("%.cov$") then
        cov_files[#cov_files + 1] = path
      elseif path:match("%.tl$") and not is_excluded(path) then
        src_files[#src_files + 1] = path
      end
    end, {})
end

--- Read one .cov file written by the collector.
--- @param path string The .cov file path
--- @return {string: {integer: integer}} | nil Hits by chunk source, or nil on error
--- @return string? Error message if reading or decoding failed
local function read_cov(path: string): {string: {integer: integer}} | nil, string
  local body, err = fs.read(path)
  if not body then
    return nil, err
  end
  local data, derr = codec.decode_lua_unsafe(body)
  if data == nil then
    return nil, derr
  end
  local t = data as {string: any} -- cast: from any
  if t["version"] ~= 1 then
    return nil, "unsupported coverage data version"
  end
  local hits = t["hits"]
  if hits == nil then
    return nil, "missing hits table"
  end
  return hits as {string: {integer: integer}} -- cast: from any
end

--- Merge one chunk's hit counts into the per-file entries.
--- @param entries {string: FileEntry} Accumulated entries by display path
--- @param display string The normalized display path
--- @param parse string The path to analyze for executable lines
--- @param hits {integer: integer} Line hit counts to add
local function merge_hits(entries: {string: FileEntry}, display: string,
    parse: string, hits: {integer: integer})
  local entry = entries[display]
  if not entry then
    entry = {display = display, parse = parse, hits = {}}
    entries[display] = entry
  end
  for line, n in pairs(hits) do
    entry.hits[line] = (entry.hits[line] or 0) + n
  end
end

--- Compute one file's coverage from its merged hits.
--- The line universe is the statically derived executable lines unioned
--- with the lines actually hit; hit lines prove their own executability
--- (multi-line statements, function `end` lines), so the union corrects
--- what static analysis cannot see.
--- @param entry FileEntry The merged entry for one file
--- @return FileReport
local function analyze(entry: FileEntry): FileReport
  local report: FileReport = {
    display = entry.display,
    covered = 0,
    total = 0,
    missing = {},
  }
  local exec: {integer: boolean} = nil
  local source, rerr = fs.read(entry.parse)
  if not source then
    report.note = rerr or ("cannot read " .. entry.parse)
  else
    local lerr: string
    exec, lerr = cov_lines.executable_lines(source, entry.parse)
    if not exec then
      report.note = lerr or "static analysis failed"
    end
  end
  local universe: {integer: boolean} = {}
  if exec then
    for line in pairs(exec) do
      universe[line] = true
    end
  end
  for line in pairs(entry.hits) do
    universe[line] = true
  end
  for line in pairs(universe) do
    report.total = report.total + 1
    if entry.hits[line] then
      report.covered = report.covered + 1
    else
      report.missing[#report.missing + 1] = line
    end
  end
  table.sort(report.missing)
  return report
end

--- Format sorted line numbers as compact ranges, e.g. "3-5,9,12-14".
--- @param lines {integer} Sorted line numbers
--- @param max_ranges integer Truncate after this many ranges
--- @return string
local function format_ranges(lines: {integer}, max_ranges: integer): string
  local parts: {string} = {}
  local first: integer = nil
  local last: integer = nil
  local hidden = 0
  local function flush()
    if not first then
      return
    end
    if #parts < max_ranges then
      if first == last then
        parts[#parts + 1] = tostring(first)
      else
        parts[#parts + 1] = first .. "-" .. last
      end
    else
      hidden = hidden + 1
    end
  end
  for _, line in ipairs(lines) do
    if last and line == last + 1 then
      last = line
    else
      flush()
      first = line
      last = line
    end
  end
  flush()
  local out = table.concat(parts, ",")
  if hidden > 0 then
    out = out .. " +" .. hidden .. " more"
  end
  return out
end

--- Render file reports plus a totals row.
--- @param reports {FileReport} Per-file results, already sorted
--- @return string
local function render(reports: {FileReport}): string
  local width = #("total")
  for _, r in ipairs(reports) do
    if #r.display > width then
      width = #r.display
    end
  end
  local out: {string} = {}
  local covered_sum = 0
  local total_sum = 0
  for _, r in ipairs(reports) do
    covered_sum = covered_sum + r.covered
    total_sum = total_sum + r.total
    local pct = r.total > 0 and (100.0 * r.covered / r.total) or 100.0
    local line = string.format("%-" .. width .. "s %6.1f%% %9s",
      r.display, pct, r.covered .. "/" .. r.total)
    if #r.missing > 0 then
      line = line .. "  missing: " .. format_ranges(r.missing, 8)
    end
    if r.note then
      line = line .. "  (" .. r.note .. ")"
    end
    out[#out + 1] = line
  end
  local pct = total_sum > 0 and (100.0 * covered_sum / total_sum) or 100.0
  out[#out + 1] = string.format("%-" .. width .. "s %6.1f%% %9s",
    "total", pct, covered_sum .. "/" .. total_sum)
  return table.concat(out, "\n")
end

--- Merge .cov data into sorted per-file results.
--- Each path may be a .cov file, a directory to scan for .cov files, or
--- a source directory whose .tl files join the report even with no hits.
--- Warnings about unreadable inputs go to stderr.
--- @param paths {string} Input paths
--- @return {FileReport} | nil Sorted results, or nil when no coverage data was found
--- @return string? Error message when no data was found
local function compute(paths: {string}): {FileReport} | nil, string
  local cov_files: {string} = {}
  local src_files: {string} = {}
  for _, p in ipairs(paths) do
    if fs.isdir(p) then
      scan_dir(p, cov_files, src_files)
    elseif p:match("%.cov$") then
      cov_files[#cov_files + 1] = p
    else
      io.stderr:write("coverage: not a directory or .cov file: " .. p .. "\n")
    end
  end
  if #cov_files == 0 then
    return nil, "coverage: no .cov files found"
  end

  local cwd = fs.getcwd() or ""
  local entries: {string: FileEntry} = {}
  for _, path in ipairs(cov_files) do
    local hits, err = read_cov(path)
    if not hits then
      io.stderr:write("coverage: " .. path .. ": " .. (err or "unreadable") .. "\n")
    else
      -- cast: record union after guard
      for src, lines in pairs(hits as {string: {integer: integer}}) do
        local display, parse = normalize(src, cwd)
        if display then
          merge_hits(entries, display, parse, lines)
        end
      end
    end
  end
  for _, s in ipairs(src_files) do
    if not entries[s] then
      local compiled = "o/" .. s:gsub("%.tl$", ".lua")
      entries[s] = {
        display = s,
        parse = fs.isfile(compiled) and compiled or s,
        hits = {},
      }
    end
  end

  local reports: {FileReport} = {}
  for _, entry in pairs(entries) do
    reports[#reports + 1] = analyze(entry)
  end
  table.sort(reports, function(a: FileReport, b: FileReport): boolean
      return a.display < b.display
    end)
  return reports
end

--- Merge .cov data and render the coverage report to stdout.
--- @param paths {string} Input paths (see compute)
--- @return integer Exit code: 0 on success, 1 when no coverage data was found
local function report(paths: {string}): integer
  local reports, err = compute(paths)
  if not reports then
    io.stderr:write((err or "coverage: no data") .. "\n")
    return 1
  end
  io.write(render(reports as {FileReport}) .. "\n") -- cast: record union after guard
  return 0
end

local record ReportModule
  type FileReport = FileReport
  report: function(paths: {string}): integer
  compute: function(paths: {string}): {FileReport} | nil, string
  normalize: function(src: string, cwd: string): string | nil, string
  format_ranges: function(lines: {integer}, max_ranges: integer): string
  read_cov: function(path: string): {string: {integer: integer}} | nil, string
end

local M: ReportModule = {
  report = report,
  compute = compute,
  normalize = normalize,
  format_ranges = format_ranges,
  read_cov = read_cov,
}

return M
