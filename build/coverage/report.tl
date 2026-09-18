--- Turning one run's collected line hits into one module's own
--- hit-or-not line map, once for the whole `cosmic test` run rather
--- than once per test: instrumenting only the whole run is enough to
--- answer "how much of the tree did the suite touch", the question a
--- first cut of coverage needs to answer, and it costs one hook
--- install/remove instead of one pair per test.

local Coverage = require("cosmic.coverage")
local lines = require("build.coverage.lines")
local importer = require("build.importer")
local type compiler = require("build.compiler")

local type Module = importer.Module

local record report
  --- One module's own executable lines, hit (true) or not (false).
  type LineHits = {integer: boolean}
end

--- Every executable line of `m`'s own source, hit or not -- the form a
--- caller writes into `o/records.db`'s `coverage` table one row per
--- line, so a specific never-hit line can be pointed at directly
--- rather than only counted, and a percentage is a plain count over
--- the result (`hit`/`#total`). A module whose source no longer parses
--- here, which should not happen since `m` only ever holds source that
--- already compiled once earlier in the same run, reports the parse
--- failure rather than a fabricated count.
--- @param built compiler The loaded compiler capsule (`build.teal.load()`)
--- @param m Module The module to compute lines for
--- @param hits Coverage.Hits Every line hit, by module import path
--- @return LineHits | nil Every executable line, hit (true) or not (false)
--- @return string Error message on a parse failure
function report.lines_of(built: compiler, m: Module,
                         hits: Coverage.Hits): report.LineHits | nil, string
  local executable, trouble = lines.executable(built, m.source, m.file)
  if executable == nil then
    return nil, trouble
  end
  local hit_lines = hits[m.path] or {}
  local out: report.LineHits = {}
  for line in pairs(executable) do
    out[line] = hit_lines[line] == true
  end
  return out, ""
end

return report
