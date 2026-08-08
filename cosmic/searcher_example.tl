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
-- require() report its own "module not found" carrying every
-- searcher's reason — this module's line included.
local function Example_miss()
  -- The name is computed so the checker never resolves it.
  local missing = "no_such_" .. "module_anywhere"
  local ok, err = pcall(require, missing) as (boolean, any) -- cast: dynamic require probe
  print(ok)
  print(tostring(err):find("no .tl source found", 1, true) ~= nil)
  -- Output:
  -- false
  -- true
end

-- Suppress unused warnings for examples
local _ = {Example_install, Example_miss}
