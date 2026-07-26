#!/usr/bin/env cosmic
-- The Makefile-path fetcher.
--
-- Its url building and archive-name validation used to live here, as a
-- second implementation beside `cosmic --make fetch`'s — reading the
-- SAME committed `*.pin.tl` files. The two drifted (this side
-- interpolated any scalar field as `{key}`, the other only `{version}`
-- and `{platform}`), which is the failure a pin exists to prevent,
-- happening to the pin reader itself. Resolution is `_make.pin` now, so
-- those tests moved to where the one reader is exercised — against the
-- REAL committed pins, in `_make/pins_test.tl`, rather than against
-- hand-written strings.
--
-- What is left here is this file's own surface: it exports nothing, and
-- that is the assertion. When the bridge goes (3i) this file goes with
-- it, and the shared reader stays.

local fetcher = require("_build.build-fetch")

local function test_the_fetcher_exports_nothing()
  local names: {string} = {}
  for key in pairs(fetcher as {string: any}) do -- cast: module table
    names[#names + 1] = key
  end
  table.sort(names)
  assert(#names == 0,
    "pin resolution belongs to _make.pin, shared with `--make fetch`; " ..
    "a second copy here is the drift this consolidation removed. Found: " ..
    table.concat(names, ", "))
end
test_the_fetcher_exports_nothing()

print("all build-fetch tests passed")
