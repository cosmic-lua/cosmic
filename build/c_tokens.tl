--- The tokens of this tree's own C, as [`build.c.layout`] lays them out
--- and [`build.link_files`] reads links from their comments. Every byte
--- of a file belongs to exactly one token.

local record c_tokens
  --- One lexical piece of a C file. Every byte belongs to exactly one, so
  --- joining them gives the file back.
  record Token
    --- "space", "newline", "comment", "directive", "literal", "word", or
    --- "punct".
    kind: string
    text: string
  end

  --- One comment of a C file and the line it starts on.
  record Comment
    line: integer
    text: string
  end
end

local puncts: {string} = {
  "<<=", ">>=", "...", "->", "++", "--", "<<", ">>", "<=", ">=", "==", "!=",
  "&&", "||", "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "##",
}

--- The end of the directive that starts at `at`: the line, and every
--- line a trailing backslash joins to it.
local function directive_end(s: string, at: integer): integer
  local i = at
  while true do
    local nl = s:find("\n", i, true)
    if nl == nil then return #s end
    if s:sub(nl - 1, nl - 1) ~= "\\" then return nl - 1 end
    i = nl + 1
  end
end

--- The end of the quoted literal that opens at `at`.
local function literal_end(s: string, at: integer): integer
  local quote = s:sub(at, at)
  local i = at + 1
  while i <= #s do
    local c = s:sub(i, i)
    if c == "\\" then
      i = i + 2
    elseif c == quote or c == "\n" then
      return i
    else
      i = i + 1
    end
  end
  return #s
end

--- Every token of `s`, in order.
function c_tokens.lex(s: string): {c_tokens.Token}
  local out: {c_tokens.Token} = {}
  local i = 1
  local line_start = true
  while i <= #s do
    local c = s:sub(i, i)
    local stop: integer
    local kind: string
    if line_start and s:match("^[ \t]*#", i) then
      local hash = s:find("#", i, true)
      if hash > i then
        out[#out + 1] = { kind = "space", text = s:sub(i, hash - 1) }
      end
      i = hash
      stop, kind = directive_end(s, i), "directive"
    elseif c == "\n" then
      stop, kind = i, "newline"
    elseif c == " " or c == "\t" then
      stop, kind = (s:find("[^ \t]", i) or #s + 1) - 1, "space"
    elseif s:sub(i, i + 1) == "/*" then
      local close = s:find("*/", i + 2, true)
      stop, kind = close ~= nil and close + 1 or #s, "comment"
    elseif s:sub(i, i + 1) == "//" then
      stop, kind = (s:find("\n", i, true) or #s + 1) - 1, "comment"
    elseif c == "\"" or c == "'" then
      stop, kind = literal_end(s, i), "literal"
    elseif c:match("[%a_]") then
      stop, kind = (s:find("[^%w_]", i) or #s + 1) - 1, "word"
    elseif c:match("%d") or (c == "." and s:sub(i + 1, i + 1):match("%d")) then
      local j = i + 1
      while j <= #s do
        local d = s:sub(j, j)
        if d:match("[%w_.]") then
          j = j + 1
        elseif (d == "+" or d == "-") and s:sub(j - 1, j - 1):match("[eEpP]") then
          j = j + 1
        else
          break
        end
      end
      stop, kind = j - 1, "word"
    else
      stop, kind = i, "punct"
      for _, p in ipairs(puncts) do
        if s:sub(i, i + #p - 1) == p then
          stop = i + #p - 1
          break
        end
      end
    end
    out[#out + 1] = { kind = kind, text = s:sub(i, stop) }
    line_start = kind == "newline" or (line_start and kind == "space")
    i = stop + 1
  end
  return out
end

--- Every comment of `s`, `//` or `/* */`, markers and all, with the
--- line it starts on.
function c_tokens.comments(s: string): {c_tokens.Comment}
  local out: {c_tokens.Comment} = {}
  local line = 1
  for _, t in ipairs(c_tokens.lex(s)) do
    if t.kind == "comment" then
      out[#out + 1] = { line = line, text = t.text }
    end
    local _, breaks = t.text:gsub("\n", "")
    line = line + breaks
  end
  return out
end

return c_tokens
