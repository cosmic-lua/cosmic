#!/usr/bin/env cosmic
local lex = require("cosmic.template.lex")
local types = require("cosmic.template.types")

local function kinds(toks: {types.Token}): string
  local out: {string} = {}
  for _, t in ipairs(toks) do
    out[#out + 1] = t.kind
  end
  return table.concat(out, " ")
end

local function test_plain_text_with_no_actions()
  local toks, err = lex.lex("just text", "t")
  assert(toks, "expected tokens, got error: " .. tostring(err))
  assert(#toks == 1, "expected one token, got " .. #toks)
  assert(toks[1].kind == "text" and toks[1].value == "just text")
end

local function test_field_and_word_and_pipe()
  local toks, err = lex.lex("{{.a.b | pkg.func}}", "t")
  assert(toks, "expected tokens, got error: " .. tostring(err))
  assert(kinds(toks) == "open field pipe word close", kinds(toks))
  assert(toks[2].value == ".a.b", toks[2].value)
  assert(toks[4].value == "pkg.func", toks[4].value)
end

local function test_bare_dot_is_a_field_token()
  local toks, err = lex.lex("{{.}}", "t")
  assert(toks, "expected tokens, got error: " .. tostring(err))
  assert(toks[2].kind == "field" and toks[2].value == ".")
end

local function test_text_and_actions_interleave()
  local toks, err = lex.lex("a{{.x}}b{{.y}}c", "t")
  assert(toks, "expected tokens, got error: " .. tostring(err))
  assert(kinds(toks) == "text open field close text open field close text",
    kinds(toks))
  assert(toks[1].value == "a" and toks[5].value == "b" and toks[9].value == "c")
end

local function test_line_and_col_track_across_newlines()
  local toks, err = lex.lex("one\ntwo {{.x}}", "t")
  assert(toks, "expected tokens, got error: " .. tostring(err))
  local field: types.Token | nil = nil
  for _, t in ipairs(toks) do
    if t.kind == "field" then
      field = t
    end
  end
  assert(field, "expected a field token")
  assert(field.line == 2, "expected line 2, got " .. field.line)
  assert(field.col == 7, "expected col 7, got " .. field.col)
end

local function test_unterminated_action_is_an_error()
  local toks, err = lex.lex("{{.x", "t")
  assert(not toks, "expected an error for an unterminated action")
  assert(err:match("unterminated action"), "got: " .. err)
  assert(err:match("^t:1:"), "expected the template name and line, got: " .. err)
end

local function test_keyword_words_lex_like_any_other_word()
  -- lex.tl does not know keywords; parse.tl decides meaning from
  -- position, so "if"/"end"/"type" are ordinary "word" tokens here.
  local toks, err = lex.lex("{{if}}{{end}}", "t")
  assert(toks, "expected tokens, got error: " .. tostring(err))
  assert(toks[2].kind == "word" and toks[2].value == "if")
  assert(toks[5].kind == "word" and toks[5].value == "end")
end
