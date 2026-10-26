--- Checks for the tests of [`build.fix.layout`]: a source laid out and held to what holds for any source (no token or
--- comment changes, the tree is the same, laying out what is laid out changes nothing), and the ways a test spoils
--- a laid-out source without changing what it means.
local Dump = require("lang.ast_dump")
local Layout = require("build.fix.layout")
local Lexer = require("lang.lexer")
local Parser = require("lang.parser")
local Roles = require("build.fix.roles")
local Trivia = require("build.fix.trivia")

local record Check
  --- The line structure of `source`: for each item whether a break lies before it and whether a blank line does.
  breaks_of: function(source: string): string
  --- `source` laid out, which must succeed with the tokens, comments and tree of `source`, keep its line
  --- structure and be a fixed point.
  laid: function(source: string): string
  --- Asserts that `source` is laid out as `want`.
  lays: function(source: string, want: string)
  --- Asserts that `source` is refused.
  refuses: function(source: string)
  --- `source` with the gap between each two neighbours on a line replaced by a draw of spaces and tabs, except
  --- inside a type, where the gap is the author's own.
  respaced: function(source: string, seed: integer): string
  --- `source` with the indentation of each line drawn again; a comment on a line of its own gets that of the code
  --- after it, so it stays lined up. A comment past the last token is left as it is.
  reindented: function(source: string, seed: integer): string
  --- `source` with line breaks moved: some gaps on a line become a break and some breaks a space, each only where
  --- the tree stays the same.
  rebroken: function(source: string, seed: integer): string
end

--- The next pseudo-random number after `state`, in 0 to 2^31.
local function next_state(state: integer): integer
  return (state * 1103515245 + 12345) % 2147483648
end

local function parsed_of(source: string): Parser.Parsed, Lexer.Lexed
  local lexed = Lexer.lex(source, "f.tl")
  return Parser.parse(lexed, "f.tl", "tl"), lexed
end

--- The kind and text of each token and each comment of `source`, in order, as one string.
local function tokens_of(source: string): string
  local lexed = Lexer.lex(source, "f.tl")
  local out: mut {string} = {}
  for _, item in ipairs(Trivia.of(source, lexed.tokens).items) do
    out[#out + 1] = item.kind .. ":" .. item.text
  end
  return table.concat(out, "\0")
end

--- The tree of `source` as text, without positions ([`lang.ast_dump`]); it asserts that `source` parses.
local function shape_of(source: string): string
  local parsed = parsed_of(source)
  local first = parsed.errors[1]
  assert(first == nil, string.format("%q does not parse: %s", source, first and first.msg or ""))
  return Dump.dump(parsed.chunk)
end

function Check.breaks_of(source: string): string
  local lexed = Lexer.lex(source, "f.tl")
  local out: mut {string} = {}
  local stream = Trivia.of(source, lexed.tokens)
  for i, item in ipairs(stream.items) do
    -- The end of the file is left out: whether a final break precedes it is the file's last newline. So are the
    -- breaks before the first item, which are dropped unless a `#!` line comes first.
    if item.kind ~= "eof" and (i > 1 or stream.shebang ~= nil) then
      out[#out + 1] = (if item.newlines > 0 then "n" else "-" end) .. (if item.blank then "b" else "-" end)
    end
  end
  return table.concat(out, " ")
end

function Check.laid(source: string): string
  local got, why = Layout.of(source, "f.tl")
  assert(got ~= nil, string.format("%q refused: %s", source, why))
  assert(tokens_of(got) == tokens_of(source), string.format("%q changed tokens: %q", source, got))
  assert(shape_of(got) == shape_of(source), string.format("%q changed the tree: %q", source, got))
  assert(Check.breaks_of(got) == Check.breaks_of(source), string.format("%q moved a break: %q", source, got))
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

local GAPS <const>: {string} = { " ", "  ", "\t", " \t ", "   " }

--- The indentation a line may begin with.
local MARGINS <const>: {string} = { "", " ", "    ", "\t", "      ", "\t\t" }

function Check.respaced(source: string, seed: integer): string
  local parsed, lexed = parsed_of(source)
  local roled = Roles.of(parsed.chunk)
  local stream = Trivia.of(source, lexed.tokens)
  local out: mut {string} = {}
  local state = seed
  if stream.shebang ~= nil then
    out[#out + 1] = stream.shebang
  end
  for i, item in ipairs(stream.items) do
    local before = stream.items[i - 1]
    if item.kind ~= "eof" then
      if i == 1 then
        out[#out + 1] = if stream.shebang ~= nil then ("\n"):rep(item.newlines) else "" end
      elseif item.newlines > 0 then
        out[#out + 1] = ("\n"):rep(item.newlines)
      elseif before ~= nil and before.kind == "token" and item.kind == "token" and
          roled.regions[item.token] ~= 0 and roled.regions[item.token] == roled.regions[before.token] then
        out[#out + 1] = source:sub(before.offset + #before.text, item.offset - 1)
      else
        state = next_state(state)
        out[#out + 1] = GAPS[state // 65536 % #GAPS + 1] or " "
      end
      out[#out + 1] = item.text
    end
  end
  return table.concat(out)
end

function Check.reindented(source: string, seed: integer): string
  local lexed = Lexer.lex(source, "f.tl")
  local stream = Trivia.of(source, lexed.tokens)
  local items = stream.items
  -- The margin of each item that begins a line, a comment's being that of the first token after it.
  local margins: mut {integer: string} = {}
  local state = seed
  local pending: mut {integer} = {}
  for i, item in ipairs(items) do
    if item.kind == "eof" then
      break
    end
    if i == 1 or item.newlines > 0 then
      if item.kind == "comment" then
        pending[#pending + 1] = i
      else
        state = next_state(state)
        local margin = MARGINS[state // 65536 % #MARGINS + 1] or ""
        margins[i] = margin
        for _, comment in ipairs(pending) do
          margins[comment] = margin
        end
        pending = {}
      end
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

function Check.rebroken(source: string, seed: integer): string
  local want = shape_of(source)
  local lexed = Lexer.lex(source, "f.tl")
  local stream = Trivia.of(source, lexed.tokens)
  local items = stream.items
  local shebang = stream.shebang
  -- For each gap between two tokens, the gap as it stands and whether it may change: a gap on a line may become a
  -- break, and a single break a space. A comment keeps its line, and so does the token after one.
  local gaps: mut {integer: string} = {}
  local state = seed
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
    if i > 1 and item.kind == "token" and before ~= nil and before.kind == "token" then
      state = next_state(state)
      if state // 65536 % 3 == 0 then
        local kept = gaps[i] or ""
        if item.newlines == 0 then
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
  end
  return built()
end

return Check
