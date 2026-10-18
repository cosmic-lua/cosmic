--- `cosmic lsp`'s lines and positions ([`build.lsp.lines`]): a character
--- counted in UTF-16 units or in bytes, as the client and server agree.

local lines = require("build.lsp.lines")

local function test_a_position_counts_utf16_units_or_bytes()
  -- "😀" is four bytes and two UTF-16 units; byte 6 is the `x` after it.
  local held = lines.lines_of('a\r"😀x"\n')
  local wide = lines.position(held, 3 + 5, "utf-16")
  assert(wide.line == 1 and wide.character == 3, tostring(wide.line) .. ":" .. tostring(wide.character))
  local narrow = lines.position(held, 3 + 5, "utf-8")
  assert(narrow.character == 5, tostring(narrow.character))
  assert(lines.byte_of('"😀x"', 3, "utf-16") == 6)
end

local function test_the_checker_counts_lines_at_a_newline_alone()
  local starts = lines.checker_starts("a\r\nb\rc\n")
  assert(#starts == 3 and starts[2] == 4 and starts[3] == 8,
    tostring(#starts) .. ": " .. tostring(starts[2]) .. "," .. tostring(starts[3]))
end
