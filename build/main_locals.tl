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
  --- nil, as for `lua` that does not compile, or that Lua refuses for another reason than too many locals (such as too many
  --- registers). One load answers the common case.
  over: function(lua: string, limit: integer): integer?
end

--- Lua's limit on the locals of a function.
local LIMIT <const> = 200

--- Whether Lua's words `trouble` are the refusal for too many locals, and no other (a chunk that needs too many registers is
--- refused in other words, and the locals in front of it can be what brings that on).
local function crowded(trouble: string): boolean
  return trouble:find("too many local variables", 1, true) ~= nil
end

--- The locals the main chunk of `lua` holds, found by the most that fit in front of it; nil where it does not compile
--- alone. A refusal that is no word of too many locals is taken as a fit: it is the registers, not the locals, that ran out.
local function count(lua: string): integer?
  local alone, _ = LuaTail.fits_with(lua, 0)
  if not alone then
    return nil
  end
  local low, high = 0, LIMIT
  while low < high do
    local middle = (low + high + 1) // 2
    local fits, trouble = LuaTail.fits_with(lua, middle)
    if fits or not crowded(trouble) then
      low = middle
    else
      high = middle - 1
    end
  end
  return LIMIT - low
end

function MainLocals.over(lua: string, limit: integer): integer?
  local fits, trouble = LuaTail.fits_with(lua, LIMIT - limit)
  -- A refusal for registers is no count of locals: it is left alone, and so is a chunk Lua refuses on its own.
  if fits or not crowded(trouble) then
    return nil
  end
  local held = count(lua)
  if held ~= nil and held > limit then
    return held
  end
  return nil
end

return MainLocals
