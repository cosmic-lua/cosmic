--- Turning one run's collected line hits into one module's own
--- hit-or-not line map. `build.test` opens one coverage window per
--- test (plus one for each module's own one-time load code) and merges
--- every window's hits into a single whole-run accumulator before
--- calling this; this module only ever sees that one flat `hits` table
--- and does not care how many separate windows fed into it.

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
--- caller writes into `o/build.db`'s `coverage` table one row per
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
