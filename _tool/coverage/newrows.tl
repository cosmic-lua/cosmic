--- The would-be `.cosmic-coverage` row for a measured file the
--- committed baseline carries no entry for at all -- a file just
--- added, never a decline in one already tracked.
---
--- `baseline.check` (`_tool/coverage/baseline.tl`) already fails the
--- ratchet over such a file through `compare`'s "not in baseline"
--- problem; this module answers the question that failure used to
--- leave open -- what number goes in the row a builder is told to
--- hand-edit. Split out of `baseline.tl` rather than added to it: that
--- file sits at the repo's file-length cap.
---
--- The line this prints is deliberately the SAME syntax
--- `_tool/coverage/baseline_test.tl`'s `fixture` and
--- `_make/policy_test.tl`'s `baseline_fixture` test helpers already
--- write by hand -- two-space indented, unquoted inner keys -- so it
--- is a paste, not a translation.

local rep = require("_tool.coverage.report")

local type FileReport = rep.FileReport

--- One printable row: `["path"] = {covered = C, total = T},`.
--- @param path string The file's baseline key
--- @param covered integer Lines this run covered
--- @param total integer The file's line universe size
--- @return string The row, newline-free, trailing comma
local function row_line(path: string, covered: integer, total: integer): string
  return string.format("  [%s] = {covered = %d, total = %d},",
    string.format("%q", path), covered, total)
end

--- Print, on stdout, one row per measured file absent from `entries`,
--- under a header -- nothing when every measured file has a row.
--- Never touches an exit code: whether the run overall passed or
--- failed is `baseline.compare`'s decision, made from the same data.
--- @param reports {FileReport} Sorted results from report.compute
--- @param entries {string: any} Baseline rows by path -- presence is all that counts
local function print_missing(reports: {FileReport}, entries: {string: any})
  local lines: {string} = {}
  for _, r in ipairs(reports) do
    if not entries[r.display] then
      lines[#lines + 1] = row_line(r.display, r.covered, r.total)
    end
  end
  if #lines == 0 then
    return
  end
  io.write("coverage ratchet: new files, rows to add by hand\n")
  for _, line in ipairs(lines) do
    io.write(line .. "\n")
  end
end

local record NewRowsModule
  row_line: function(path: string, covered: integer, total: integer): string
  print_missing: function(reports: {FileReport}, entries: {string: any})
end

local M: NewRowsModule = {
  row_line = row_line,
  print_missing = print_missing,
}

return M
