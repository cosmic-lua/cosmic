--- The records a build writes, and the one grammar they are written in.
---
--- Four things leave a run for something other than a person to read:
--- a per-target **row**, a stage **summary**, a verb's **verdict**, and
--- the **exit code** each maps to. CI greps them, `ci` grades the
--- summaries its own stages wrote, and the verdict line is documented
--- as the record that survives a truncated log. That makes them an
--- interface, and an interface assembled at four call sites with
--- `..` is one that drifts a word at a time.
---
--- So it lives here, once. A printer imports it; a test asserting on
--- output imports it too, which is what stops a test from freezing a
--- spelling the printer has already left behind.
---
--- The grammar:
---
---     ✓ cosmic/fs/init_test.tl (7 test functions)  12ms   <- row
---     19 checks: 18 passed, 1 failed                      <- summary
---     wall: 73148ms  slowest: fixpoint_test.tl (48022ms)  <- summary
---     test: FAIL (1 of 19 files)                          <- verdict
---
--- Exit codes are the same three everywhere: 0 pass, 2 skip, anything
--- else fail. `skip` is NOT a pass — a stage that stopped checking and
--- said nothing is the failure this distinction exists to make visible.

local fs = require("cosmic.fs")

--- A recorded result's status.
local EXIT_OK < const > = 0
local EXIT_SKIP < const > = 2

--- Display icons for a `.got` status.
local ICONS < const >: {string: string} = {
  pass = "✓",
  fail = "✗",
  skip = "→",
  ignore = "○",
}

--- The stage suffixes a `.got` base carries, longest first so `.test`
--- cannot strip out of `.benchmark`.
local STAGES < const >: {string} = {
  "benchmark", "example", "coverage", "test", "fmt", "lint",
}

--- Classify the exit code recorded in a `.got` file.
--- @param exit_code integer Exit code from the .got file
--- @return string "pass" (0), "skip" (2), or "fail" (anything else)
local function status_of(exit_code: integer): string
  if exit_code == EXIT_OK then
    return "pass"
  elseif exit_code == EXIT_SKIP then
    return "skip"
  end
  return "fail"
end

--- The name a row carries: the SOURCE this result is about.
---
--- A basename is not a name in a project with directory modules. Eleven
--- files are called `init_test.tl` in this tree, and eleven rows called
--- `init_test.tl` name none of them -- a failing row you cannot resolve
--- to a file costs a grep, and the grep has eleven hits. The build
--- directory mirrors the source tree, so dropping `o/` and the stage
--- suffix leaves the path the user typed, which is also the path an
--- editor will open.
---
--- The coverage lane keeps its `coverage/` segment, because that is a
--- true statement about which run produced the row.
--- @param base string A `.got` base path, e.g. `o/cosmic/fs/init_test.tl.test`
--- @return string The source path, e.g. `cosmic/fs/init_test.tl`
local function display(base: string): string
  local name = base:gsub("^o/", "")
  for _, stage in ipairs(STAGES) do
    local cut = name:gsub("%." .. stage .. "$", "")
    if cut ~= name then
      return cut
    end
  end
  return name
end

