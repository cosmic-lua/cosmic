--- What a checked test run ([`doc/testing.md`]'s "run-time type checks")
--- met while a function ran: a test of a declaration asks it whether a
--- value crossed a typed boundary as a kind its type does not admit.
--- Only a checked run (`cosmic test --check-types`) compiles the checks
--- in, so a test using this skips in any other.

local Test = require("cosmic.test")
local worker = require("build.test_worker")

local record TypeWatch
end

--- Whether this run compiled the run-time checks in.
function TypeWatch.checked(): boolean
  -- The hook a checked run defines as a global; read by a chunk, since the
  -- global is no field of the checker's `_G`.
  local read = assert(load("return __cosmic_tc", "=type_watch", "t"))
  return (read()) ~= nil
end

--- The violations of a boundary declared under `under` (the standard
--- library, "cosmic/", by default) met while `fn` ran, bar a value left out
--- of a failure pair's later slot, each as `kind target: declared, got
--- actual (at place)`; skips the test in a run that carries no checks.
function TypeWatch.during(fn: function(), under?: string): {string}
  if not TypeWatch.checked() then
    Test.skip("run with --check-types: only a checked run carries the type checks")
  end
  local prefix = under or "cosmic/"
  local before: {string:integer} = {}
  -- A parameter is declared where its target names, in parentheses; a
  -- return value or a field is declared where it is sent.
  local function declared_under(each: worker.Violation): boolean
    if each.kind == "parameter" then return each.target:find("(" .. prefix, 1, true) ~= nil end
    return each.at:sub(1, #prefix) == prefix
  end
  local function key(each: worker.Violation): string
    return each.kind .. "\0" .. each.at .. "\0" .. each.target .. "\0" .. each.actual
  end
  for _, each in ipairs(worker.violations()) do before[key(each)] = each.count end
  fn()
  local found: {string} = {}
  for _, each in ipairs(worker.violations()) do
    -- A success that answers its value alone, where the declaration adds
    -- the reason a failure gives, answers nothing in that slot: the
    -- failure idiom of doc/design.md, not a lie.
    if each.actual ~= "absent" and declared_under(each) and each.count > (before[key(each)] or 0) then
      found[#found + 1] = ("%s %s: declared %s, got %s (at %s)"):format(each.kind, each.target,
        each.declared, each.actual, each.at)
    end
  end
  return found
end

return TypeWatch
