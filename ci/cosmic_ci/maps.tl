--- Copies of string maps. A collection a call answers is a view in the
--- new checker, so a caller that writes to one builds its own with `with`.

local record Maps
end

--- A new map holding the entries of `base`, then those of `extra`: an
--- entry of `extra` replaces the one of `base` under its name.
function Maps.with(base: {string:string}, extra: {string:string}): {string:string}
  local out: mut {string:string} = {}
  for name, value in pairs(base) do out[name] = value end
  for name, value in pairs(extra) do out[name] = value end
  return out
end

--- A new map holding the entries of `base` but those under `names`.
function Maps.without(base: {string:string}, names: {string}): {string:string}
  local gone: mut {string:boolean} = {}
  for _, name in ipairs(names) do gone[name] = true end
  local out: mut {string:string} = {}
  for name, value in pairs(base) do
    if gone[name] ~= true then out[name] = value end
  end
  return out
end

return Maps
