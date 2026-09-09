--- Extra check selection flags live separately from the shipped Flags record.
--- The dispatcher resets this state for every invocation, including refusals.
local fs = require("cosmic.fs")
local wanted = false
local report_path: string | nil

local function extract(name: string, words: {string}): {string} | nil, string
  wanted = false
  report_path = nil
  local out: {string} = {}
  local i = 1
  while i <= #words do
    local word = words[i]
    if word == "--changed" then
      if name ~= "check" then
        return nil, "make: --changed belongs to check"
      end
      wanted = true
    elseif word == "--report" then
      local path = words[i + 1]
      if name ~= "check" or not path or path:sub(1, 1) == "-" then
        return nil, "make: check --report needs an output path"
      end
      report_path = fs.absolute_path(path)
      i = i + 1
    else
      out[#out + 1] = word
    end
    i = i + 1
  end
  if wanted and #out == 0 then
    wanted = false
    return nil, "make: check --changed needs changed paths (include deleted paths)"
  end
  return out
end

local function changed(): boolean return wanted end
local function report(): string | nil return report_path end
local record ScopeModule
  extract: function(name: string, words: {string}): {string} | nil, string
  changed: function(): boolean
  report: function(): string | nil
end
local M: ScopeModule = {extract = extract, changed = changed, report = report}
return M
