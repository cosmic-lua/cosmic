--- Compact formatting for uncovered coverage lines.

--- Format sorted line numbers as compact ranges, e.g. "3-5,9,12-14".
--- @param lines {integer} Sorted line numbers
--- @param max_ranges integer Truncate after this many ranges
--- @return string
local function format_ranges(lines: {integer}, max_ranges: integer): string
  local parts: {string} = {}
  local first: integer = nil
  local last: integer = nil
  local hidden = 0
  local function flush()
    if not first then
      return
    end
    if #parts < max_ranges then
      if first == last then
        parts[#parts + 1] = tostring(first)
      else
        parts[#parts + 1] = first .. "-" .. last
      end
    else
      hidden = hidden + 1
    end
  end
  for _, line in ipairs(lines) do
    if last and line == last + 1 then
      last = line
    else
      flush()
      first = line
      last = line
    end
  end
  flush()
  local out = table.concat(parts, ",")
  if hidden > 0 then
    out = out .. " +" .. hidden .. " more"
  end
  return out
end

local record GapsModule
  format_ranges: function(lines: {integer}, max_ranges: integer): string
end

local M: GapsModule = {
  format_ranges = format_ranges,
}

return M
