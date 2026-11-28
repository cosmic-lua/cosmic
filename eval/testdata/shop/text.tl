--- Helpers for laying out text in columns.

local record Text
end

--- `s` with spaces before it, to `width` bytes; `s` itself where it is that long already.
function Text.pad_left(s: string, width: integer): string
  if #s >= width then return s end
  return string.rep(" ", width - #s) .. s
end

--- `s` with spaces after it, to `width` bytes; `s` itself where it is that long already.
function Text.pad_right(s: string, width: integer): string
  if #s >= width then return s end
  return s .. string.rep(" ", width - #s)
end

--- `s` in the middle of `width` bytes, the odd space after it. A receipt could
--- use it for its title; see [`Text.pad_left`] for a column.
function Text.center(s: string, width: integer): string
  if #s >= width then return s end
  local before = (width - #s) // 2
  return string.rep(" ", before) .. s .. string.rep(" ", width - #s - before)
end

return Text
