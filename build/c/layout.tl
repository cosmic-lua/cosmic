--- The layout of this tree's own C, as Lua's own C lays itself out,
--- written back by `cosmic fix` the way it writes Teal back.
---
--- What the layout decides, and nothing else:
---
--- - A line that begins a statement, a declaration, a label, or an entry
---   of a braced initializer is indented two columns for every brace it
---   is inside; a line that closes a brace, one fewer.
--- - A line that continues the one before it keeps the columns its
---   author gave it, relative to that line: when a statement moves, what
---   continues it moves with it.
--- - A function defined or declared at file scope has a space between
---   its name and its parameters, `static int str_len (lua_State *L)`,
---   and a call never does, so a search for `^name (` finds definitions.
--- - No line ends in whitespace, a run of blank lines is at most two, and
---   the file ends in exactly one newline.
---
--- What it carries over untouched: where every line breaks, the spacing
--- inside a line past its indentation, every preprocessor directive, and
--- the text of every comment and literal (a comment spanning lines moves
--- with the line it starts on).
---
--- Only whitespace ever changes, so what comes out is checked against
--- what went in token for token (`same`), and a file that fails is left
--- as it was.

local record layout
end

--- One lexical piece of a C file. Every byte belongs to exactly one, so
--- joining them gives the file back.
local record Token
  --- "space", "newline", "comment", "directive", "literal", "word", or
  --- "punct".
  kind: string
  text: string
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
local function lex(s: string): {Token}
  local out: {Token} = {}
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

