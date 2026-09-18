--- The trust gate around the raw debug table cosmic.coverage wraps:
--- nobody ever gets it by naming it directly, and a load that is not
--- handed the trusted `extra` table falls through to that same failing
--- name, exactly like `cosmic.store`/`cosmic.sqlite` do today.

local Store = require("cosmic.store")

local function test_internal_debug_not_reachable_by_name()
  local ok = pcall(require, "cosmic.internal.debug")
  assert(not ok, "cosmic.internal.debug must never resolve by name")
end

local function test_untrusted_load_cannot_reach_raw_debug()
  local bytes, trouble = Store.bytecode("cosmic.coverage")
  assert(bytes ~= nil, tostring(trouble))
  local chunk, load_trouble = load(bytes, "@cosmic.coverage", "b")
  assert(chunk ~= nil, tostring(load_trouble))
  -- Called the way an untrusted loader hands a module its `extra`
  -- argument -- anything but a table -- cosmic.coverage must fall
  -- through to `require("cosmic.internal.debug")` by name, which
  -- never resolves (see test_internal_debug_not_reachable_by_name
  -- above), so the module itself fails to load rather than handing
  -- back a working raw debug table.
  local ok = pcall(chunk, "cosmic.coverage", "not a table")
  assert(not ok, "an untrusted load must not obtain a working raw debug table")
end
