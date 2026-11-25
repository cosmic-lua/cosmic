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

--- The type `text` cut to at most `most` bytes, where it is longer, with its returns kept: a function type keeps its
--- first parameters whole and writes `...` for the rest; any other type is cut at its end, as [`NearNames.cut`] does.
---
---     print(NearNames.cut_signature("function(path: string, mode: integer): string", 35)) -- function(path: string, ...): string
function NearNames.cut_signature(text: string, most: integer): string
  if #text <= most then return text end
  if text:sub(1, 1) == "(" and text:sub(-2) == ")?" then
    return "(" .. NearNames.cut_signature(text:sub(2, -3), most - 3) .. ")?"
  end
  local open = text:find("(", 1, true)
  if text:sub(1, 8) ~= "function" or open == nil then return NearNames.cut(text, most) end
  -- The parameters at depth 0 of the list `open` begins, each ending at its `,` or at the list's `)`.
  local ends: mut {integer} = {}
  local close: integer? = nil
  local depth = 0
  for i = open + 1, #text do
    local c = text:sub(i, i)
    if c == "(" or c == "{" or c == "<" then
      depth = depth + 1
    elseif depth > 0 and (c == ")" or c == "}" or c == ">") then
      depth = depth - 1
    elseif depth == 0 and c == "," then
      ends[#ends + 1] = i - 1
    elseif depth == 0 and c == ")" then
      close = i
      break
    end
  end
  if close == nil then return NearNames.cut(text, most) end
  local tail = text:sub(close)
  local kept = open
  for _, e in ipairs(ends) do
    if e + #", ..." + #tail <= most then kept = e end
  end
  local head = text:sub(1, kept) .. (if kept > open then ", ..." else "..." end)
  if #head + #tail > most then return NearNames.cut(text, most) end
  return head .. tail
end

return NearNames
