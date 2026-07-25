--- Examples for the cosmic.searcher module.
--- The runtime `.tl` package searcher: what makes `require("mod")` find
--- and compile `mod.tl` when no compiled `mod.lua` exists. Every
--- artifact installs it at boot, so most code never calls it directly —
--- but the two things it returns are worth knowing, because they are
--- what `require()` reports back to you.

-- Example_install demonstrates installing the searcher. It appends to
-- package.searchers, so pre-compiled .lua modules still win; and it is
-- idempotent, because the embed wrapper installs it before an entry
-- that may install it again.
local function Example_install()
  local searcher = require("cosmic.searcher")
  searcher.install()
  searcher.install()
  print("installed")
  -- Output:
  -- installed
end

-- Example_miss demonstrates what a miss looks like. A searcher that
-- declines returns a STRING rather than raising, which is what lets
-- require() go on to report its own "module not found" listing every
-- path it tried.
local function Example_miss()
  local searcher = require("cosmic.searcher")
  local why = searcher.searcher("no_such_module_anywhere")
  print(type(why))
  print((why as string):match("^no %.tl source found") ~= nil) -- cast: a miss returns a string
  -- Output:
  -- string
  -- true
end

-- Suppress unused warnings for examples
local _ = {Example_install, Example_miss}
