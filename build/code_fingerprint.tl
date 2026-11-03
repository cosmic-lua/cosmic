--- The tokens of a source with its comments and layout taken away, and a digest of them: what the identities of the code that
--- reads and checks hash in place of the source ([`build.code_walk`] holds the walks).
---
--- A comment, a blank line, an indent or a line break moves nothing the code does, so the identities of the code that reads
--- a source ([`build.pipeline`]'s `coded`, [`build.importer`]'s `analyzer_identity` and `receivers_identity`, [`build.work`]'s
--- links finder) hash [`CodeFingerprint.normal`] and not the source, and an edit to a comment or to the layout of a module
--- they walk moves no compile or parse key. Everything else moves them: the text of every token, a string's and a number's
--- among them, as written.
---
--- A comment does not reach what a compile or a parse stores. The Lua of a module has none, so what the code does is all of
--- its tokens. What a compile keeps is the Lua and bytecode of a module and the record-field uses in it ([`build.work`]'s
--- `compiled` and `typed_refs`), each at a position of the module's own source, and what a parse keeps is rows of the
--- module's own text (its docs, uses, places and links), so both are keyed by that source too. A message the checker or a
--- reader raises is never kept, nor is a refusal, which is printed and caches nothing, so no stored row holds a line of the
--- code that read it.

local Hash = require("cosmic.hash")
local Lexer = require("lang.lexer")

local record CodeFingerprint
  --- The tokens of `source`, the text of each exactly as written, with a line break between two where the second begins on a
  --- later line than the first ends and a space where it does not. The module is `name` in what is said of a source that
  --- does not lex. The result is itself a source that lexes to the same tokens on the same breaks, so it is its own normal
  --- form: `normal(normal(s)) == normal(s)`. That is what lets a test's pure store ([`build.closure_store`]) keep this in
  --- place of a walked module's source, and the identity come out as it does of the source.
  ---
  --- The parser gives a line break meaning (a `(` that begins a line is not a call of the token before it, and `match` and
  --- `continue` are names or words by their line), so the breaks between tokens are part of the form, and joining two lines
  --- or splitting one moves it. A comment (the grammar has only line comments), a blank line and an indent are no break
  --- between tokens and move nothing. (The parser's recovery from an error reads columns, so an indent can change what a
  --- source that does not parse reports; such a source is refused and never kept.)
  ---
  --- A space ends a token whichever two meet, and one inside a token (a string, a long string) is part of that token, which the lexer reads whole, so two sources have one form only if they have the same
  --- tokens on the same breaks. Raises, with the first error of the lexer, where `source` does not lex: a source that is no
  --- code is no module to name, and a digest of what is left of it would name two sources alike.
  normal: function(source: string, name: string): string

  --- The hex SHA-256 of [`CodeFingerprint.normal`] of `source`, under the version of this form. Where `source` does not lex it
  --- is the hex SHA-256 of the source itself under another prefix, and does not raise: an identity over a module with a
  --- syntax error must still be taken, so that the compile refuses the module with the lexer's `file:line:col`. Such a digest
  --- names no build, since a refused compile is never kept, and moves with any byte of the source.
  of: function(source: string, name: string): string
end

--- The prefix of the digest of a source that does not lex ([`CodeFingerprint.of`]), which no digest of tokens carries.
local unlexed <const> = "code-fingerprint-unlexed"

--- The version of the form; a change to what `normal` writes moves every digest.
local form <const> = "code-fingerprint-2"

--- The normal forms made in this process, by source. A test's process writes the pure store of each closure that declares a
--- walk, and the identities are taken more than once, so each source is read once.
local record Remembered
  mut forms: mut {string:string}
  mut count: integer
end

local remembered: Remembered = { forms = {}, count = 0 }

--- The most sources `remembered` holds before it starts over.
local LIMIT <const> = 1024

function CodeFingerprint.normal(source: string, name: string): string
  local held = remembered.forms[source]
  if held ~= nil then return held end
  local lexed = Lexer.lex(source, name)
  local first = lexed.errors[1]
  if first ~= nil then
    error("code-fingerprint: " .. name .. " does not lex: " .. first.msg, 0)
  end
  local texts: mut {string} = {}
  local ended = 0
  for i = 1, Lexer.count(lexed.tokens) do
    local text = Lexer.text(lexed.tokens, i)
    -- Only the `$EOF$` token has no text.
    if text ~= "" then
      if #texts > 0 then
        texts[#texts + 1] = if Lexer.y(lexed.tokens, i) > ended then "\n" else " " end
      end
      texts[#texts + 1] = text
      ended = Lexer.yend(lexed.tokens, i)
    end
  end
  local made = table.concat(texts)
  if remembered.count >= LIMIT then
    remembered.forms, remembered.count = {}, 0
  end
  remembered.forms[source] = made
  remembered.count = remembered.count + 1
  return made
end

function CodeFingerprint.of(source: string, name: string): string
  local box: mut {string} = {}
  local ok, _ = pcall(function()
    box[1] = CodeFingerprint.normal(source, name)
  end)
  local made = box[1]
  if not ok or made == nil then
    -- A source that does not lex has no tokens to name. It is the source that names it, so the compile goes on and refuses
    -- the module with the position of the error, which a raise here would hide; a refused compile is never kept.
    return Hash.hex_sha256(unlexed .. "\n" .. source)
  end
  return Hash.hex_sha256(form .. "\n" .. made)
end

return CodeFingerprint
