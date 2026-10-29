--- Which of the violations a checked run ([`build.test`]) met fail it. The hook raises at the first violation of a
--- parameter declared under cosmic/ ([`build.test_worker`]), which fails the test that met it; a `pcall` in the code
--- under test can swallow that raise, so the run fails for the row the hook kept all the same.
local record TypeViolations
  --- One distinct violation, by what it is and where, with the first test that met it.
  record Row
    kind: string
    at: string
    target: string
    declared: string
    actual: string
    test: string
  end

  --- The first row of `rows` that is a parameter declared under cosmic/, as a line naming it and the test, or "". A
  --- parameter of a listed fixture file met by the test that owns it is skipped: the hook's own tests declare
  --- those on purpose, to be violated.
  library: function(rows: {Row}): string
end

--- The fixture files the hook's tests declare parameters in on purpose, by the module of the one test that owns each. A
--- file not listed here, or a listed one met by another test, is not exempt.
local FIXTURES <const>: {string: string} = {
  ["cosmic/boundary_hook_fake.tl"] = "build.boundary_hook_test",
  ["cosmic/type_violations_fake.tl"] = "build.type_violations_test",
}

--- Whether `met` is a parameter of a fixture, met by the test that owns the fixture.
local function fixture(met: TypeViolations.Row): boolean
  for file, owner in pairs(FIXTURES) do
    if met.target:find("(" .. file .. ":", 1, true) ~= nil and met.test:sub(1, #owner + 1) == owner .. " " then
      return true
    end
  end
  return false
end

function TypeViolations.library(rows: {TypeViolations.Row}): string
  for _, met in ipairs(rows) do
    -- A parameter's target names where it is declared, in parentheses.
    if met.kind == "parameter" and met.target:find("(cosmic/", 1, true) ~= nil and not fixture(met) then
      return string.format("type violation: %s: %s declared %s, got %s (met by %s)", met.at, met.target, met.declared,
        met.actual, met.test)
    end
  end
  return ""
end

return TypeViolations
