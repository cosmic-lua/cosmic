--- Sources for the properties of the lexer ([`lang.lexer`]): bytes of every kind, and runs of pieces that reach
--- each branch of the lexer, with a `#!` first line now and then. Every property over lexed sources draws from here.
local Fuzz = require("build.fuzz")

local record Sources
  --- One source drawn from `src`: a quarter of them are raw bytes, the rest a run of pieces.
  source: function(src: Fuzz.Source): string
end

--- Pieces of source that reach every branch of the lexer, well and ill
--- formed, with the bytes around them that decide where they end.
local PIECES <const>: {string} = {
  "local", "function", "end", "goto", "continue", "match", "mut", "as", "is", "record", "x", "_y1", "Z9",
  "0", "12", "0xFF", "1e3", "2.5", ".5", "5.", "0x1p4", "1_000", "3x", "0x", "1e", "1..2", "9223372036854775808",
  "'a'", "\"b\"", "'", "\"", "'\\n'", "\"\\x41\"", "'\\u{20AC}'", "\"\\q\"", "'\\z  \n  x'", "'a\\\nb'", "'\\256'",
  "[[long]]", "[==[a]]b]==]", "[[", "[=[", "[=x", "[", "]", "]]",
  "-- note", "--[[ c ]]", "--[==[ c\n]==]", "--[[ c", "--[=", "---", "--#pragma",
  "+", "-", "*", "/", "//", "%", "^", "#", "&", "~", "~=", "|", "<<", ">>", "<", "<=", ">", ">=", "=", "==",
  "..", "...", ".", ":", "::", "::lbl::", ",", ";", "?", "(", ")", "{", "}",
  "@", "!", "!=", "`", "\\", "$", "\195\169", "\239\187\191", "\1", "\0",
  " ", "  ", "\t", "\n", "\n\n", "\r\n", "\n\r", "\r", "\v", "\f",
}

--- First lines that begin a source: with each line ending, and with nothing after the `#!` or no line ending.
local SHEBANGS <const>: {string} = { "#!/bin/cosmic\n", "#!x\r\n", "#!\r", "#!\n\n", "#!x\n\r", "#!" }

function Sources.source(src: Fuzz.Source): string
  if src:int(0, 3) == 0 then
    return Fuzz.bytes(src, 120)
  end
  local out: mut {string} = {}
  if src:int(0, 15) == 0 then
    local first = SHEBANGS[src:int(1, #SHEBANGS)]
    assert(first ~= nil, "a first line index is in range")
    out[#out + 1] = first
  end
  while Fuzz.more(src, #out, 40) do
    local piece = PIECES[src:int(1, #PIECES)]
    assert(piece ~= nil, "a piece index is in range")
    out[#out + 1] = piece
  end
  return table.concat(out)
end

return Sources
