-- What a suite's `cosmic test` said of itself, read from its output: the
-- summary line build/test.tl ends a run with,
--
--     test: 1994 tests passed in 193 modules; 0 ran, 1994 stood, 2385 ms; sandboxed
--     test: 2 of 1994 tests failed, 0 infrastructure errors, 2385 ms; sandboxed
--
-- and the key parts a keyed run says under `--census`
-- (build/shared_verdicts.tl's `key_parts`, or the `unmatched` line that
-- says them in its place):
--
--     test: key parts: host kernel X, host Y, system Z, runtime R, compiler C, harness H
--
-- and, after it, the key parts the rows of the verdict cache it found
-- name, each set with how many rows it keys (`census_line`):
--
--     test: census: 1994 rows under host kernel X, ..., harness H; 3 rows under no parts named
--
-- A run that said neither -- one timed out, or failed before its tests
-- ran -- yields no figures, never an error: the driver still records
-- how it ended (`status`).
local State = require("cosmic_ci.state")

local record SuiteOutput
  --- A reason tests were skipped for, and how many were.
  record Skip
    reason: string
    count: integer
  end

  record Figures
    --- "pass" or "fail", from the summary line; nil without one.
    mut verdict?: string
    mut tests?: integer
    mut modules?: integer
    mut ran?: integer
    mut stood?: integer
    mut every?: integer
    mut shared?: integer
    mut failed?: integer
    mut errors?: integer
    mut elapsed_ms?: integer
    --- What the summary line says after its time: "sandboxed", or why not.
    mut sandbox?: string
    --- How many tests a bailing run (`cosmic test --bail`) started none
    --- of after its first failure; nil where the line says none.
    mut not_run?: integer
    --- Each key part by the name the line gives it ("host kernel",
    --- "runtime", ...), its digest's prefix as said ("" for none).
    mut parts?: {string:string}
    --- What the verdict cache held when the run began: its census
    --- line's list as said ("" for "no rows"), which `held` reads;
    --- nil where the run said none.
    mut held?: string
  end
  --- A suite's figures and how it ended ([`SuiteOutput.status`]).
  record Read
    figures: Figures
    status: string
  end
  --- One set of key parts a verdict cache's rows name (`parts`, {} for
  --- rows that name none), and how many rows it keys.
  record Held
    parts: {string:string}
    rows: integer
  end
end

local function number(text: string?): integer?
  if text == nil then return nil end
  return math.tointeger(tonumber(text))
end

--- The parts of a "name digest, name digest, ..." list.
local function parts_of(list: string): {string:string}
  local parts: mut {string:string} = {}
  for item in (list .. ", "):gmatch("(.-), ") do
    local name, value = item:match("^(.-) (%S*)$")
    if name ~= nil and name ~= "" and value ~= nil then parts[name] = value end
  end
  return parts
end

local function pass_figures(detail: string, into: SuiteOutput.Figures)
  into.verdict = "pass"
  into.tests = number(detail:match("^(%d+) tests? passed in "))
  into.modules = number(detail:match("^%d+ tests? passed in (%d+) modules?;"))
  into.ran = number(detail:match("; (%d+) ran, "))
  into.stood = number(detail:match(" (%d+) stood, "))
  into.every = number(detail:match(", (%d+) run every time ")) or 0
  into.shared = number(detail:match(", (%d+) of them on another checkout's verdict, ")) or 0
  into.failed = 0
  into.elapsed_ms = number(detail:match(", (%d+) ms"))
  into.sandbox = detail:match(", %d+ ms; (.*)$") or ""
end

local function fail_figures(detail: string, into: SuiteOutput.Figures): boolean
  local failed, total, errors, ms, rest =
    detail:match("^(%d+) of (%d+) tests? failed, (%d+) infrastructure errors?, (%d+) ms(.*)$")
  if not failed then return false end
  into.verdict = "fail"
  into.failed, into.tests = number(failed), number(total)
  into.errors, into.elapsed_ms = number(errors), number(ms)
  local tail, skipped = assert(rest):match("^(.*); (%d+) not run after the first failure$")
  if skipped then
    into.not_run = number(skipped)
    rest = tail
  end
  into.sandbox = assert(rest):match("^; (.*)$") or ""
  return true
