--- Fuzz property for the new checker's lexer ([`lang.lexer`]): for any
--- bytes it answers, its tokens and comments tile the
--- source, and every error lies in the source with a message and a fix
--- ([`lang.lexer_cover`]). `FUZZ_SEED` and `FUZZ_ITERS` pick the inputs
--- (build/fuzz/init.tl).
local Cover = require("lang.lexer_cover")
local Fuzz = require("build.fuzz")
local Lexer = require("lang.lexer")

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
  " ", "  ", "\t", "\n", "\n\n", "\r\n", "\r", "\v", "\f",
}

local function gen_source(src: Fuzz.Source): string
  if src:int(0, 3) == 0 then
    return Fuzz.bytes(src, 120)
  end
  local out: {string} = {}
  if src:int(0, 15) == 0 then
    out[1] = "#!/bin/cosmic\n"
  end
  while Fuzz.more(src, #out, 40) do
    out[#out + 1] = PIECES[src:int(1, #PIECES)]
  end
  return table.concat(out)
end

local function test_the_tokens_tile_the_source_and_every_error_says_how_to_fix_it(tmp: string)
  Fuzz.run({
    name = "lexer tiles any source",
    dir = tmp,
    gen = gen_source,
    check = function(input: string): boolean, string
      local lexed = Lexer.lex(input, "f.tl")
      local ok, why = Cover.check(input, lexed)
      if not ok then
        return false, why
      end
      Fuzz.label(#lexed.errors == 0 and "clean" or "refused")
      for _, e in ipairs(lexed.errors) do
        Fuzz.label(e.code)
      end
      return true, ""
    end,
    requires = { "clean", "refused", "label_or_goto", "bad_escape", "stray_byte", "unterminated_string", "long_comment" },
    shares = { clean = 0.01, refused = 0.3 },
  })
end

local function test_a_source_cut_at_any_byte_still_tiles()
  -- A source ended anywhere is a prefix of the source: the lexer reads to the
  -- end of its input and stops there, whatever token it was inside.
  local source = "local s = 'a\\u{41}' .. [==[x\ny]==] --[[ c ]] 0x1p4 goto next ::next:: @"
  for cut = 0, #source do
    local piece = source:sub(1, cut)
    local ok, why = Cover.check(piece, Lexer.lex(piece, "f.tl"))
    assert(ok, "cut at " .. cut .. ": " .. why)
  end
end