--- What a token says, whitespace aside: a comment's lines without their
--- indentation or trailing blanks, since moving a comment moves its lines.
local function meaning(t: Token): string
  if t.kind ~= "comment" then return t.text end
  local lines: {string} = {}
  for line in (t.text .. "\n"):gmatch("([^\n]*)\n") do
    lines[#lines + 1] = (line:gsub("^[ \t]+", ""):gsub("[ \t]+$", ""))
  end
  return table.concat(lines, "\n")
end

--- Whether `a` and `b` are the same C, whitespace aside: the same tokens,
--- in the same order, saying the same things. The first difference when
--- they are not.
function layout.same(a: string, b: string): boolean, string
  local function significant(s: string): {Token}
    local out: {Token} = {}
    for _, t in ipairs(lex(s)) do
      if t.kind ~= "space" and t.kind ~= "newline" then out[#out + 1] = t end
    end
    return out
  end
  local x, y = significant(a), significant(b)
  for i = 1, math.max(#x, #y) do
    local p, q = x[i], y[i]
    if p == nil or q == nil or p.kind ~= q.kind or meaning(p) ~= meaning(q) then
      return false, "token " .. i .. ": " .. (p and p.text or "<end>") .. " became " ..
        (q and q.text or "<end>")
    end
  end
  return true, ""
end

local keywords: {string: boolean} = {
  ["if"] = true, ["while"] = true, ["for"] = true, ["switch"] = true,
  ["return"] = true, ["sizeof"] = true, ["_Alignof"] = true, ["_Static_assert"] = true,
  ["__attribute__"] = true, ["_Generic"] = true, ["defined"] = true,
}

--- A line of tokens, with what the layout needs to know of it.
local record Line
  tokens: {Token}
  --- The tokens past the indentation that are neither space nor comment.
  code: {Token}
end

local function lines_of(tokens: {Token}): {Line}
  local out: {Line} = {}
  local current: Line = { tokens = {}, code = {} }
  for _, t in ipairs(tokens) do
    if t.kind == "newline" then
      out[#out + 1] = current
      current = { tokens = {}, code = {} }
    else
      current.tokens[#current.tokens + 1] = t
      if t.kind ~= "space" and t.kind ~= "comment" then
        current.code[#current.code + 1] = t
      end
    end
  end
  out[#out + 1] = current
  return out
end

--- The columns a run of indentation takes, a tab to the next multiple
--- of eight.
local function width(indent: string): integer
  local col = 0
  for c in indent:gmatch(".") do
    if c == "\t" then col = (col // 8 + 1) * 8 else col = col + 1 end
  end
  return col
end

--- Moves every line of a comment after its first by `delta` columns.
local function shifted(comment: string, delta: integer): string
  if delta == 0 or not comment:find("\n", 1, true) then return comment end
  return (comment:gsub("\n([ \t]*)", function(indent: string): string
    return "\n" .. string.rep(" ", math.max(width(indent) + delta, 0))
  end))
end

--- Whether the brace that `before` precedes opens a list of entries
--- rather than a block of statements. `cast` is what came before the `(`
--- that `before` closes, when it is a `)`: `= (struct t){` is a compound
--- literal's entries, `if (x) {` a block.
local function opens_entries(before: Token, before2: Token, cast: Token): boolean
  if before == nil then return false end
  local t = before.text
  if t == ")" then
    local c = cast ~= nil and cast.text or ""
    return c == "=" or c == "return" or c == "," or c == "("
  end
  if t == "=" or t == "," or t == "{" or t == "enum" or t == "(" then return true end
  if before.kind == "word" and before2 ~= nil and before2.text == "enum" then return true end
  return false
end

--- `source` laid out.
local function laid_out(source: string): string
  local tokens = lex(source)
  -- A definition's name, which takes a space before its parameters: at
  -- file scope, after a type, before a `(` whose close is followed by a
  -- body, a `;`, or an attribute.
  local spaced: {Token: boolean} = {}
  do
    local depth, parens = 0, 0
    local prev, prev2: Token, Token
    for i, t in ipairs(tokens) do
      if t.kind == "punct" or t.kind == "word" or t.kind == "literal" then
        if t.text == "{" then depth = depth + 1
        elseif t.text == "}" then depth = depth - 1
        elseif t.text == "(" then
          if depth == 0 and parens == 0 and prev ~= nil and prev.kind == "word"
              and not keywords[prev.text] and prev2 ~= nil
              and (prev2.kind == "word" or prev2.text == "*")
              and tokens[i - 1] == prev then
            -- Find the close, then what follows it.
            local level, j = 0, i
            while j <= #tokens do
              local u = tokens[j]
              if u.text == "(" then level = level + 1
              elseif u.text == ")" then
                level = level - 1
                if level == 0 then break end
              end
              j = j + 1
            end
            j = j + 1
            while tokens[j] ~= nil and (tokens[j].kind == "space" or tokens[j].kind == "newline"
                or tokens[j].kind == "comment") do
              j = j + 1
            end
            local after = tokens[j]
            if after ~= nil and (after.text == "{" or after.text == ";" or after.kind == "word") then
              spaced[prev] = true
            end
          end
          parens = parens + 1
        elseif t.text == ")" then parens = parens - 1
        end
        prev2, prev = prev, t
      end
    end
  end

  local out: {string} = {}
  local stack: {boolean} = {} -- true for a list of entries
  local parens = 0
  -- What came before each open parenthesis, and before the last closed.
  local opened: {Token} = {}
  local cast: Token
  local ends = true
  local delta = 0
  local blanks = 0
  local prev, prev2: Token, Token
  for _, line in ipairs(lines_of(tokens)) do
    local toks = line.tokens
    local first = 1
    local indent = ""
    if toks[1] ~= nil and toks[1].kind == "space" then
      indent = toks[1].text
      first = 2
    end
    if toks[first] == nil then
      blanks = blanks + 1
      if blanks <= 2 then out[#out + 1] = "" end
    else
      blanks = 0
      local lead = toks[first]
      local at: integer
      if lead.kind == "directive" then
        at = width(indent)
      elseif (ends and parens == 0) or line.code[1] == lead and lead.text == "}" then
        local depth = #stack
        if line.code[1] ~= nil and line.code[1].text == "}" and lead == line.code[1] then
          depth = depth - 1
        end
        at = 2 * math.max(depth, 0)
        delta = at - width(indent)
      else
        at = math.max(width(indent) + delta, 0)
      end
      local parts: {string} = { string.rep(" ", at) }
      for k = first, #toks do
        local t = toks[k]
        local text = t.text
        if t.kind == "comment" then text = shifted(text, at - width(indent)) end
        if spaced[t] and toks[k + 1] ~= nil and toks[k + 1].text == "(" then
          text = text .. " "
          -- What continues the parameters is lined up under them, unless
          -- they begin on a line of their own at an indent of their own.
          if line.code[#line.code] ~= toks[k + 1] then delta = delta + 1 end
        end
        parts[#parts + 1] = text
      end
      out[#out + 1] = (table.concat(parts):gsub("[ \t]+$", ""))

      if lead.kind ~= "directive" then
        local label = line.code[1] ~= nil
          and (line.code[1].text == "case" or line.code[1].text == "default")
        for _, t in ipairs(line.code) do
          if t.text == "{" then
            stack[#stack + 1] = opens_entries(prev, prev2, cast)
          elseif t.text == "}" then
            stack[#stack] = nil
          elseif t.text == "(" or t.text == "[" then
            parens = parens + 1
            opened[#opened + 1] = prev
          elseif t.text == ")" or t.text == "]" then
            parens = parens - 1
            cast = opened[#opened]
            opened[#opened] = nil
          end
          prev2, prev = prev, t
        end
        local last = line.code[#line.code]
        if last ~= nil then
          local v = last.text
          ends = v == ";" or v == "{" or v == "}"
            or (v == ":" and (label or #line.code == 2))
            or (v == "," and stack[#stack] == true and parens == 0)
        end
      end
    end
  end
  while out[#out] == "" do out[#out] = nil end
  return table.concat(out, "\n") .. "\n"
end

--- `source`, a C file, laid out; or nil and why, when the layout would
--- change more than whitespace or is not yet settled.
function layout.rendered(source: string): string | nil, string
  local out = laid_out(source)
  local same, difference = layout.same(source, out)
  if not same then
    return nil, "laying it out changed more than whitespace: " .. difference
  end
  if laid_out(out) ~= out then
    return nil, "laying it out is not a fixed point: a second pass changed it"
  end
  return out, ""
end

return layout
