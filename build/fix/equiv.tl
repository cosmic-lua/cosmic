--- Whether two Teal sources mean the same: the check that stands between the layout of [`build.fix.layout`] and a file
--- written to disk. A layout that passes the golden cases but loses a token, moves a comment across code, or changes
--- what the parser reads would be found here, on the file it is laid out on, and the file left as it was.
---
--- Two sources are the same when all of these hold:
--- - the tokens, in order, are the same (kind and bytes), but for the comma a table ends with, written before its `}`
---   or not (which the tree says: the token before the `}` that closes a `Table`);
--- - the comments are the same, in order, byte for byte, and each follows the same number of tokens. One that lay
---   before a binary operator that began a line follows the operator once the layout moves it behind the code before
---   it, so that one more token may precede it there;
--- - each comment that is part of a doc comment (the run of comments on the lines just before the first token of a
---   declaration, as [`lang.parser`] reads it) still is, and no other becomes one, so that a layout that parted a doc
---   comment from its declaration, or joined a comment to one, is found;
--- - the syntax tree is the same ([`lang.ast_dump`]: the kind and fields of every node, none of the places);
--- - the `#!` line is the same.
---
--- What the sources hold of whitespace, blank lines and breaks is the layout's to change. This check reads nothing of it.
local Ast = require("lang.ast")
local Dump = require("lang.ast_dump")
local Lexer = require("lang.lexer")
local Parser = require("lang.parser")
local plural = require("build.plural")

local record Equiv
  --- A comment of a source: its bytes, and the number of the tokens (the trailing commas of tables not counted) that
  --- come before it.
  record Remark
    text: string
    before: integer
    --- The token it is kept on, the first after it.
    on: integer
    --- Whether it is part of the doc comment of the node that begins at the token it is kept on.
    doc: boolean
    y: integer
    x: integer
  end

  --- What is compared of a source.
  record Side
    --- The first lexical or syntax error, worded `name:line:column: message`; "" when there is none.
    trouble: string
    shebang: string?
    tokens: Lexer.Tokens
    --- The numbers of the tokens that count: all but the trailing commas of tables.
    mut kept: {integer}
    mut comments: {Remark}
    --- The binary operators, by token.
    mut operators: {integer: boolean}
    --- The tree without places ([`lang.ast_dump`]); "" when the source does not parse.
    mut shape: string
  end

  --- What `source` is compared by, as the dialect `dialect` reads it: `name` is the file it is the text of, for
  --- the words of an error.
  read: function(source: string, name: string, dialect: Ast.Dialect): Side

  --- Why `after` is not the same as `before`, or nil when it is. `before` must parse; an `after` that does not is
  --- a difference.
  difference: function(before: Side, after: Side): string?
end

--- The kinds of node that [`lang.parser`] reads a doc comment for: the comments just before their first token.
local DOCUMENTED <const>: {string: boolean} = {
  Local = true, LocalFunction = true, Function = true, Record = true, Interface = true, Class = true, Enum = true,
  Alias = true, Import = true, FieldDecl = true, Method = true, EnumValue = true,
}

--- The comments kept on token `i` that are its doc comment, as [`lang.parser`] reads one: the run on the lines just
--- before the token, each on a line of its own and not at the end of a line of code. The first of them is the
--- number returned, the count of comments if there is none.
local function doc_start(tokens: Lexer.Tokens, i: integer, comments: {Lexer.Comment}): integer
  local line = Lexer.y(tokens, i) - 1
  local floor = if i > 1 then Lexer.yend(tokens, i - 1) else 0 end
  local from = #comments + 1
  for k = #comments, 1, -1 do
    local comment = comments[k]
    if comment == nil or comment.y ~= line or comment.y <= floor then
      break
    end
    from = k
    line = line - 1
  end
  return from
end

