--- The names a wrong name may have meant, for a refusal that says what to write instead: [`lang.check`]'s of a field a
--- record does not have, and the driver's of a module there is none of ([`build.standard_meant`]).

local record NearNames
  --- At most this many members a refusal shows with their types, and this many more by name.
  TYPED: integer
  NAMED: integer
end

NearNames.TYPED = 4
NearNames.NAMED = 40

--- How far apart `a` and `b` are by edits, up to `limit`: `limit + 1` for more.
---
---     print(NearNames.distance("fz", "fs", 2)) -- 1
function NearNames.distance(a: string, b: string, limit: integer): integer
  if math.abs(#a - #b) > limit then return limit + 1 end
  local previous: mut {integer} = {}
  for j = 0, #b do previous[#previous + 1] = j end
  for i = 1, #a do
    local row: mut {integer} = { i }
    for j = 1, #b do
      local cost = if a:byte(i) == b:byte(j) then 0 else 1 end
      local best = math.min((previous[j] or 0) + cost, (previous[j + 1] or 0) + 1, (row[j] or 0) + 1)
      row[#row + 1] = best
    end
    previous = row
  end
  return previous[#b + 1] or (limit + 1)
end

--- The names of `names` that the unknown `name` may mean, beyond the one nearest it: those it begins with or that begin
--- with it (`read_file` with `read`, `parse` with `parse_date`), and those that share a part of four letters or more
--- with it, parts split at `_`; in the order of `names`.
---
---     print(table.concat(NearNames.related("read_file", { "open", "read", "write" }), " ")) -- read
function NearNames.related(name: string, names: {string}): {string}
  local function parts(s: string): {string: boolean}
    local out: mut {string: boolean} = {}
    for part in s:lower():gmatch("[^_]+") do
      if #part >= 4 then out[part] = true end
    end
    return out
  end
  local mine = parts(name)
  local out: mut {string} = {}
  for _, other in ipairs(names) do
    local shared = false
    for part in pairs(parts(other)) do
      if mine[part] == true then shared = true end
    end
    local begins = (#other >= 3 and name:sub(1, #other) == other) or (#name >= 3 and other:sub(1, #name) == name)
    if other ~= name and (begins or shared) then out[#out + 1] = other end
  end
  return out
end

--- `text` cut to at most `most` bytes, at a whole character, `...` at its end where it was longer.
---
---     print(NearNames.cut("abcdef", 5)) -- ab...
function NearNames.cut(text: string, most: integer): string
  if #text <= most then return text end
  local at = most - 3
  -- A byte 10xxxxxx continues a character: back up to the start of one.
  while at > 0 and (text:byte(at + 1) or 0) & 0xC0 == 0x80 do at = at - 1 end
  return text:sub(1, at) .. "..."
end

return NearNames
