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
--- * an array, a map, a record, a declaration used as a value: "table"
--- * an interface: "table" and "userdata", since a userdata record may implement one
--- * a class instance: "table", and its declaration in `classes`
--- * a userdata record: "userdata"
--- * a function: "function"
--- * a union: the kinds of its members
--- * `any`, a type variable, `invalid`, a union with one of them, and the stdlib's `Coroutine` and `Yielder` (threads at
---   run time): no check
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

-- The userdata records of lang/stdlib.d.tl that are no userdata at run time: a coroutine is a thread, and the handle a
-- body yields through is taken for one. No kind of ours is a thread's, so a boundary typed with one is not checked.
local THREADS <const>: {string: boolean} = { Coroutine = true, Yielder = true }

--- What the members of a type admit as it is read.
local record Seen
  found: mut {string: boolean}
  strings: mut {string}
  -- Whether a string of any text, or a table of any kind, is admitted.
  mut any_string: boolean
  mut other_table: boolean
  classes: mut {Types.Decl}
  mut unchecked: boolean
  -- The aliases read, by path, so that aliases that reach each other through their unions are read once.
  visited: mut {string: boolean}
end

local function add(seen: Seen, t: Types.Type)
  local current = t
  if (current.tag == "named") and current.decl.kind == "alias" then
    if seen.visited[current.decl.text] == true then
      return
    end
    seen.visited[current.decl.text] = true
    local body = Types.unfold(current)
    if body == current then
      -- An alias with no body yet.
      seen.unchecked = true
    else
      add(seen, body)
    end
    return
  end
  if (current.tag == "union") then
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
    elseif kind == "userdata" and not current.value and #current.decl.names == 1 and
        THREADS[current.decl.name] == true then
      seen.unchecked = true
    elseif kind == "userdata" and not current.value then
      seen.found["userdata"] = true
    else
      seen.found["table"] = true
      -- A userdata record may implement an interface, so a value of one is also a userdata.
      if kind == "interface" then
        seen.found["userdata"] = true
      end
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
  local seen: Seen = { found = {}, strings = {}, any_string = false, other_table = false, classes = {}, unchecked = false, visited = {} }
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

-- TODO: give `Coroutine` and `Yielder` a kind of their own ("thread") once lang/stdlib.d.tl declares a thread type: they
-- are userdata records there and threads at run time, so a boundary typed with one is not checked.
-- TODO: once the checker lists the declared returns and fields written as well (the next step of the boundary checks), have [`lang.boundary_checks`] call [`Boundaries.kinds`] and [`Boundaries.spec`] for them as it
-- does for a parameter: only the parameters of a function are checked so far.

return Boundaries
