--- Fuzz property for the new checker's lexer ([`lang.lexer`]): for any
--- bytes it answers, its tokens and comments tile the
--- source, and every error lies in the source with a message and a fix
--- ([`lang.lexer_cover`]). `FUZZ_SEED` and `FUZZ_ITERS` pick the inputs
--- (build/fuzz/init.tl).
local Cover = require("lang.lexer_cover")
local Fuzz = require("build.fuzz")
local Lexer = require("lang.lexer")
local Sources = require("build.lexer_sources")

local function test_the_tokens_tile_the_source_and_every_error_says_how_to_fix_it(tmp: string)
  Fuzz.run({
    name = "lexer tiles any source",
    dir = tmp,
    gen = Sources.source,
    check = function(input: string): boolean, string
      local lexed = Lexer.lex(input, "f.tl")
      local ok, why = Cover.check(input, lexed)
      if not ok then
        return false, why
      end
      Fuzz.label(if #lexed.errors == 0 then "clean" else "refused" end)
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
