--- The new lexer against the fork's `lex` ([`build.teal`]) over some of the
--- tree's own files: where the new one finds no error, it makes the same
--- tokens of the same kind, at the same places, with the same comments before
--- them. What the tree reads of a token today therefore reads the new
--- tokens. They differ in two ways only: the `$EOF$` token's text, which the
--- fork spells `$EOF$`, and a word the grammar reserves ([`lang.lexer`]'s
--- `added`), which is a `keyword` here and an `identifier` in the fork.
local Fs = require("cosmic.fs")
local Lexer = require("lang.lexer")
local teal = require("build.teal")
local Test = require("cosmic.test")

-- The directories compared; the fork lexes about 5 MB a second, so these
-- stay small.
Test.policy{
  grants = {
    { path = "core/", letters = "r" },
    { path = "eval/", letters = "r" },
    { path = "lang/", letters = "r" },
  },
}

local built = assert(teal.load())

local ADDED: {string: boolean} = {}
for _, word in ipairs(Lexer.added) do
  ADDED[word] = true
end

--- The first way the new lexer's answer for `source` differs from the
--- fork's, or "".
local function difference(source: string, path: string): string
  local mine = Lexer.lex(source, path)
  if #mine.errors > 0 then
    return ""
  end
  local theirs = built.lex(source, path)
  if Lexer.count(mine.tokens) ~= #theirs then
    return path .. ": " .. Lexer.count(mine.tokens) .. " tokens, the fork's " .. #theirs
  end
  for i = 1, Lexer.count(mine.tokens) do
    local token = Lexer.token(mine.tokens, i)
    local other = theirs[i]
    if token.kind ~= "$EOF$" and token.text ~= other.tk then
      return path .. ": token " .. i .. " is `" .. token.text .. "`, the fork's `" .. other.tk .. "`"
    end
    local kind = tostring(token.kind)
    if kind ~= other.kind and not (kind == "keyword" and other.kind == "identifier" and ADDED[token.text]) then
      return path .. ": token " .. i .. " (`" .. token.text .. "`) is " .. kind .. ", the fork's " .. other.kind
    end
    if token.y ~= other.y or token.x ~= other.x then
      return path .. ": token " .. i .. " is at " .. token.y .. ":" .. token.x .. ", the fork's " .. other.y .. ":" .. other.x
    end
    local comments, other_comments = token.comments or {}, other.comments or {}
    if #comments ~= #other_comments then
      return path .. ": token " .. i .. " has " .. #comments .. " comments, the fork's " .. #other_comments
    end
    for k, comment in ipairs(comments) do
      local same = other_comments[k]
      if comment.text ~= same.text or comment.y ~= same.y or comment.x ~= same.x then
        return path .. ": comment " .. k .. " of token " .. i .. " differs"
      end
    end
  end
  return ""
end

local function compare(dir: string)
  local found = assert(Fs.walk(dir))
  local compared = 0
  for _, relative in ipairs(found) do
    if relative:match("%.tl$") then
      local path = dir .. "/" .. relative
      local source = assert(Fs.read(path))
      local why = difference(source, path)
      assert(why == "", why)
      compared = compared + 1
    end
  end
  assert(compared > 0, dir .. " holds no .tl file")
end

local function test_core_tokens_are_the_forks()
  compare("core")
end

local function test_eval_tokens_are_the_forks()
  compare("eval")
end

local function test_lang_tokens_are_the_forks()
  compare("lang")
end
