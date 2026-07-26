#!/usr/bin/env lua

local getopt = require("cosmic.getopt")
local proc = require("cosmic.proc")
local fs = require("cosmic.fs")
-- The .got exit-code contract and its icons live in cosmic.testrun (#779):
-- both reporters feed _cli.build's ci verdict, so they must agree on what
-- an exit code means. See status_of there.
local testrun = require("cosmic.testrun")

local record CheckResult
  status: string
  message: string
  name: string
  file: string
  checker: string
end

local record CategorizedResults
  pass: {CheckResult}
  fail: {CheckResult}
  skip: {CheckResult}
  ignore: {CheckResult}
end

local function extract_checker(filename: string): string
  return filename:match("%.([^%.]+)%.got$")
end

local function format_results(results: {CheckResult}): string
  local lines: {string} = {}
  for _, result in ipairs(results) do
    local status = string.upper(result.status)
    local icon = testrun.STATUS_ICONS[result.status] or " "
    local checker = result.checker or ""
    local line = string.format("%s %-6s %-8s %s", icon, status, checker, result.name)
    if result.status ~= "pass" and result.message and result.message ~= "" then
      line = line .. " (" .. result.message .. ")"
    end
    table.insert(lines, line)
  end
  return table.concat(lines, "\n")
end

local function format_summary(checker_name: string, results: CategorizedResults): string
  local total = #results.pass + #results.fail + #results.skip + #results.ignore
  if total == 0 then
    return ""
  end
  return string.format(
    "%s: %d checks: %d passed, %d failed, %d skipped, %d ignored",
    checker_name, total, #results.pass, #results.fail, #results.skip, #results.ignore
  )
end

local function format_failures(results: {CheckResult}): string
  local lines: {string} = {"", "FAILURES:"}
  local found = false

  for _, result in ipairs(results) do
    if result.status == "fail" then
      found = true
      table.insert(lines, "")
      if result.checker then
        table.insert(lines, string.format("--- %s (%s) ---", result.name, result.checker))
      else
        table.insert(lines, string.format("--- %s ---", result.name))
      end
      if result.message and result.message ~= "" then
        table.insert(lines, result.message)
      end
      if result.file then
        local base = result.file:gsub("%.got$", "")
        local out = fs.read(base .. ".out") or ""
        local err = fs.read(base .. ".err") or ""
        if out ~= "" then
          table.insert(lines, "")
          table.insert(lines, "stdout:")
          table.insert(lines, out)
        end
        if err ~= "" then
          table.insert(lines, "")
          table.insert(lines, "stderr:")
          table.insert(lines, err)
        end
      end
    end
  end

  return found and table.concat(lines, "\n") or nil
end

local function main(...: string): integer, string
  local args = {...}
  local dir: string = nil
  local out: string = nil

  local longopts: {getopt.LongOpt} = {
    {name = "dir", has_arg = "required"},
    {name = "out", has_arg = "required"},
  }
  local parser = getopt.new(args, "", longopts)

  while true do
    local opt, optarg = parser:next()
    if not opt then break end
    if opt == "dir" then
      dir = optarg
    elseif opt == "out" then
      out = optarg
    elseif opt == "?" then
      return 1, "usage: reporter.lua --dir DIR [--out FILE] FILES..."
    end
  end

  local files = parser:remaining()
  if not files or #files == 0 then
    return 1, "usage: reporter.lua --dir DIR [--out FILE] FILES..."
  end
  if not dir then
    return 1, "error: --dir is required"
  end

  local function strip_prefix(file_name: string): string
    if file_name:sub(1, #dir) == dir and file_name:sub(#dir + 1, #dir + 1) == "/" then
      return file_name:sub(#dir + 2)
    end
    return file_name
  end

  -- group files by checker type
  local checker_files: {string: {string}} = {}
  for _, file in ipairs(files) do
    local checker = extract_checker(file)
    if checker then
      checker_files[checker] = checker_files[checker] or {}
      table.insert(checker_files[checker], file)
    end
  end

  -- get sorted list of checkers
  local checkers: {string} = {}
  for checker in pairs(checker_files) do
    table.insert(checkers, checker)
  end
  table.sort(checkers)

  -- collect results for each checker
  local checker_results: {string: CategorizedResults} = {}
  local all_results: {CheckResult} = {}

  for _, checker in ipairs(checkers) do
    local results: CategorizedResults = {pass = {}, fail = {}, skip = {}, ignore = {}}
    local strip_suffix = "%." .. string.gsub(checker, "%-", "%%-") .. "%.got$"

    local result_files = checker_files[checker]
    table.sort(result_files)

    for _, file in ipairs(result_files) do
      local content = fs.read(file)
      if content then
        -- cast: tonumber returns number, status_of takes integer
        local exit_code = (tonumber(string.match(content, "^(%d+)")) or -1) as integer
        local status_str = testrun.status_of(exit_code)
        local base = string.gsub(file, "%.got$", "")
        -- cast: or fallback does not narrow
        local out_content = (fs.read(base .. ".out") or "") as string
        -- cast: or fallback does not narrow
        local err_content = (fs.read(base .. ".err") or "") as string

        local message = ""
        if exit_code ~= 0 and err_content ~= "" then
          message = err_content:match("^([^\n]+)") or ""
        elseif out_content ~= "" then
          message = out_content:match("([^\n]+)\n*$") or ""
        end

        local name_stripped = strip_prefix(file)
        name_stripped = string.gsub(name_stripped, strip_suffix, "")

        local result: CheckResult = {
          status = status_str,
          message = message,
          name = name_stripped,
          file = file,
          checker = checker,
        }

        -- cast: dynamic key into record
        local status_list = (results as {string: {CheckResult}})[result.status]
        if status_list then
          table.insert(status_list, result)
        end
        table.insert(all_results, result)
      end
    end

    checker_results[checker] = results
  end

  -- sort all results by name, then checker
  table.sort(all_results, function(a: CheckResult, b: CheckResult): boolean
      if a.name ~= b.name then return a.name < b.name end
      return (a.checker or "") < (b.checker or "")
    end)

  -- build output
  local parts: {string} = {}
  table.insert(parts, format_results(all_results))

  -- per-checker summaries
  local total_passed, total_failed, total_skipped, total_ignored = 0, 0, 0, 0

  for _, checker in ipairs(checkers) do
    local results = checker_results[checker]
    local summary = format_summary(checker, results)
    if summary and summary ~= "" then
      table.insert(parts, summary)
    end
    total_passed = total_passed + #results.pass
    total_failed = total_failed + #results.fail
    total_skipped = total_skipped + #results.skip
    total_ignored = total_ignored + #results.ignore
  end

  -- total summary (only for multiple checkers)
  if #checkers > 1 then
    local total = total_passed + total_failed + total_skipped + total_ignored
    table.insert(parts, "")
    table.insert(parts, string.format(
        "total: %d checks: %d passed, %d failed, %d skipped, %d ignored",
        total, total_passed, total_failed, total_skipped, total_ignored
      ))
  end

  -- failures
  local failures = format_failures(all_results)
  if failures then
    table.insert(parts, failures)
  end

  -- REPORTER_NOTE: an extra line from the make rule (e.g. lint's
  -- skipped-deleted-files notice). An env var, not a flag: note text
  -- carries spaces, which a shell-free recipe argv cannot (#732).
  local note = os.getenv("REPORTER_NOTE")
  if note and note ~= "" then
    table.insert(parts, note)
  end

  local report = table.concat(parts, "\n")
  print(report)
  -- --out replaces the recipes' `| tee $@` (#732): the reporter writes
  -- its own summary file, so the rule needs no shell and no host tee.
  if out then
    local ok, werr = fs.write(out, report .. "\n")
    if not ok then
      return 1, "error: cannot write " .. out .. ": " .. (werr or "unknown error")
    end
  end
  return total_failed == 0 and 0 or 1, nil
end

if proc.is_main() then
  local code, err = main(...)
  if err then
    io.stderr:write(err .. "\n")
  end
  os.exit(code)
end