--- Which stage a `.got` base belongs to, "" when it names none.
--- @param base string A `.got` base path
--- @return string The stage name, or ""
local function stage_of(base: string): string
  for _, stage in ipairs(STAGES) do
    if base:sub(-#stage - 1) == "." .. stage then
      return stage
    end
  end
  return ""
end

--- One result row.
---
--- The annotation is the count of things the target actually ran, and
--- it is only ever attached to a status that ran them: a `skip` with
--- "(7 test functions)" describes work that did not happen, and a
--- `fail` row's useful number is in the failure block below it.
--- @param status string "pass", "fail" or "skip"
--- @param name string The row's name, from `display`
--- @param count integer How many units ran, 0 when unrecorded
--- @param unit string What the count counts ("test functions")
--- @param wall_ms integer Duration, negative when unrecorded
--- @return string The row, without its newline
local function row(status: string, name: string, count: integer,
    unit: string, wall_ms: integer): string
  local out = (ICONS[status] or ICONS.fail) .. " " .. name
  if status == "pass" and count > 0 then
    out = out .. string.format(" (%d %s)", count, unit)
  end
  if wall_ms >= 0 then
    out = out .. string.format("  %dms", wall_ms)
  end
  return out
end

--- The counts line: `N checks: P passed[, F failed][, S skipped]`.
--- @param passed integer
--- @param failed integer
--- @param skipped integer
--- @return string The line, without its newline
local function counts(passed: integer, failed: integer,
    skipped: integer): string
  local out = (passed + failed + skipped) .. " checks: " .. passed .. " passed"
  if failed > 0 then
    out = out .. ", " .. failed .. " failed"
  end
  if skipped > 0 then
    out = out .. ", " .. skipped .. " skipped"
  end
  return out
end

--- Read a stage summary back: what its counts line says.
---
--- The inverse of `counts`, and the reason the two live together. A
--- verb's verdict is a claim about the stage that just ran, and the
--- only thing that counted that stage is the summary it wrote.
--- Guessing from the size of the file list instead makes
--- `test: FAIL (7 files)` mean "seven files were selected" while
--- reading as "seven failed".
--- @param text string A summary file's contents
--- @return integer Passed, -1 when the text carries no counts line
--- @return integer Failed
--- @return integer Skipped
local function parse_counts(text: string): integer, integer, integer
  local total = text:match("(%d+) checks:")
  if not total then
    return -1, 0, 0
  end
  local passed = tonumber(text:match("checks: (%d+) passed")) or 0
  local failed = tonumber(text:match(", (%d+) failed")) or 0
  local skipped = tonumber(text:match(", (%d+) skipped")) or 0
  return math.tointeger(passed), math.tointeger(failed),
  math.tointeger(skipped)
end

--- A verb's verdict detail: what it did, or what went wrong with it.
---
--- `N unit` when everything passed, `M of N unit` when it did not, so
--- the one line that survives truncation says how much of the stage
--- failed rather than how much of it there was.
--- @param failed integer How many targets failed
--- @param total integer How many targets there were
--- @param unit string The singular noun ("file")
--- @return string The detail, ready for `verdict`
local function detail(failed: integer, total: integer, unit: string): string
  local noun = total == 1 and unit or unit .. "s"
  if failed <= 0 then
    return total .. " " .. noun
  end
  return failed .. " of " .. total .. " " .. noun
end

--- The verdict detail for a stage, read from the summary it wrote.
---
--- Falls back to the plain count when there is no summary to read: a
--- stage that failed before writing one (a validation error, a make
--- that never started) has no per-target counts, and inventing them
--- would be worse than saying how big the stage was.
--- @param summary_path string Path to the stage's summary file
--- @param total integer How many targets the stage had
--- @param unit string The singular noun ("file")
--- @return string The detail
local function stage_detail(summary_path: string, total: integer,
    unit: string): string
  local text = fs.read(summary_path)
  if text == nil then
    return detail(0, total, unit)
  end
  local passed, failed, skipped = parse_counts(text as string) -- cast: nil ruled out
  if passed < 0 then
    return detail(0, total, unit)
  end
  return detail(failed, passed + failed + skipped, unit)
end

--- Print a verb's verdict line and return the exit code it means.
---
--- Every verb ends in one, so a caller that reads only the last line
--- still knows what happened.
--- @param verb string The verb
--- @param ok boolean Whether it succeeded
--- @param what string Parenthetical detail, empty for none
--- @return integer 0 when ok, 1 otherwise
local function verdict(verb: string, ok: boolean, what: string): integer
  io.write(verb .. (ok and ": PASS" or ": FAIL") ..
    (what ~= "" and " (" .. what .. ")" or "") .. "\n")
  return ok and 0 or 1
end

local record RecordsModule
  EXIT_OK: integer
  EXIT_SKIP: integer
  ICONS: {string: string}
  status_of: function(exit_code: integer): string
  display: function(base: string): string
  stage_of: function(base: string): string
  row: function(status: string, name: string, count: integer, unit: string, wall_ms: integer): string
  counts: function(passed: integer, failed: integer, skipped: integer): string
  parse_counts: function(text: string): integer, integer, integer
  detail: function(failed: integer, total: integer, unit: string): string
  stage_detail: function(summary_path: string, total: integer, unit: string): string
  verdict: function(verb: string, ok: boolean, what: string): integer
end

local M: RecordsModule = {
  EXIT_OK = EXIT_OK,
  EXIT_SKIP = EXIT_SKIP,
  ICONS = ICONS,
  status_of = status_of,
  display = display,
  stage_of = stage_of,
  row = row,
  counts = counts,
  parse_counts = parse_counts,
  detail = detail,
  stage_detail = stage_detail,
  verdict = verdict,
}

return M
