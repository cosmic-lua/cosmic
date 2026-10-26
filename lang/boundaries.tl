--- The Lua kinds a value of a checker type may have: what a run-time check of a declared
--- boundary (a parameter, a return value or a field written) holds the value to.
---
--- [`Boundaries.kinds`] answers the kinds, and [`Boundaries.spec`] spells them as the
--- worker's `__cosmic_tc` reads them ([`build.test_worker`]): `type`'s names joined by "|",
--- and "integer" for a number that `math.type` says is one. The mapping:
---
--- * `integer`: "integer"; `number`: "number"
--- * `string`: "string"; an enum: "string", and its values in `strings`
--- * `boolean`, `true`, `false`: "boolean"
--- * `nil`, and a union that holds `nil`: "nil"
--- * an array, a map, a record, an interface, a declaration used as a value: "table"
--- * a class instance: "table", and its declaration in `classes`
--- * a userdata record: "userdata"
--- * a function: "function"
--- * a union: the kinds of its members
--- * `any`, a type variable, `invalid` and a union with one of them: no check
--- * `never`: no kind at all, since no value has the type
---
--- `nil` is a kind only where the type admits it. A recursive alias is read one level, as
--- [`Types.unfold`] does: `type Json = string | {Json}` is "string" or "table", and the
--- elements of the array go unchecked.

local Types = require("lang.types")

local record Boundaries
  --- What a value of a type may be.
  record Kinds
    --- The kinds, in one order whatever the type was: some of integer, number, string, boolean, table,
    --- function, userdata and nil. "integer" is left out where "number" is in.
    list: {string}
    --- The values of the enums the type's strings come from, sorted, where every string it admits is one of an
    --- enum's; nil where it admits a string of any text, or none.
    strings: {string}?
    --- The classes the type's tables are instances of, where every table it admits is an instance of one of them (the
    --- metatables `__fact` holds a table to); nil where any other table, a record's or an interface's, is admitted.
    classes: {Types.Decl}?
  end

  --- The kinds a value of `t` may have, or nil where the type says nothing of its value (`any`, a type variable,
  --- `invalid`, a union with one of them, or an alias with no body yet) and no check is made.
  kinds: function(t: Types.Type): Kinds?

  --- `kinds` as the worker reads a declared type: its kinds joined by "|", or "-" where nothing is checked.
  spec: function(kinds: Kinds?): string
end

local ORDER <const>: {string} = { "integer", "number", "string", "boolean", "table", "function", "userdata", "nil" }

-- A bound on the aliases looked through, which a store's aliases never reach: a body names an alias only inside an
-- array or a map.
local MAX_ALIASES <const> = 100

--- What the members of a type admit as it is read.
local record Seen
  found: mut {string: boolean}
  strings: mut {string}
  -- Whether a string of any text, or a table of any kind, is admitted.
  mut any_string: boolean
  mut other_table: boolean
  classes: mut {Types.Decl}
  mut unchecked: boolean
end

local function add(seen: Seen, t: Types.Type)
  local current = t
  for _ = 1, MAX_ALIASES do
    local next_type = Types.unfold(current)
    if next_type == current then
      break
    end
    current = next_type
  end
  if (current.tag == "named") and current.decl.kind == "alias" then
    -- An alias with no body yet.
    seen.unchecked = true
  elseif (current.tag == "union") then
    for _, member in ipairs(current.members) do
      add(seen, member)
    end
    if current.nilable then
      seen.found["nil"] = true
    end
  elseif current.tag == "integer" then
    seen.found["integer"] = true
  elseif current.tag == "number" then
    seen.found["number"] = true
  elseif current.tag == "string" then
    seen.found["string"] = true
    seen.any_string = true
  elseif current.tag == "boolean" or current.tag == "true" or current.tag == "false" then
    seen.found["boolean"] = true
  elseif current.tag == "nil" then
    seen.found["nil"] = true
  elseif current.tag == "fn" then
    seen.found["function"] = true
  elseif current.tag == "array" or current.tag == "map" then
    seen.found["table"] = true
    seen.other_table = true
  elseif (current.tag == "named") then
    local kind = current.decl.kind
    if kind == "enum" then
      seen.found["string"] = true
      local body = current.decl.body
      if body == nil then
        seen.any_string = true
      else
        for _, value in ipairs(body.values) do
          seen.strings[#seen.strings + 1] = value
        end
      end
    elseif kind == "userdata" then
      seen.found["userdata"] = true
    else
      seen.found["table"] = true
      if kind == "class" and not current.value then
        seen.classes[#seen.classes + 1] = current.decl
      else
        seen.other_table = true
      end
    end
  elseif current.tag == "never" then
    -- No value has the type, so it admits no kind.
    return
  else
    -- `any`, a variable or `invalid`.
    seen.unchecked = true
  end
end

function Boundaries.kinds(t: Types.Type): Boundaries.Kinds?
  local seen: Seen = { found = {}, strings = {}, any_string = false, other_table = false, classes = {}, unchecked = false }
  add(seen, t)
  if seen.unchecked then
    return nil
  end
  local list: mut {string} = {}
  for _, kind in ipairs(ORDER) do
    if seen.found[kind] == true and not (kind == "integer" and seen.found["number"] == true) then
      list[#list + 1] = kind
    end
  end
  local strings: {string}? = nil
  local classes: {Types.Decl}? = nil
  if seen.found["string"] == true and not seen.any_string then
    local values: mut {string} = {}
    local once: mut {string: boolean} = {}
    for _, value in ipairs(seen.strings) do
      if once[value] ~= true then
        once[value] = true
        values[#values + 1] = value
      end
    end
    table.sort(values)
    strings = values
  end
  if seen.found["table"] == true and not seen.other_table then
    local decls: mut {Types.Decl} = {}
    local once: mut {string: boolean} = {}
    for _, decl in ipairs(seen.classes) do
      if once[decl.text] ~= true then
        once[decl.text] = true
        decls[#decls + 1] = decl
      end
    end
    classes = decls
  end
  return { list = list, strings = strings, classes = classes }
end

function Boundaries.spec(kinds: Boundaries.Kinds?): string
  if kinds == nil then
    return "-"
  end
  return table.concat(kinds.list, "|")
end

-- TODO: once lang/codegen.tl writes a boundary check from the checker's list of declared parameters, returns and fields
-- (the next step of the boundary checks in doc/plans/strict-teal.md), call [`Boundaries.kinds`] and [`Boundaries.spec`]
-- there: nothing outside the tests calls them yet.

return Boundaries
