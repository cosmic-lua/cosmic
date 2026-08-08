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

-- Example_miss demonstrates what a miss looks like from require's
-- side: every installed searcher — this module's included — declines
-- with a string rather than raising, so the require fails cleanly.
-- (searcher_test asserts the decline message itself.)
local function Example_miss()
  -- The name is computed so the checker never resolves it.
  local ok = pcall(require, "no_such_" .. "module_anywhere")
  print(ok)
  -- Output:
  -- false
end

-- Suppress unused warnings for examples
local _ = {Example_install, Example_miss}
