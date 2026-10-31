--- What a checked test run ([`doc/testing.md`]'s "run-time type checks")
--- met while a function ran: a test of a declaration asks it whether a
--- value crossed a typed boundary as a kind its type does not admit.
--- A checked compile writes the checks of a function's typed parameters ([`lang.boundary_checks`]) but not yet of a returned
--- value or a field written, so a test using this skips in every run, checked or not.

-- TODO: once the checker lists each declared return and field write and lang/codegen.tl writes a check for it in a checked
-- compile (doc/plans/strict-teal.md), make [`skip_reason`] answer nothing for a checked run: until then a checked run
-- meets violations of parameters alone (rows of kind "parameter", which `during` already reads), and the tests that ask
-- `during` would pass having checked a part of what they are about. `__fact` ([`lang.fact_wraps`]) carries narrowed reads
-- only, not the declared kind of a value crossing a boundary.
local Test = require("cosmic.test")
local Globals = require("cosmic.internal.globals")
local worker = require("build.test_worker")

local record TypeWatch
end

--- Whether this run compiled the run-time checks in.
function TypeWatch.checked(): boolean
  -- The hook a checked run defines as a global; read by a chunk, since the
  -- global is no field of the checker's `_G`.
  local read = assert(load("return __cosmic_tc", "=type_watch", "t", Globals.table()))
  return (read()) ~= nil
end

--- Why `during` skips the test, for a run that `checked` says is checked or
--- not: a plain run carries no checks at all, and a checked run carries only
--- those of narrowed reads, not of declared boundaries.
function TypeWatch.skip_reason(checked: boolean): string
  if not checked then
    return "run with --check-types: only a checked run carries the type checks"
  end
  return "boundary checks are not compiled in: a checked run writes a check at a declared parameter but not at a return or " ..
    "field write, so this test would pass having checked a part of what it is about (see the TODO in build/type_watch.tl)"
end

--- The violations of a boundary declared under `under` (the standard
--- library, "cosmic/", by default) met while `fn` ran, bar a value left out
--- of a failure pair's later slot, each as `kind target: declared, got
--- actual (at place)`; skips the test in every run for now, since none
--- compiles the checks of returns and fields in ([`skip_reason`]).
function TypeWatch.during(fn: function(), under?: string): {string}
  Test.skip(TypeWatch.skip_reason(TypeWatch.checked()))
  local prefix = under or "cosmic/"
  local before: mut {string:integer} = {}
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
  local found: mut {string} = {}
  for _, each in ipairs(worker.violations()) do
    -- A success that answers its value alone, where the declaration adds
    -- the reason a failure gives, answers nothing in a later slot: the
    -- failure idiom of doc/design.md, not a lie. A first slot left out
    -- (a bare `return`) is one.
    if not (each.actual == "absent" and each.target ~= "return value 1") and declared_under(each) and each.count > (before[key(each)] or 0) then
      found[#found + 1] = ("%s %s: declared %s, got %s (at %s)"):format(each.kind, each.target,
        each.declared, each.actual, each.at)
    end
  end
  return found
end

return TypeWatch
