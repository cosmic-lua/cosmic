--- Turns one run's collected line hits into one module's own map of
--- executable lines, hit or not. [`build.test`] opens one coverage window
--- per test, plus one for each module's one-time load code, and merges
--- every window's hits into one whole-run table before calling this
--- module, which sees only that table.

local Coverage = require("cosmic.coverage")
local Sqlite = require("cosmic.sqlite")
local syntax_lines = require("build.coverage.syntax_lines")
local importer = require("build.importer")

local type Module = importer.Module

local record coverage
  --- One module's own executable lines, hit (true) or not (false).
  type LineHits = {integer: boolean}
end

--- Every executable line of `m`'s own source, hit or not: the form a
--- caller writes into `build.db`'s `coverage` table, one row per line,
--- so a line never hit can be named and a percentage is a plain count
--- over the result (`hit`/`#total`). The lines come from
--- [`syntax_lines.executable_cached`], keyed by `m.source_hash` in `db`'s
--- `executable` table, so a module whose source has not changed since a
--- previous run is not reparsed. A source that fails to parse, which
--- should not happen since `m` holds only source that compiled earlier in
--- the run, returns the parse failure rather than a made-up count.
---
--- The lines are those of the new checker's syntax tree over the text it read ([`build.coverage.syntax_lines`]).
--- @param db Sqlite.Handle The working database ([`work.open`]'s `.db`)
--- @param m Module The module to compute lines for
--- @param hits Coverage.Hits Every line hit, by module import path
--- @return LineHits | nil Every executable line, hit (true) or not (false)
--- @return string Error message on a parse failure
function coverage.lines_of(db: Sqlite.Handle, m: Module, hits: Coverage.Hits): coverage.LineHits?, string
  local executable, trouble = syntax_lines.executable_cached(db, m.source_hash, m.source, m.file)
  if executable == nil then
    return nil, trouble
  end
  local hit_lines = hits[m.path] or {}
  local out: coverage.LineHits = {}
  for line in pairs(executable) do
    out[line] = hit_lines[line] == true
  end
  return out, ""
end

return coverage
