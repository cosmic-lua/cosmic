--- Checks for the tests of [`build.fix.layout`]: a source laid out and held to what holds for any source (no token or
--- comment changes, the tree is the same, laying out what is laid out changes nothing), and the ways a test spoils
--- a laid-out source without changing what it means.
---
--- What a layout may change, and the checks leave out: the comma of a table that is added or dropped before its
--- `}`, and the break before a binary operator that begins a line, which the layout moves behind the operator.
--- What else it may change is the breaks: it takes none away, and adds one only before a token that
--- [`build.fix.breaks`] names, where a break alone leaves the tree of the source as it was.
local Ast = require("lang.ast")
local Blocks = require("build.fix.blocks")
local Breaks = require("build.fix.breaks")
local Continuation = require("build.fix.continuation")
local Dump = require("lang.ast_dump")
local Layout = require("build.fix.layout")
local Lexer = require("lang.lexer")
local Parser = require("lang.parser")
local Roles = require("build.fix.roles")
local Trivia = require("build.fix.trivia")

local record Check
  --- The line structure of `source`: for each token and for each comment whether a break lies before it and
  --- whether a blank line does, with the break before a binary operator that begins a line counted before the
  --- operand after it, where the layout puts it.
  breaks_of: function(source: string): string
  --- `source` laid out, which must succeed with the tokens, comments and tree of `source`, keep its line structure but
  --- for the breaks it adds (each before a token that [`build.fix.breaks`] names, and each alone leaving the tree as
  --- it was) and be a fixed point.
  laid: function(source: string): string
  --- Asserts that `source` is laid out as `want`.
  lays: function(source: string, want: string)
  --- Asserts that `source` is refused.
  refuses: function(source: string)
  --- `source` with the gap between each two neighbours on a line replaced by a draw of spaces and tabs, except
  --- inside a type, where the gap is the author's own.
  respaced: function(source: string, seed: integer): string
  --- `source` with the indentation of each line drawn again, except a line that continues a type (whose spacing is
  --- the author's); a comment on a line of its own gets that of the code after it, so it stays lined up. A comment
  --- past the last token is left as it is.
  reindented: function(source: string, seed: integer): string
  --- `source` with line breaks moved: some gaps on a line become a break and some breaks a space, each only where
  --- the tree stays the same. It parses the source once for each gap it moves, so it is for tiny sources.
  rebroken: function(source: string, seed: integer): string
  --- `source` with every break between two tokens made a space where the tree stays the same: the longest lines
  --- it can have. It parses the source once for each break, so it is for tiny sources.
  joined: function(source: string): string
end

--- The next pseudo-random number after `state`, in 0 to 2^31.
local function next_state(state: integer): integer
  return (state * 1103515245 + 12345) % 2147483648
end

--- A source lexed and parsed.
local record Parse
  parsed: Parser.Parsed
  lexed: Lexer.Lexed
end

--- The last few sources parsed, by text: a check reads the same text several times, and a parse is most of what a
--- check costs.
local parses: mut {string: Parse} = {}
local parse_order: mut {string} = {}

local function parsed_of(source: string): Parser.Parsed, Lexer.Lexed
  local held = parses[source]
  if held ~= nil then
    return held.parsed, held.lexed
  end
  local lexed = Lexer.lex(source, "f.tl")
  local parsed = Parser.parse(lexed, "f.tl", "tl")
  parses[source] = { parsed = parsed, lexed = lexed }
  parse_order[#parse_order + 1] = source
  if #parse_order > 4 then
    local old = table.remove(parse_order, 1)
    if old ~= nil then
      parses[old] = nil
    end
  end
  return parsed, lexed
end

--- Whether item `i` of `items` is a comma that a layout may add or drop: one on the line of the code before it, with
--- a `}` after it.
local function table_comma(items: {Trivia.Item}, i: integer): boolean
  local item = items[i]
  if item == nil or item.kind ~= "token" or item.text ~= "," or item.newlines > 0 then
    return false
  end
  for k = i + 1, #items do
    local after = items[k]
    if after ~= nil and after.kind ~= "comment" then
      return after.kind == "token" and after.text == "}"
    end
  end
  return false
end

--- The items of `items` that a layout moves forward: a binary operator that begins a line moves behind the code
--- before it unless a blank line is before it, or a comment ends its line and another lies between it and the code.
local function moved_of(items: {Trivia.Item}, operators: {integer: boolean}): {integer: boolean}
  local moved: mut {integer: boolean} = {}
  -- The comments since the last token, and whether the last of them is a trailing one.
  local between = 0
  local code = false
  for i, item in ipairs(items) do
    if item.kind == "comment" then
      between = between + 1
    elseif item.kind == "token" then
      local after = items[i + 1]
      local ends_operator = after ~= nil and after.kind == "comment" and after.trailing
      if operators[item.token] == true and item.newlines > 0 and not item.blank and code and
          not (ends_operator and between > 0) then
        moved[i] = true
      end
      between = 0
      code = true
    end
  end
  return moved
end

--- The tokens of `source` in order, each with its kind and text, and each comment with the number of tokens before
--- it and its text: a comment before an operator that a layout moves counts the operator among those before it, as
--- the layout writes it.
local function tokens_of(source: string): string
  local parsed, lexed = parsed_of(source)
  local items = Trivia.of(source, lexed.tokens).items
  local moved = moved_of(items, Continuation.of(parsed.chunk).operators)
  local tokens: mut {string} = {}
  local comments: mut {string} = {}
  for i, item in ipairs(items) do
    if item.kind == "comment" then
      -- The token the comment is kept on: the next one.
      local next_at = i + 1
      while items[next_at] ~= nil and (items[next_at] or item).kind == "comment" do
        next_at = next_at + 1
      end
      comments[#comments + 1] = string.format("%d:%s", #tokens + (if moved[next_at] == true then 1 else 0 end), item.text)
    elseif not table_comma(items, i) then
      tokens[#tokens + 1] = item.kind .. ":" .. item.text
    end
  end
  return table.concat(tokens, "\0") .. "\1" .. table.concat(comments, "\0")
end

--- The tree of `source` as text, without positions ([`lang.ast_dump`]); it asserts that `source` parses.
local function shape_of(source: string): string
  local parsed = parsed_of(source)
  local first = parsed.errors[1]
  if first ~= nil then
    error(string.format("%q does not parse: %s", source, first.msg))
  end
  return Dump.dump(parsed.chunk)
end

--- The line structure of one token or comment: whether a break lies before it (`n`) and whether a blank line does
--- (`b`), each `-` where not.
local record Flag
  --- The index of the token, 0 for a comment.
  token: integer
  flag: string
end

--- The flags of the tokens of `source` and of its comments, in order.
local function flags_of(source: string): {Flag}, {Flag}
  local parsed, lexed = parsed_of(source)
  local stream = Trivia.of(source, lexed.tokens)
  local items = stream.items
  local moved = moved_of(items, Continuation.of(parsed.chunk).operators)
  local tokens: mut {Flag} = {}
  local comments: mut {Flag} = {}
  -- Whether the operand after an operator that begins a line is to take its break.
  local owed = false
  for i, item in ipairs(items) do
    -- The end of the file is left out: whether a final break precedes it is the file's last newline. So are the
    -- breaks before the first item, which are dropped unless a `#!` line comes first.
    if item.kind ~= "eof" and (i > 1 or stream.shebang ~= nil) then
      local breaks = (item.newlines > 0 and moved[i] ~= true) or (owed and item.kind == "token")
      local flag = (if breaks then "n" else "-" end) .. (if item.blank then "b" else "-" end)
      if item.kind == "comment" then
        comments[#comments + 1] = { token = 0, flag = flag }
      elseif not table_comma(items, i) then
        tokens[#tokens + 1] = { token = item.token, flag = flag }
      end
      if item.kind == "token" then
        owed = moved[i] == true
      end
    end
  end
  return tokens, comments
end

function Check.breaks_of(source: string): string
  local tokens, comments = flags_of(source)
  local words: mut {string} = {}
  for _, one in ipairs(tokens) do
    words[#words + 1] = one.flag
  end
  local more: mut {string} = {}
  for _, one in ipairs(comments) do
    more[#more + 1] = one.flag
  end
  return table.concat(words, " ") .. "|" .. table.concat(more, " ")
end

--- `source` with a break in the gap before token `t`, which has none before it.
local function broken_before(source: string, t: integer): string
  local lexed = Lexer.lex(source, "f.tl")
  local before = Lexer.offset(lexed.tokens, t - 1) + #Lexer.text(lexed.tokens, t - 1)
  return source:sub(1, before - 1) .. "\n" .. source:sub(Lexer.offset(lexed.tokens, t))
end

--- Asserts that `got`, the layout of `source`, has the breaks of `source` and no others but the ones the plan of
--- [`build.fix.breaks`] allows, and that each of those alone leaves the tree of `source`.
local function breaks_added(source: string, got: string)
  local was_tokens, was_comments = flags_of(source)
  local now_tokens, now_comments = flags_of(got)
  --- Fails with `why` about `source` and its layout `got`.
  local function fail(why: string)
    error(string.format("%q: %s: %q", source, why, got))
  end
  if #was_tokens ~= #now_tokens or #was_comments ~= #now_comments then
    fail("lost a token or a comment")
  end
  for i, was in ipairs(was_comments) do
    if was.flag ~= (now_comments[i] or was).flag then
      fail("moved the break of a comment")
    end
  end
  local allowed = Breaks.candidates(Breaks.of(parsed_of(source).chunk))
  local want = shape_of(source)
  for i, was in ipairs(was_tokens) do
    local now = now_tokens[i] or was
    local had, has = was.flag:sub(1, 1) == "n", now.flag:sub(1, 1) == "n"
    if was.flag:sub(2) ~= now.flag:sub(2) then
      fail("changed a blank line")
    elseif had and not has then
      fail("lost a break")
    elseif has and not had then
      if allowed[was.token] ~= true then
        fail(string.format("added a break before token %d, which no rule asks for", was.token))
      end
      if shape_of(broken_before(source, was.token)) ~= want then
        fail(string.format("added a break before token %d, which changes the tree", was.token))
      end
    end
  end
end

function Check.laid(source: string): string
  local got, why = Layout.of(source, "f.tl")
  assert(got ~= nil, string.format("%q refused: %s", source, why))
  assert(tokens_of(got) == tokens_of(source), string.format("%q changed tokens: %q", source, got))
  assert(shape_of(got) == shape_of(source), string.format("%q changed the tree: %q", source, got))
  breaks_added(source, got)
  local again, _ = Layout.of(got, "f.tl")
  assert(again == got, string.format("%q is not a fixed point: %q then %q", source, got, tostring(again)))
  return got
end

function Check.lays(source: string, want: string)
  local got = Check.laid(source)
  assert(got == want, string.format("%q\n got %q\nwant %q", source, got, want))
end

function Check.refuses(source: string)
  local got, _ = Layout.of(source, "f.tl")
  assert(got == nil, string.format("%q was laid out as %q", source, tostring(got)))
end

--- For each token, the line on which the statement, member or value that holds it begins: that of the latest token
--- at its depth that begins one. The type of a token keeps the columns of its lines relative to that line, and so does
--- the body of a record, an interface or an enum, relative to the line of its declaration.
local function statement_lines(chunk: Ast.Chunk, roled: Roles.Roled): {integer}
  local tokens = chunk.tokens
  local levels = Blocks.of(chunk)
  local lines: mut {integer} = {}
  local at_depth: mut {integer: integer} = {}
  for i = 1, Lexer.count(tokens) do
    local depth = levels.depths[i] or 0
    if levels.starts[i] == true and levels.anchors[i] == nil then
      at_depth[depth] = Lexer.y(tokens, i)
    end
    local line = at_depth[depth] or Lexer.y(tokens, i)
    if Roles.in_body(roled, i) then
      line = at_depth[(levels.depths[Roles.region(roled, i)] or 1) - 1] or line
    end
    lines[#lines + 1] = line
  end
  return lines
end

local GAPS <const>: {string} = { " ", "  ", "\t", " \t ", "   " }

--- The indentation a line may begin with.
local MARGINS <const>: {string} = { "", " ", "    ", "\t", "      ", "\t\t" }

function Check.respaced(source: string, seed: integer): string
  local parsed, lexed = parsed_of(source)
  local roled = Roles.of(parsed.chunk)
  local bare = Continuation.of(parsed.chunk).bare
  local lines = statement_lines(parsed.chunk, roled)
  local stream = Trivia.of(source, lexed.tokens)
  local out: mut {string} = {}
  local state = seed
  if stream.shebang ~= nil then
    out[#out + 1] = stream.shebang
  end
  -- For each line whose indentation was dropped, how many bytes it had.
  local dropped: mut {integer: integer} = {}
  -- The token before the item, which is not a comment.
  local previous = 0
  for i, item in ipairs(stream.items) do
    local before = stream.items[i - 1]
    if item.kind ~= "eof" then
      local continues = item.kind == "token" and Roles.continues(roled, item.token, previous)
      if i == 1 then
        out[#out + 1] = if stream.shebang ~= nil then ("\n"):rep(item.newlines) else "" end
        dropped[item.y] = item.x - 1
      elseif before ~= nil and item.newlines == 0 and item.kind == "token" and before.kind == "token" and
          bare[item.token] == true and bare[before.token] == true then
        -- The author's spacing of the type parameters of a declaration.
        out[#out + 1] = source:sub(before.offset + #before.text, item.offset - 1)
      elseif continues and item.newlines == 0 and before ~= nil then
        out[#out + 1] = source:sub(before.offset + #before.text, item.offset - 1)
      elseif continues then
        -- The author's spacing of a type, the columns of its lines among it, taken in with the line its statement
        -- begins on.
        local by = dropped[lines[item.token] or 0] or 0
        out[#out + 1] = ("\n"):rep(item.newlines) .. (" "):rep(math.max(0, item.x - 1 - by))
      elseif item.newlines > 0 then
        out[#out + 1] = ("\n"):rep(item.newlines)
        dropped[item.y] = item.x - 1
      else
        state = next_state(state)
        out[#out + 1] = GAPS[state // 65536 % #GAPS + 1] or " "
      end
      out[#out + 1] = item.text
      if item.kind == "token" then
        previous = item.token
      end
    end
  end
  return table.concat(out)
end

function Check.reindented(source: string, seed: integer): string
  local parsed, lexed = parsed_of(source)
  local roled = Roles.of(parsed.chunk)
  local lines = statement_lines(parsed.chunk, roled)
  local stream = Trivia.of(source, lexed.tokens)
  local items = stream.items
  -- The margin of each item that begins a line, a comment's being that of the first token after it.
  local margins: mut {integer: string} = {}
  local state = seed
  local pending: mut {integer} = {}
  -- For each line a margin was drawn for, how many bytes longer it is than it was.
  local longer: mut {integer: integer} = {}
  -- The token before the item, which is not a comment.
  local previous = 0
  for i, item in ipairs(items) do
    if item.kind == "eof" then
      break
    end
    if i == 1 or item.newlines > 0 then
      local kept = false
      if item.kind == "token" then
        kept = Roles.continues(roled, item.token, previous)
      end
      if item.kind == "comment" then
        pending[#pending + 1] = i
      elseif kept then
        -- A line of a type moves with the line its statement begins on.
        local old = source:sub(item.offset - (item.x - 1), item.offset - 1)
        local by = longer[lines[item.token] or 0] or 0
        local margin = (" "):rep(math.max(0, #old + by))
        margins[i] = margin
        longer[item.y] = #margin - (item.x - 1)
        for _, comment in ipairs(pending) do
          margins[comment] = margin
        end
        pending = {}
      else
        state = next_state(state)
        local margin = MARGINS[state // 65536 % #MARGINS + 1] or ""
        margins[i] = margin
        if item.kind == "token" then
          longer[item.y] = #margin - (item.x - 1)
        end
        for _, comment in ipairs(pending) do
          margins[comment] = margin
        end
        pending = {}
      end
    end
    if item.kind == "token" then
      previous = item.token
    end
  end
  local out: mut {string} = {}
  if stream.shebang ~= nil then
    out[#out + 1] = stream.shebang
  end
  for i, item in ipairs(items) do
    local before = items[i - 1]
    if item.kind ~= "eof" then
      if before == nil then
        out[#out + 1] = if stream.shebang ~= nil then ("\n"):rep(item.newlines) else "" end
      elseif item.newlines > 0 then
        out[#out + 1] = ("\n"):rep(item.newlines)
      else
        out[#out + 1] = source:sub(before.offset + #before.text, item.offset - 1)
      end
      if before == nil or item.newlines > 0 then
        -- A comment with no token after it keeps the margin it had.
        out[#out + 1] = margins[i] or source:sub(item.offset - (item.x - 1), item.offset - 1)
      end
      out[#out + 1] = item.text
    end
  end
  return table.concat(out)
end

--- `source` with the gaps between its tokens that `chooses` toggled where the tree stays the same: a gap on a line
--- becomes a break, a single break becomes a space (only that, where `joining` is set).
local function toggled(source: string, chooses: function(item: Trivia.Item): boolean, joining: boolean): string
  local want = shape_of(source)
  local lexed = Lexer.lex(source, "f.tl")
  local stream = Trivia.of(source, lexed.tokens)
  local items = stream.items
  local shebang = stream.shebang
  -- For each gap between two tokens, the gap as it stands and whether it may change. A comment keeps its line, and
  -- so does the token after one.
  local gaps: mut {integer: string} = {}
  for i, item in ipairs(items) do
    local before = items[i - 1]
    if item.kind == "eof" or (i == 1 and shebang == nil) then
      gaps[i] = ""
    elseif item.newlines > 0 or before == nil then
      gaps[i] = ("\n"):rep(item.newlines)
    else
      gaps[i] = source:sub(before.offset + #before.text, item.offset - 1)
    end
  end
  local function built(): string
    local out: mut {string} = {}
    if shebang ~= nil then
      out[#out + 1] = shebang
    end
    for i, item in ipairs(items) do
      if item.kind ~= "eof" then
        out[#out + 1] = gaps[i] or ""
        out[#out + 1] = item.text
      end
    end
    return table.concat(out)
  end
  for i, item in ipairs(items) do
    local before = items[i - 1]
    if i > 1 and item.kind == "token" and before ~= nil and before.kind == "token" and chooses(item) then
      local kept = gaps[i] or ""
      if item.newlines == 0 and not joining then
        gaps[i] = "\n"
      elseif item.newlines == 1 then
        gaps[i] = " "
      end
      local text = built()
      local parsed = parsed_of(text)
      if parsed.errors[1] ~= nil or Dump.dump(parsed.chunk) ~= want then
        gaps[i] = kept
      end
    end
  end
  return built()
end

function Check.rebroken(source: string, seed: integer): string
  local state: mut {integer: integer} = { [1] = seed }
  return toggled(source, function(_: Trivia.Item): boolean
    local drawn = next_state(state[1] or seed)
    state[1] = drawn
    return drawn // 65536 % 3 == 0
  end, false)
end

function Check.joined(source: string): string
  return toggled(source, function(_: Trivia.Item): boolean
    return true
  end, true)
end

return Check
