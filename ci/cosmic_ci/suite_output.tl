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
  into.tests = number(detail:match("^(%d+) tests,"))
  into.modules = number(detail:match("^%d+ tests, (%d+) modules;"))
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
    detail:match("^(%d+) of (%d+) failed, (%d+) infrastructure errors, (%d+) ms(.*)$")
  if not failed then return false end
  into.verdict = "fail"
  into.failed, into.tests = number(failed), number(total)
  into.errors, into.elapsed_ms = number(errors), number(ms)
  into.sandbox = rest:match("^; (.*)$") or ""
  return true
end

--- The figures `text`, a suite's stdout, holds: its last summary line's
--- and its last key-parts line's, each left nil where it has none.
function SuiteOutput.parse(text: string): SuiteOutput.Figures
  local figures: SuiteOutput.Figures = {}
  for raw in text:gmatch("[^\n]+") do
    local line = raw:gsub("\r$", "")
    local passed = line:match("^test: PASS %((.*)%)$")
    local failed = line:match("^test: FAIL %((.*)%)$")
    local listed = line:match("^test: key parts: (.*)$") or
      line:match("^test: shared verdicts: none of %d+ tests looked up stood, .* %(([^()]*)%)$")
    if passed then
      local parts = figures.parts
      figures = { parts = parts }
      pass_figures(passed, figures)
    elseif failed then
      local parts = figures.parts
      local candidate: SuiteOutput.Figures = { parts = parts }
      if fail_figures(failed, candidate) then figures = candidate end
    elseif listed then
      figures.parts = parts_of(listed)
    end
  end
  return figures
end

--- How a suite ended, for its row: "timeout" where the driver ended it
--- (status 124), else its summary line's verdict, else "unreported":
--- it said none, having stopped before its tests' end.
function SuiteOutput.status(figures: SuiteOutput.Figures, code: integer): string
  if code == 124 then return "timeout" end
  return figures.verdict or "unreported"
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