function Equiv.read(source: string, name: string, dialect: Ast.Dialect): Equiv.Side
  local lexed = Lexer.lex(source, name)
  local parsed = Parser.parse(lexed, name, dialect)
  local tokens = lexed.tokens
  local count = Lexer.count(tokens)
  local trouble = ""
  local first = parsed.errors[1]
  if first ~= nil then
    trouble = string.format("%s:%d:%d: %s", name, first.y, first.x, first.msg)
  end
  local shebang: string? = nil
  if source:sub(1, 2) == "#!" then
    shebang = source:sub(1, (source:find("[\r\n]", 3) or #source + 1) - 1)
  end
  local side: Equiv.Side = {
    trouble = trouble, shebang = shebang, tokens = tokens, kept = {}, comments = {}, operators = {}, shape = "",
  }
  if first ~= nil then
    return side
  end

  local dropped: mut {integer: boolean} = {}
  local operators: mut {integer: boolean} = {}
  local documented: mut {integer: boolean} = {}
  local queue: mut {Ast.Node} = { parsed.chunk }
  for _, node in ipairs(queue) do
    local kids: mut {Ast.Node} = {}
    Ast.children(node, function(child: Ast.Node)
      kids[#kids + 1] = child
      queue[#queue + 1] = child
    end)
    local head = kids[1]
    if DOCUMENTED[node.kind] == true then
      documented[node.first] = true
    end
    if node.kind == "Table" and node.last > node.first + 1 and Lexer.text(tokens, node.last - 1) == "," then
      dropped[node.last - 1] = true
    elseif node.kind == "Binary" and head ~= nil then
      operators[head.last + 1] = true
    end
  end

  local kept: mut {integer} = {}
  local comments: mut {Equiv.Remark} = {}
  for i = 1, count do
    local here = tokens.comments[i] or {}
    local from = if documented[i] == true then doc_start(tokens, i, here) else #here + 1 end
    for k, comment in ipairs(here) do
      comments[#comments + 1] = {
        text = comment.text, before = #kept, on = i, doc = k >= from, y = comment.y, x = comment.x,
      }
    end
    if dropped[i] ~= true then
      kept[#kept + 1] = i
    end
  end
  side.kept = kept
  side.comments = comments
  side.operators = operators
  side.shape = Dump.dump(parsed.chunk)
  return side
end

--- Where token `i` of `side` is, for a message.
local function place(side: Equiv.Side, i: integer): string
  return string.format("%d:%d", Lexer.y(side.tokens, i), Lexer.x(side.tokens, i))
end

--- A token of `side` as it is written in a message.
local function shown(side: Equiv.Side, i: integer): string
  local text = Lexer.text(side.tokens, i)
  if #text > 40 then
    text = text:sub(1, 37) .. "..."
  end
  return string.format("%q", text)
end

--- The first place at which `a` and `b` differ, and a window of each around it.
local function window(a: string, b: string): string
  local at = 1
  local limit = math.min(#a, #b)
  while at <= limit and a:byte(at) == b:byte(at) do
    at = at + 1
  end
  local from = math.max(1, at - 30)
  return string.format("%q against %q", a:sub(from, at + 30), b:sub(from, at + 30))
end

--- Whether token `i` of `before` and token `j` of `after` are the same: the same kind and bytes.
local function alike(before: Equiv.Side, i: integer?, after: Equiv.Side, j: integer?): boolean
  if i == nil or j == nil then
    return false
  end
  return Lexer.kind(before.tokens, i) == Lexer.kind(after.tokens, j) and
    Lexer.text(before.tokens, i) == Lexer.text(after.tokens, j)
end

--- Why the tokens of `before` and `after` differ, or nil.
local function tokens_differ(before: Equiv.Side, after: Equiv.Side): string?
  local a, b = before.kept, after.kept
  for k = 1, math.max(#a, #b) do
    local i, j = a[k], b[k]
    if i == nil or j == nil then
      if i == nil and j ~= nil then
        return string.format("a token was added at %s: %s", place(after, j), shown(after, j))
      end
      return string.format("the token at %s was lost: %s", place(before, i or 1), shown(before, i or 1))
    end
    if not alike(before, i, after, j) then
      -- One token more or fewer, the rest the same.
      if alike(before, a[k + 1], after, j) then
        return string.format("the token at %s was lost: %s", place(before, i), shown(before, i))
      elseif alike(before, i, after, b[k + 1]) then
        return string.format("a token was added at %s: %s", place(after, j), shown(after, j))
      end
      return string.format("the token at %s, %s, is %s at %s", place(before, i), shown(before, i), shown(after, j),
        place(after, j))
    end
  end
  return nil
end

--- Why the comments of `before` and `after` differ, or nil.
local function comments_differ(before: Equiv.Side, after: Equiv.Side): string?
  local a, b = before.comments, after.comments
  for k = 1, math.max(#a, #b) do
    local was, now = a[k], b[k]
    if was == nil and now ~= nil then
      return string.format("a comment was added at %d:%d", now.y, now.x)
    elseif was ~= nil and now == nil then
      return string.format("the comment at %d:%d was lost", was.y, was.x)
    elseif was ~= nil and now ~= nil then
      if was.text ~= now.text then
        return string.format("the comment at %d:%d changed: %s", was.y, was.x, window(was.text, now.text))
      end
      if was.doc ~= now.doc then
        return string.format("the comment at %d:%d %s", was.y, was.x,
          if was.doc then "is no longer part of a doc comment" else "is now part of a doc comment" end)
      end
      -- Behind the operator it lay before, once the operator moved behind the code before.
      local moved = before.operators[was.on] == true and now.before == was.before + 1
      if now.before ~= was.before and not moved then
        return string.format("the comment at %d:%d comes after %s, where it came after %d", was.y, was.x,
          plural.count(now.before, "token"), was.before)
      end
    end
  end
  return nil
end

function Equiv.difference(before: Equiv.Side, after: Equiv.Side): string?
  if before.trouble ~= "" then
    return "the source does not parse: " .. before.trouble
  end
  if after.trouble ~= "" then
    return "the layout does not parse: " .. after.trouble
  end
  if before.shebang ~= after.shebang then
    return "the #! line changed"
  end
  local why = tokens_differ(before, after) or comments_differ(before, after)
  if why ~= nil then
    return why
  end
  if before.shape ~= after.shape then
    return "the syntax tree changed: " .. window(before.shape, after.shape)
  end
  return nil
end

return Equiv
