-- What a suite's `cosmic test` said of itself, read from its output: the
-- summary line build/test.tl ends a run with,
--
--     test: PASS (1994 tests, 193 modules; 0 ran, 1994 stood, 2385 ms; sandboxed)
--     test: FAIL (2 of 1994 failed, 0 infrastructure errors, 2385 ms; sandboxed)
--
-- and the key parts a keyed run says under `--census`
-- (build/shared_verdicts.tl's `key_parts`, or the `unmatched` line that
-- says them in its place):
--
--     test: key parts: host features X, host Y, system Z, runtime R, compiler C, harness H
--
-- and, after it, the key parts the rows of the verdict cache it found
-- name, each set with how many rows it keys (`census_line`):
--
--     test: census: 1994 rows under host features X, ..., harness H; 3 rows under no parts named
--
-- A run that said neither -- one timed out, or failed before its tests
-- ran -- yields no figures, never an error: the driver still records
-- how it ended (`status`).
local State = require("cosmic_ci.state")

local record SuiteOutput
  record Figures
    --- "pass" or "fail", from the summary line; nil without one.
    verdict: string
    tests: integer
    modules: integer
    ran: integer
    stood: integer
    every: integer
    -- TODO: drop `assumed`, here, in cosmic_ci/state.tl's `runs` and in
    -- their tests, once ci/cosmic-driver.pin names a release that keys
    -- every unsandboxed run by declaration (plan 4.2's PR 3): the tree's
    -- tool assumes no verdict, and only the pinned driver's summary, of
    -- the fixtures it runs, still counts one.
    assumed: integer
    shared: integer
    failed: integer
    errors: integer
    elapsed_ms: integer
    --- What the summary line says after its time: "sandboxed", or why not.
    sandbox: string
    --- Each key part by the name the line gives it ("host features",
    --- "runtime", ...), its digest's prefix as said ("" for none).
    parts: {string:string}
    --- What the verdict cache held when the run began: its census
    --- line's list as said ("" for "no rows"), which `held` reads;
    --- nil where the run said none.
    held: string
  end
  --- One set of key parts a verdict cache's rows name (`parts`, {} for
  --- rows that name none), and how many rows it keys.
  record Held
    parts: {string:string}
    rows: integer
  end
end

local function number(text: string | nil): integer | nil
  if text == nil then return nil end
  return math.tointeger(tonumber(text))
end

--- The parts of a "name digest, name digest, ..." list.
local function parts_of(list: string): {string:string}
  local parts: {string:string} = {}
  for item in (list .. ", "):gmatch("(.-), ") do
    local name, value = item:match("^(.-) (%S*)$")
    if name and name ~= "" then parts[name] = value end
  end
  return parts
end

local function pass_figures(detail: string, into: SuiteOutput.Figures)
  into.verdict = "pass"
  into.tests = number(detail:match("^(%d+) tests?,"))
  into.modules = number(detail:match("^%d+ tests?, (%d+) modules?;"))
  into.ran = number(detail:match("; (%d+) ran, "))
  into.stood = number(detail:match(" (%d+) stood, "))
  into.every = number(detail:match(", (%d+) run every time ")) or 0
  into.assumed = number(detail:match(", (%d+) assumed ")) or 0
  into.shared = number(detail:match(", (%d+) of them on another checkout's verdict, ")) or 0
  into.failed = 0
  into.elapsed_ms = number(detail:match(", (%d+) ms"))
  into.sandbox = detail:match(", %d+ ms; (.*)$") or ""
end

local function fail_figures(detail: string, into: SuiteOutput.Figures): boolean
  local failed, total, errors, ms, rest =
    detail:match("^(%d+) of (%d+) failed, (%d+) infrastructure errors?, (%d+) ms(.*)$")
  if not failed then return false end
  into.verdict = "fail"
  into.failed, into.tests = number(failed), number(total)
  into.errors, into.elapsed_ms = number(errors), number(ms)
  into.sandbox = rest:match("^; (.*)$") or ""
  return true
end

--- The sets of key parts a census line's list (`Figures.held`) names,
--- as said, the most rows first; none for "" (a cache with no rows).
function SuiteOutput.held(list: string): {SuiteOutput.Held}
  local out: {SuiteOutput.Held} = {}
  for group in (list .. "; "):gmatch("(.-); ") do
    local rows, named = group:match("^(%d+) rows? under (.*)$")
    if rows then
      out[#out + 1] = { rows = number(rows),
        parts = named == "no parts named" and {} or parts_of(named) }
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
    local passed = line:match("^test: PASS %((.*)%)$")
    local failed = line:match("^test: FAIL %((.*)%)$")
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
      figures.held = census == "no rows" and "" or census
    end
  end
  return figures
end

--- How a suite ended, for its row, given `figures`, what its output
--- said, and `code`, its exit status: "timeout" where the driver ended
--- it (status 124); "fail" where it exited otherwise than 0, whatever
--- its summary said (`--audit` says PASS and exits 1 for a test that
--- read what it does not declare); else its summary line's verdict, or
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
function SuiteOutput.read(text: string, code: integer): SuiteOutput.Figures, string
  local figures = SuiteOutput.parse(text)
  local status = SuiteOutput.status(figures, code)
  if status == "timeout" then figures = { parts = figures.parts, held = figures.held } end
  return figures, status
end

--- The share of `row`'s tests that stood, as a percentage with one
--- decimal ("99.5"), or "" where it says neither count or both are 0.
function SuiteOutput.stood_percent(row: State.SuiteRun): string
  if row.ran == nil or row.stood == nil or row.ran + row.stood == 0 then return "" end
  return string.format("%.1f", row.stood * 100.0 / (row.ran + row.stood))
end

local function cell(value: any): string
  if value == nil then return "" end
  local text = tostring(value):gsub("|", "\\|"):gsub("[\r\n]", " ")
  return text
end

--- The part names the suites table shows, by its column heading.
local shown_parts: {{string}} = { { "Runtime", "runtime" }, { "Harness", "harness" },
  { "Compiler", "compiler" }, { "Host", "host" }, { "System", "system" },
  { "Host features", "host features" } }

--- `rows` as the step summary's markdown table of suites: one line each,
--- its counts, its stood share and its key parts.
function SuiteOutput.markdown(rows: {State.SuiteRun}): string
  local headings: {string} = { "Worker", "Phase", "Suite", "Status", "Exit", "Tests",
    "Ran", "Stood", "Stood %", "Shared", "ms" }
  local align: {string} = { "---", "---", "---", "---", "---:", "---:", "---:",
    "---:", "---:", "---:", "---:" }
  for _, part in ipairs(shown_parts) do
    headings[#headings + 1] = part[1]; align[#align + 1] = "---"
  end
  local lines: {string} = { "| " .. table.concat(headings, " | ") .. " |\n",
    "|" .. table.concat(align, "|") .. "|\n" }
  for _, row in ipairs(rows) do
    local cells: {string} = { cell(row.worker), cell(row.phase), cell(row.suite),
      cell(row.status), cell(row.exit_code), cell(row.tests), cell(row.ran),
      cell(row.stood), SuiteOutput.stood_percent(row), cell(row.shared),
      cell(row.elapsed_ms) }
    local parts = row.parts or {}
    for _, part in ipairs(shown_parts) do cells[#cells + 1] = cell(parts[part[2]]) end
    lines[#lines + 1] = "| " .. table.concat(cells, " | ") .. " |\n"
  end
  return table.concat(lines)
end

return SuiteOutput
