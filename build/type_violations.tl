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

  --- The first row of `rows` that is a parameter declared under cosmic/, as a line naming it and the test, or "".
  library: function(rows: {Row}): string
end

function TypeViolations.library(rows: {TypeViolations.Row}): string
  for _, met in ipairs(rows) do
    -- A parameter's target names where it is declared, in parentheses.
    if met.kind == "parameter" and met.target:find("(cosmic/", 1, true) ~= nil then
      return string.format("type violation: %s: %s declared %s, got %s (met by %s)", met.at, met.target, met.declared,
        met.actual, met.test)
    end
  end
  return ""
end

return TypeViolations
