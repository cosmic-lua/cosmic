--- The lines hit so far in the open coverage window, read without ending
--- it: what the tests of the collector itself look at. A program that
--- collects lines starts and stops a window ([`cosmic.coverage`]); only
--- a test about the collector has a window open that it did not start
--- (the one [`build.test`] opens around it), and reads it in place.

-- The raw collector is handed to this wrapper alone of the build's
-- modules (core/store.c's `raw_modules`), as it is to cosmic.coverage,
-- and only while this module loads from the binary's own tree.
local type NativeCoverage = require("cosmic.internal.debug")

local extra: any = select(2, ...)
local native: NativeCoverage
if type(extra) == "table" then
  native = extra as NativeCoverage
else
  native = require("cosmic.internal.debug")
end

local record coverage_hits
end

--- A copy of every line hit so far in the open window, by module import
--- path, in the form [`cosmic.coverage`]'s `stop` answers: reads only, so
--- the window is as it was.
--- Empty when none is open.
--- @return Hits Every line hit so far
function coverage_hits.snapshot(): NativeCoverage.Hits
  return native.snapshot()
end

--- The line each of the core's own C functions begins on, among
--- [`cosmic.coverage`]'s `native_lines`: a function was entered when a hit names
--- its line. Empty in a core built without native coverage.
--- @return Hits Every C function's first line, each true
function coverage_hits.native_entries(): NativeCoverage.Hits
  return native.entries()
end

return coverage_hits