end

--- The sets of key parts a census line's list ([`Figures.held`]) names,
--- as said, the most rows first; none for "" (a cache with no rows).
function SuiteOutput.held(list: string): {SuiteOutput.Held}
  local out: mut {SuiteOutput.Held} = {}
  for group in (list .. "; "):gmatch("(.-); ") do
    local rows, named = group:match("^(%d+) rows? under (.*)$")
    local count = number(rows)
    if count ~= nil and named ~= nil then
      local parts: {string:string} = {}
      if named ~= "no parts named" then parts = parts_of(named) end
      out[#out + 1] = { rows = count, parts = parts }
    end
  end
  return out
end

--- The figures `text`, a suite's stdout, holds: its last summary line's,
--- its last key-parts line's and its last census line's, each left nil
--- where it has none.
function SuiteOutput.parse(text: string): SuiteOutput.Figures
  local figures: SuiteOutput.Figures = {}
  for raw in text:gmatch("[^\n]+") do
    local line = raw:gsub("\r$", "")
    -- A line cut before its elapsed time is no summary.
    local passed = line:match("^test: (%d+ tests? passed in .*, %d+ ms.*)$")
    local failed = line:match("^test: (%d+ of %d+ tests? failed, .*)$")
    local listed = line:match("^test: key parts: (.*)$") or
      line:match("^test: shared verdicts: none of %d+ tests? looked up stood, .* %(([^()]*)%)$")
    local census = line:match("^test: census: (.*)$")
    if passed then
      local parts, held = figures.parts, figures.held
      figures = { parts = parts, held = held }
      pass_figures(passed, figures)
    elseif failed then
      local parts, held = figures.parts, figures.held
      local candidate: SuiteOutput.Figures = { parts = parts, held = held }
      if fail_figures(failed, candidate) then figures = candidate end
    elseif listed then
      figures.parts = parts_of(listed)
    elseif census then
      figures.held = if census == "no rows" then "" else census end
    end
  end
  return figures
end

--- How a suite ended, for its row, given `figures`, what its output
--- said, and `code`, its exit status: "timeout" where the driver ended
--- it (status 124); "fail" where it exited otherwise than 0, whatever
--- its summary said, since the status is what it answered; else its
--- summary line's verdict, or
--- "unreported" where it said none because it stopped before its tests'
--- end.
function SuiteOutput.status(figures: SuiteOutput.Figures, code: integer): string
  if code == 124 then return "timeout" end
  if code ~= 0 then return "fail" end
  return figures.verdict or "unreported"
end

--- What a suite's row holds, from `text`, its stdout, and `code`, its
--- exit status: its figures (`parse`) and its status (`status`). A
--- suite the driver ended (status 124) keeps only its key parts and
--- census, said before its tests ran: a summary line in its output is
--- some test's own nested run's, never the suite's, which it did not
--- reach.
function SuiteOutput.read(text: string, code: integer): SuiteOutput.Read
  local figures = SuiteOutput.parse(text)
  local status = SuiteOutput.status(figures, code)
  if status == "timeout" then figures = { parts = figures.parts, held = figures.held } end
  return { figures = figures, status = status }
end

--- The share of `row`'s tests that stood, as a percentage with one
--- decimal ("99.5"), or "" where it says neither count or both are 0.
function SuiteOutput.stood_percent(row: State.SuiteRun): string
  local ran = row.ran
  local stood = row.stood
  if ran == nil or stood == nil or ran + stood == 0 then return "" end
  return string.format("%.1f", stood * 100.0 / (ran + stood))
end

local function cell(value: any): string
  if value == nil then return "" end
  local text = tostring(value):gsub("|", "\\|"):gsub("[\r\n]", " ")
  return text
end

--- The part names the suites table shows, by its column heading.
local record Shown
  heading: string
  part: string
end

local shown_parts: {Shown} = { { heading = "Runtime", part = "runtime" },
  { heading = "Harness", part = "harness" }, { heading = "Compiler", part = "compiler" },
  { heading = "Store", part = "store" }, { heading = "Host", part = "host" },
  { heading = "System", part = "system" },
  { heading = "Host kernel", part = "host kernel" } }

--- `rows` as the step summary's markdown table of suites: one line each,
--- its counts, its stood share and its key parts.
function SuiteOutput.markdown(rows: {State.SuiteRun}): string
  local headings: mut {string} = { "Worker", "Phase", "Suite", "Status", "Exit", "Tests",
    "Ran", "Stood", "Stood %", "Shared", "ms" }
  local align: mut {string} = { "---", "---", "---", "---", "---:", "---:", "---:",
    "---:", "---:", "---:", "---:" }
  for _, part in ipairs(shown_parts) do
    headings[#headings + 1] = part.heading
    align[#align + 1] = "---"
  end
  local lines: mut {string} = { "| " .. table.concat(headings, " | ") .. " |\n",
    "|" .. table.concat(align, "|") .. "|\n" }
  for _, row in ipairs(rows) do
    local cells: mut {string} = { cell(row.worker), cell(row.phase), cell(row.suite),
      cell(row.status), cell(row.exit_code), cell(row.tests), cell(row.ran),
      cell(row.stood), SuiteOutput.stood_percent(row), cell(row.shared),
      cell(row.elapsed_ms) }
    local parts = row.parts or {}
    for _, part in ipairs(shown_parts) do cells[#cells + 1] = cell(parts[part.part]) end
    lines[#lines + 1] = "| " .. table.concat(cells, " | ") .. " |\n"
  end
  return table.concat(lines)
end

--- The reason of a skipped test with what differs from test to test taken
--- out: a scratch path under /tmp/cosmic-test-, which names the test's own
--- directory, becomes `<dir>`.
local function generic_reason(reason: string): string
  return (reason:gsub("/tmp/cosmic%-test%-[^%s:)]*", "<dir>"))
end

--- Each reason a skipped test gave in `text`, a suite's stdout (its
--- `test: SKIP  <module> <test>: <reason>` lines), with how many gave it,
--- the most first, ties by reason.
function SuiteOutput.skips(text: string): {SuiteOutput.Skip}
  local counts: mut {string:integer} = {}
  for raw in text:gmatch("[^\n]+") do
    local line = raw:gsub("\r$", "")
    local reason = line:match("^test: SKIP  %S+ %S+: (.*)$")
    if reason ~= nil then
      local key = generic_reason(reason)
      counts[key] = (counts[key] or 0) + 1
    end
  end
  local out: mut {SuiteOutput.Skip} = {}
  for reason, count in pairs(counts) do out[#out + 1] = { reason = reason, count = count } end
  table.sort(out, function(a: SuiteOutput.Skip, b: SuiteOutput.Skip): boolean
    if a.count ~= b.count then return a.count > b.count end
    return a.reason < b.reason
  end)
  return out
end

--- The skips of suite `name`, from its stdout `text`, as a page of the
--- run's summary: a heading with the total and a table of each reason with
--- its count; "" where nothing was skipped. A report only: nothing fails
--- for a skip.
function SuiteOutput.skip_report(name: string, text: string): string
  local reasons = SuiteOutput.skips(text)
  if #reasons == 0 then return "" end
  local total = 0
  for _, row in ipairs(reasons) do total = total + row.count end
  local lines: mut {string} = { "### Skipped tests: " .. name .. " (" .. tostring(total) .. ")\n\n",
    "| tests | reason |\n| ---: | --- |\n" }
  for _, row in ipairs(reasons) do
    local escaped = (row.reason:gsub("[|`*<>]", "\\%0"))
    lines[#lines + 1] = "| " .. tostring(row.count) .. " | " .. escaped .. " |\n"
  end
  lines[#lines + 1] = "\n"
  return table.concat(lines)
end

return SuiteOutput
