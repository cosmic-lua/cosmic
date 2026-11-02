--- The locals the main chunk of a module's Lua holds at its most, which [`build.pipeline_check`] keeps under a limit. Lua
--- gives a function 200 local variables, and the main chunk of a module is one: a file at the limit builds alone and fails
--- once two changes that each add a top-level local are merged, so the limit it is held to leaves room.
---
--- The count is Lua's own, of the Lua [`lang.codegen`] writes, and not a reading of the Teal: which locals the generator
--- writes (a class table, an import read as a value, a `<const>` Lua folds) is its choice, so the chunk is probed. It is
--- loaded with `n` locals in front, and the most `n` it takes is what the limit leaves over what the chunk holds ([`build.lua_tail`]'s `fits_with`).
--- Nothing runs: a chunk is compiled and dropped.
local LuaTail = require("build.lua_tail")

local record MainLocals
  --- The most locals the main chunk of `lua` holds at one point, nested blocks included, if that is more than `limit`; else
  --- nil, as for `lua` that does not compile. One load answers the common case.
  over: function(lua: string, limit: integer): integer?
end

--- Lua's limit on the locals of a function.
local LIMIT <const> = 200

local function count(lua: string): integer?
  if not LuaTail.fits_with(lua, 0) then
    return nil
  end
  -- The greatest n that fits is the limit less the chunk's locals: search for it.
  local low, high = 0, LIMIT
  while low < high do
    local middle = (low + high + 1) // 2
    if LuaTail.fits_with(lua, middle) then
      low = middle
    else
      high = middle - 1
    end
  end
  return LIMIT - low
end

function MainLocals.over(lua: string, limit: integer): integer?
  if LuaTail.fits_with(lua, LIMIT - limit) then
    return nil
  end
  local held = count(lua)
  if held ~= nil and held > limit then
    return held
  end
  return nil
end

return MainLocals
