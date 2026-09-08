--- Extra check selection flags live separately from the shipped Flags record.
--- The dispatcher resets this state for every invocation, including refusals.
local wanted = false

local function extract(name: string, words: {string}): {string} | nil, string
  wanted = false
  local out: {string} = {}
  for _, word in ipairs(words) do
    if word == "--changed" then
      if name ~= "check" then
        return nil, "make: --changed belongs to check"
      end
      wanted = true
    else
      out[#out + 1] = word
    end
  end
  if wanted and #out == 0 then
    wanted = false
    return nil, "make: check --changed needs changed paths (include deleted paths)"
  end
  return out
end

local function changed(): boolean return wanted end
local record ScopeModule
  extract: function(name: string, words: {string}): {string} | nil, string
  changed: function(): boolean
end
local M: ScopeModule = {extract = extract, changed = changed}
return M
