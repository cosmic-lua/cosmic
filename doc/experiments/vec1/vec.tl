--- Model-free vectors: the hashing trick over features, L2-normalised,
--- packed as vec1 wants them.
local Vec = {}

local function fnv(s: string): integer
  local h = 2166136261
  for i = 1, #s do
    h = ((h ~ s:byte(i)) * 16777619) & 0xffffffff
  end
  return h
end

--- A bag of features into `dim` float32s.
function Vec.pack(features: {string: number}, dim: integer): string
  local v: {number} = {}
  for i = 1, dim do v[i] = 0 end
  for f, w in pairs(features) do
    local h = fnv(f)
    local slot = h % dim + 1
    local sign = ((h >> 16) & 1) == 1 and 1 or -1
    v[slot] = v[slot] + sign * w
  end
  local norm = 0.0
  for i = 1, dim do norm = norm + v[i] * v[i] end
  norm = math.sqrt(norm)
  if norm > 0 then for i = 1, dim do v[i] = v[i] / norm end end
  return string.pack("=" .. string.rep("f", dim), table.unpack(v))
end

local stop: {string: boolean} = {}
for w in ("the a an of to and or is in it its on for by be as at that this with from not no when once which what are into than then there their so if but one"):
     gmatch("%a+") do stop[w] = true end

--- Words (lowercased, stopwords out, sublinear counts) and word bigrams.
function Vec.text(s: string): {string: number}
  local f: {string: number} = {}
  local prev: string = nil
  for raw in s:lower():gmatch("[%w_%.]+") do
    local w = raw:gsub("^%.+", ""):gsub("%.+$", "")
    if #w > 1 and not stop[w] then
      f["w:" .. w] = (f["w:" .. w] or 0) + 1
      if prev then f["b:" .. prev .. " " .. w] = (f["b:" .. prev .. " " .. w] or 0) + 1 end
      prev = w
    end
  end
  for k, n in pairs(f) do f[k] = 1 + math.log(n) end
  return f
end

return Vec
