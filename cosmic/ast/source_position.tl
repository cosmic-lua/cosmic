--- Byte positions shared by source snapshot indexes.
local record Range
  start_byte: integer
  end_byte: integer
end

local function line_starts(text: string): {integer}
  local starts: {integer} = {1}
  local at = 1
  while true do
    local nl = text:find("\n", at, true)
    if not nl then break end
    starts[#starts + 1] = nl + 1
    at = nl + 1
  end
  return starts
end

local function offset(starts: {integer}, line: integer, column: integer,
    source_end: integer): integer
  local start = starts[line]
  if not start then return source_end end
  return math.min(start + math.max(column, 1) - 1, source_end)
end

local function from_positions(starts: {integer}, source_end: integer,
    y: integer, x: integer, yend: integer, xend: integer): Range
  return {
    start_byte = offset(starts, y, x, source_end),
    end_byte = math.min(offset(starts, yend, xend, source_end) + 1, source_end),
  }
end

local record PositionModule
  type Range = Range
  line_starts: function(text: string): {integer}
  offset: function(starts: {integer}, line: integer, column: integer,
  source_end: integer): integer
  from_positions: function(starts: {integer}, source_end: integer,
  y: integer, x: integer, yend: integer, xend: integer): Range
end

local M: PositionModule = {
  line_starts = line_starts,
  offset = offset,
  from_positions = from_positions,
}
return M
