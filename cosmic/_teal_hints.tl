--- Fix-hints for known Teal type-check error patterns.
---
--- Split from `cosmic.teal` for room: teal.tl sits at the file-length
--- limit, and this is the part that grows — every recurring trap that
--- costs edit-check cycles earns a pattern here. The hints ride along
--- wherever errors are formatted (`--check types`, `--compile`, the
--- script runner), so this module must stay requireable from all of
--- them: message matching only, no compiler state.
---
--- Matches the most common traps:
---   1. got number, expected integer (string index/length requires integer)
---   2. X | nil used un-narrowed: passed where X is expected, indexed,
---      or looped over — truthiness (`if not x`) narrows a nil union
---      (the carried tl patch, 3p/tl/tl_patch.tl), but `assert(x)` and
---      `== nil` comparisons do not, and nothing else tells the author
---   3. excess return values (multiple returns captured incorrectly)
---   4. <any type> operations (ipairs, index, concat on any)

--- Return a fix-hint line for a known error message, or nil.
--- @param msg string The error message to match
--- @return string|nil A short hint string, or nil if no hint applies
local function hint_for_message(msg: string): string | nil
  -- Pattern 1: number/integer mismatch
  if msg:find("got number, expected integer") then
    return "  hint: annotate the variable `: number`, or convert with math.tointeger; integer is required for string indices/lengths"
  end
  -- Pattern 1b: a local declared `= nil` with no annotation. Its type
  -- is inferred as nil FOREVER — every later assignment and comparison
  -- fails, no guard helps, and nothing in either message says the
  -- declaration is the problem. Two shapes: assigning into it, and
  -- using it as an operand. The `| nil` exclusion keeps the operand
  -- shape off honest unions, which are narrowing problems, not
  -- declaration problems.
  local nil_operand = (msg:match("for types .+ and nil$") ~= nil
    or msg:find("for types nil and", 1, true) ~= nil)
  and not msg:find("| nil", 1, true)
  if msg:match("in assignment: got .+, expected nil$") or nil_operand then
    return "  hint: a local declared `= nil` without a type annotation has type nil forever — annotate the optional (`local x: integer | nil = nil`) — see `cosmic --docs guide.checking`"
  end
  -- Pattern 2: nil union not narrowed (X | nil where X expected)
  if msg:find("%| nil") and msg:find("expected") then
    return "  hint: narrow first: `if v is Rec then ... end` (plain-table records), or cast after a guard for userdata handles — see `cosmic --docs guide.checking`"
  end
  -- Pattern 2b: indexing through an un-narrowed nil union. Truthiness
  -- (`if x`, `if not x then return end`) narrows a nil union since the
  -- carried tl patch (3p/tl/tl_patch.tl), so what lands here is the
  -- shapes that still do not narrow: `assert(x)` and `== nil` /
  -- `~= nil` comparisons, which newcomers expect to narrow.
  if msg:find("cannot index") and msg:find("| nil", 1, true) then
    return "  hint: `assert(x)` and `== nil` comparisons do not narrow `T | nil` — guard with truthiness (`if not x then return end`), branch with `if x is T then ... end`, or cast (`local v = x as T`) — see `cosmic --docs guide.checking`"
  end
  -- Pattern 2c: for-in over a value the checker cannot call. The message
  -- names no type, and the usual cause is an iterator still `T | nil`
  -- from a fallible call.
  if msg:find("for loop does not return an iterator", 1, true) then
    return "  hint: often the iterator is still `T | nil` from a fallible call: guard with truthiness (`if not it then return end`) before the loop — `assert(it)` does not narrow — see `cosmic --docs guide.checking`"
  end
  -- Pattern 2d: naming another module's type that is not exported. A
  -- standalone top-level record is file-local; importers can only name
  -- types nested in (or aliased into) the module's interface record.
  if msg:find("unknown type %w+%.%w+") then
    return "  hint: a type other files use must be nested in the module's interface record (`record StoreModule record Task ... end end`), or aliased in with `type Task = Task` — see `cosmic --docs guide.checking`"
  end
  -- Pattern 2e: colon-calling a name the value's record does not
  -- declare. Also fires on a plain typo, so the hint covers both.
  if msg:find("invalid key '[%w_]+' in record") then
    return "  hint: the value's record type does not declare this key — check the spelling; and a function on your MODULE's record is dot-called with the value first (`store.add(db, ...)`), never colon-called (`db:add(...)`) — see `cosmic --docs guide.gotchas`"
  end
  -- Pattern 3: excess return values (wrong number of returns)
  if msg:find("excess return values") then
    return "  hint: capture multiple returns first: `local v, err = f(...)`"
  end
  -- Pattern 4a: ipairs on a nil union or on any — different fixes: a
  -- `{T} | nil` needs narrowing, a plain `any` needs a cast.
  if msg:find("attempting ipairs on something that's not an array") then
    if msg:find("| nil", 1, true) then
      return "  hint: `assert(xs)` does not narrow `{T} | nil` — guard with truthiness (`if not xs then return end`), branch with `is`, or cast (`local xs = v as {T}`) — see `cosmic --docs guide.checking`"
    end
    return "  hint: cast first, e.g. `local items = data as {any}`"
  end
  -- Pattern 4b: concat with any type
  if msg:find("cannot use operator '%.%.'") and msg:find("<any type>") then
    return "  hint: cast first, e.g. `local s = val as string`"
  end
  -- Pattern 4c: index on any type
  if msg:find("cannot index") and msg:find("<any type>") then
    return "  hint: cast first, e.g. `local obj = val as {string: any}`"
  end
  return nil
end

local record TealHintsModule
  hint_for_message: function(msg: string): string | nil
end

local M: TealHintsModule = {
  hint_for_message = hint_for_message,
}

return M
