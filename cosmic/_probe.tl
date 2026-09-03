--- Shared runtime capability probe: does a table carry a name its
--- declared type does not?
--- Internal to cosmic/ (leading underscore) — library code that needs
--- to test for a field a value's static type does not admit, without
--- requiring cosmic.check (its throw-on-failure assertions are not
--- library-legal outside test code).

--- Test whether `t` carries a non-nil value at `name`, regardless of
--- what `t`'s declared type says it has.
--- @param t any The table to probe
--- @param name string The field name to test for
--- @return boolean True if `t[name]` is present and non-nil
local function is_present(t: any, name: string): boolean
  -- cast: probe a table for a name its declared type may not carry
  return (t as {string: any})[name] ~= nil
end

local record ProbeModule
  is_present: function(t: any, name: string): boolean
end

local M: ProbeModule = {
  is_present = is_present,
}

return M
