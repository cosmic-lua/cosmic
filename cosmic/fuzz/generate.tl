--- Byte generators driven by an explicit recording source.
local source = require("cosmic.fuzz.source")
local function bytes(src: source.Recorder, max_len: integer): string
  if max_len < 1 then
    return ""
  end
  local n = src:int(0, max_len)
  local out: {string} = {}
  for i = 1, n do
    out[i] = string.char(src:int(0, 255))
  end
  return table.concat(out)
end

--- Mutate a sample by applying random single-byte edits.
--- Each edit is a flip, an insert or a delete, chosen uniformly; an edit
--- on an empty string is always an insert, so every edit changes the
--- string.
--- @param src source.Recorder The source to draw from
--- @param sample string The string to mutate
--- @param edits integer How many edits to apply
--- @return string The mutated string
local function mutate(src: source.Recorder, sample: string, edits: integer): string
  local out = sample
  for _ = 1, edits do
    local n = #out
    local kind = src:int(1, 3)
    if n == 0 then
      kind = 2
    end
    if kind == 1 then
      local pos = src:int(1, n)
      out = out:sub(1, pos - 1) .. string.char(src:int(0, 255)) .. out:sub(pos + 1)
    elseif kind == 2 then
      local pos = src:int(1, n + 1)
      out = out:sub(1, pos - 1) .. string.char(src:int(0, 255)) .. out:sub(pos)
    else
      local pos = src:int(1, n)
      out = out:sub(1, pos - 1) .. out:sub(pos + 1)
    end
  end
  return out
end

return {bytes = bytes, mutate = mutate}
