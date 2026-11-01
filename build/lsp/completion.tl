--- Completion for `cosmic lsp` ([`build.lsp.session`]): what can be typed at the cursor.
---
--- What it offers, by where the cursor is in the whole text (the lexer's tokens) and what the parser recovers of it:
---
--- - In a comment or a string, of one line or of several (`--[[ ]]`, `[[ ]]`, `[==[ ]==]`): nothing. Right after one, as in
---   any other code.
--- - Inside `require("`: the modules the working database lists ([`source.View`]'s `modules`) and the public modules the docs
---   know, whose names start with what is typed.
--- - After `x.` or `x:`: the members of the type the receiver has. The receiver is any chain of names, calls and indexes
---   (`a.b`, `f().x`, `a[1].x`, `m.f():x`), which the parser reads back from the tokens before the separator. A local, a
---   parameter, a function or a type of the document, a module it requires and a global of the standard library may head it.
---   Where the last text that parsed has the same expression at the same place, its type is the checker's, narrowing
---   included (`x` after `if x is T then`); else it is worked out from the declared types of the names, the members, the
---   element of an array or a map and the result of a function. `.` offers a record's or class's fields and methods, an
---   interface's (its own and those of the interfaces it lists), the functions of a module or of a declaration used as a
---   value, and an enum's values; `:` offers the methods. A member of a type the rows hold has the type as written
---   for its `detail` and the `docs` text of its symbol for `documentation` ([`source.members`]), none when the text has no
---   doc comment on it: the rows are those of the module as staged, or open and unsaved, and for the document's own module of
---   the last text that parsed. The checker's declarations answer for a type the rows cannot name exactly: a module the
---   database does not list (the standard library's `cosmic.*`), a name declared twice in a module or in a block, an
---   interface listing one the rows do not resolve, and a text with no rows (one that does not parse). There the `detail`
---   is the signature in the docs database where it has one, else the checker's type, and the `documentation` its text.
--- - In a type position, wherever the grammar has one (after `:`, `is`, `<` and `,` of type arguments, `{`, `|`, a return
---   type, `local type T =`, a field of a record, ...): the types in scope and the primitive types.
--- - Anywhere else, the names in scope: the locals, parameters, functions and types visible at the cursor
---   ([`Scopes.in_scope`]), then the globals of the standard library.
---
--- Names and members come from the document's last check that parsed ([`check.last`]): a text being typed (`p.`) does not
--- parse, so the cursor is placed in that text by what the two texts share. What is typed at the cursor is read from the text
--- as it is, with a placeholder name where the word being typed is: the lexer says whether the cursor is in a comment or a
--- string, and the parser, which recovers a tree of a text that does not parse, says what node the placeholder is in. A name
--- declared in the text typed since is not offered. Nothing is offered in a document the checker read nothing of.

-- TODO: offer only the types nested in a declaration after `point.` in a type position, once the declarations list a
-- declaration's nested types apart from its fields: every member of the receiver is offered there now.

-- TODO: type a name narrowed at the cursor where the last text that parsed has no read of it at that place (a name just
-- typed after `if x is T then`), once the checker keeps the flow at a position and not only the reads of narrowed places
-- ([`Check.Checked.narrowed`]): the declared type is used. Likewise a call receiver typed since the last parse takes its
-- function's declared result, with the type parameters of a generic function left unsolved, and a string literal as a
-- receiver (`("x"):len()`) offers nothing until the members of `string` can be read as those of a value.

-- TODO: place the cursor in the last parsed text when two separate edits, or a change of line endings, were made since
-- that parse, once the session keeps the edits since a check ([`check.Document`]) and not only the two texts: the
-- places are then found by what the texts share at their starts and their ends, which falls back to the start of the
-- shared prefix. A name declared again in the text typed since is told only by a line that begins `local`, `for` or has
-- `function` and names it ([`declares`]).

-- TODO: complete the members of the standard library's `cosmic.*` modules from rows too, once the binary's own modules have
-- `members` and `docs` rows in a database the session reads: the working database lists none of them, so their members are
-- the checker's declarations of the module and their docs the docs database's.

-- TODO: resolve an interface a declaration lists from another module, or with type arguments, in the rows, once the rows
-- name a listed interface by the module that declares it: the members are then the checker's declarations.

-- TODO: rank the items by how near they are and what was used (`sortText`), fill in `documentation` and `detail` at
-- `completionItem/resolve`, and offer snippets for a call's parameters, once a request needs them: names are ordered by
-- the depth of their scope and then by name, and every item carries its text.

local Ast = require("lang.ast")
local Declarations = require("lang.declarations")
local Driver = require("build.driver")
local Lexer = require("lang.lexer")
local Report = require("build.syntax_report")
local Scopes = require("lang.scopes")
local Types = require("lang.types")
local check = require("build.lsp.check")
local source = require("build.lsp.source")
local docs = require("build.docs")
local hover = require("build.lsp.hover")
local lines = require("build.lsp.lines")
local protocol = require("build.lsp.protocol")

local record completion
  --- What is typed at the cursor.
  record Context
    --- "modules", "members", "types" or "names".
    mut what: string
    --- The part of the name typed already, and the byte of the line it starts at.
    mut prefix: string
    mut start: integer
    --- For "members": whether the separator is `:`.
    mut method: boolean
  end

  --- A member of a declaration.
  record Member
    name: string
    --- Nil for an enum's value.
    type: Types.Type?
    method: boolean
    --- Where the member is a row: its type as written, its documentation and its kind.
    row: source.MemberRow?
  end
end

local type Context = completion.Context
local type Member = completion.Member

-- The protocol's CompletionItemKind.
local METHOD <const> = 2
local FUNCTION <const> = 3
local FIELD <const> = 5
local VARIABLE <const> = 6
local CLASS <const> = 7
local INTERFACE <const> = 8
local MODULE <const> = 9
local ENUM <const> = 13
local ENUM_MEMBER <const> = 20
local STRUCT <const> = 22
local TYPE_PARAMETER <const> = 25

--- The name the cursor's word is replaced by in the text the parser reads, which no program uses.
local PLACEHOLDER <const> = "COSMIC_COMPLETION_HERE"

--- What a receiver is parsed after, so that it is the value of a statement the parser takes whole.
local HEAD <const> = "local _ = "

--- Where the cursor, before byte `at` of the text that `tokens` are of, is: "comment", "quoted" (in a string a quote opened
--- on its line, which `require("` completes), "string" (in a long string) or "code". The lexer reads the whole text, so a
--- comment or a string of several lines is told; the end of a line comment and of a string left open at the end of its line
--- are inside it, the byte after a closed one is not.
local function lexical(tokens: Lexer.Tokens, at: integer): string
  local low, high = 1, Lexer.count(tokens)
  -- The first token that starts at or after the cursor: the comments before it are the nearest before the cursor.
  while low < high do
    local middle = (low + high) // 2
    if Lexer.offset(tokens, middle) >= at then
      high = middle
    else
      low = middle + 1
    end
  end
  local comments = tokens.comments[low]
  if comments ~= nil then
    for _, comment in ipairs(comments) do
      local stop = comment.offset + comment.length
      if at >= comment.offset + 2 then
        if comment.text:match("^%-%-%[=*%[") ~= nil then
          if at < stop then return "comment" end
        elseif at <= stop then
          return "comment"
        end
      end
    end
  end
  if low > 1 then
    local token = low - 1
    local kind = Lexer.kind(tokens, token)
    local text = Lexer.text(tokens, token)
    local quote = text:sub(1, 1) == '"' or text:sub(1, 1) == "'"
    local stop = Lexer.stop(tokens, token)
    if kind == "string" and at < stop then
      if quote then return "quoted" end
      return "string"
    elseif kind == "$ERR$" and at <= stop then
      -- A form left open: a string to the end of its line, a long string or a long comment to the end of the text.
      if quote then return "quoted" end
      if text:match("^%-%-") ~= nil then return "comment" end
      if text:match("^%[=*%[") ~= nil then return "string" end
    end
  end
  return "code"
end

--- The index of the token that opens the bracket token `close` closes, nil where the tokens before it do not.
local function opener(tokens: Lexer.Tokens, close: integer): integer?
  local depth = 0
  for at = close, 1, -1 do
    local kind = Lexer.kind(tokens, at)
    if kind == ")" or kind == "]" or kind == "}" then
      depth = depth + 1
    elseif kind == "(" or kind == "[" or kind == "{" then
      depth = depth - 1
      if depth == 0 then return at end
    end
  end
  return nil
end

--- The index of the first token of the receiver that ends at token `last`: a name, or a parenthesised expression, followed by
--- any number of fields (`.x`), methods (`:x`), calls (with parentheses, a string or a table) and indexes, or a string
--- literal. nil where the tokens are none.
local function receiver_start(tokens: Lexer.Tokens, last: integer): integer?
  local at = last
  while at >= 1 do
    local kind = Lexer.kind(tokens, at)
    if kind == "identifier" then
      local sep = at - 1
      if sep > 1 and (Lexer.kind(tokens, sep) == "." or Lexer.kind(tokens, sep) == ":") then
        at = sep - 1
      else
        return at
      end
    elseif kind == "string" then
      -- A string is the argument of a call where a callee ends before it, else the receiver itself.
      local callee = at - 1
      local before: Lexer.Kind = "$EOF$"
      if callee >= 1 then before = Lexer.kind(tokens, callee) end
      if before == "identifier" or before == ")" or before == "]" then
        at = callee
      else
        return at
      end
    elseif kind == ")" or kind == "]" or kind == "}" then
      local open = opener(tokens, at)
      if open == nil then return nil end
      local callee = open - 1
      local before: Lexer.Kind = "$EOF$"
      if callee >= 1 then before = Lexer.kind(tokens, callee) end
      if before == "identifier" or before == ")" or before == "]" then
        at = callee
      elseif kind == ")" then
        return open
      else
        return nil
      end
    else
      return nil
    end
  end
  return nil
end

--- The deepest node of `chunk` that holds token `token`.
local function innermost(chunk: Ast.Chunk, token: integer): Ast.Node
  local node: Ast.Node = chunk
  local descending = true
  while descending do
    local inside: mut {Ast.Node} = {}
    Ast.children(node, function(child: Ast.Node)
      if child.first <= token and token <= child.last then inside[1] = child end
    end)
    local child = inside[1]
    if child == nil then
      descending = false
    else
      node = child
    end
  end
  return node
end

--- Whether `name` starts with what was typed, in either case.
local function matches(name: string, prefix: string): boolean
  return name:sub(1, #prefix):lower() == prefix:lower()
end

--- The lines of `new` that differ from `old`: those between what the two share at their starts and at their ends.
local function changed_lines(old: string, new: string): string
  if old == new then return "" end
  local limit = math.min(#old, #new)
  local before = 0
  while before < limit and old:byte(before + 1) == new:byte(before + 1) do before = before + 1 end
  local after = 0
  while after < limit - before and old:byte(#old - after) == new:byte(#new - after) do
    after = after + 1
  end
  local from = before + 1
  while from > 1 and new:sub(from - 1, from - 1) ~= "\n" do from = from - 1 end
  local to = #new - after
  local stop = new:find("\n", to + 1, true) or #new
  return new:sub(from, stop)
end

--- Whether a line of `text` declares `name`: a `local` or a `for` that names it before its `=` or `in`, or a function whose
--- parameters do.
local function declares(text: string, name: string): boolean
  local word = "%f[%w_]" .. name .. "%f[^%w_]"
  for row in text:gmatch("[^\n]+") do
    local names: string? = nil
    if row:match("^%s*local%s") ~= nil or row:match("^%s*for%s") ~= nil then
      names = row:match("^([^=]*)") or row
      names = (names:match("^(.-)%sin%s") or names)
    end
    if names ~= nil and names:find(word) ~= nil then return true end
    local params = row:match("function[^%(]*(%b())")
    if params ~= nil and params:find(word) ~= nil then return true end
  end
  return false
end

--- Where the cursor, `count` bytes into the text `new`, is in the text `old`: the same place where the texts share what
--- is before it or after it, else the start of what they do not share.
local function earlier_count(old: string, new: string, count: integer): integer
  if old == new then return count end
  local limit = math.min(#old, #new)
  local before = 0
  while before < limit and old:byte(before + 1) == new:byte(before + 1) do before = before + 1 end
  if count <= before then return count end
  local after = 0
  while after < limit - before and old:byte(#old - after) == new:byte(#new - after) do
    after = after + 1
  end
  local rest = #new - count
  if rest <= after then return #old - rest end
  return before
end

--- The token of `tokens` that holds byte `at` of the text, else the first after it, else the last.
local function token_near(tokens: Lexer.Tokens, at: integer): integer
  local count = Lexer.count(tokens)
  local low, high = 1, count
  local found = 0
  while low <= high do
    local middle = (low + high) // 2
    if Lexer.offset(tokens, middle) <= at then
      found = middle
      low = middle + 1
    else
      high = middle - 1
    end
  end
  if found > 0 and at < Lexer.offset(tokens, found) + Lexer.length(tokens, found) then
    return found
  end
  return math.min(found + 1, count)
end

--- What one request reads.
local record Request
  program: Declarations.Program
  outcome: Driver.Outcome
  checker: check.Checker
  --- The text the last check was of.
  text: string
end

--- The declaration `t` is, or is an optional or a union of, and whether it is used as a value (the table of its functions).
local function receiver_of(t: Types.Type?): Types.Decl?, boolean
  if t == nil then return nil, false end
  if t.tag == "union" then
    for _, member in ipairs(t.members) do
      local decl, value = receiver_of(member)
      if decl ~= nil then return decl, value end
    end
    return nil, false
  end
  if t.tag == "named" then return t.decl, t.value end
  return nil, false
end

--- The members `decl` has, by name: of a value (the table of its functions) when `value`, else of an instance of it. The
--- rules are the checker's own for what a member read finds ([`lang.check`]).
local function members_of(program: Declarations.Program, decl: Types.Decl, value: boolean): {Member}
  local body = decl.body
  local out: mut {Member} = {}
  if body == nil then return out end
  local seen: mut {string: boolean} = {}
  local function add(name: string, t: Types.Type?, method: boolean)
    if seen[name] == true then return end
    seen[name] = true
    out[#out + 1] = { name = name, type = t, method = method, row = nil }
  end
  local absent = program.absent[decl] or {}
  for _, field in ipairs(body.fields) do
    -- A function field every value holds is not in the table of the functions.
    if not (value and (decl.kind == "class" or absent[field.name] == true)) then
      add(field.name, field.type, false)
    end
  end
  for _, method in ipairs(body.methods) do add(method.name, method.type, true) end
  local statics = program.statics[decl] or {}
  if value then
    for name, field in pairs(statics) do add(name, field.type, false) end
    if decl.kind == "enum" then
      for _, name in ipairs(body.values) do add(name, nil, false) end
    end
  else
    if decl.kind == "interface" then
      for _, field in ipairs(Declarations.inherited(program.store, program.judge, decl)) do
        add(field.name, field.type, false)
      end
    end
    -- The table of a class is the metatable of its values: a function there is a method of them.
    if decl.kind == "class" and (decl.arity or 0) == 0 then
      for name, field in pairs(statics) do
        if field.type.tag == "fn" then add(name, field.type, true) end
      end
    end
  end
  table.sort(out, function(a: Member, b: Member): boolean return a.name < b.name end)
  return out
end

--- The type of the name `name` at the token of the request, the declaration it is, and whether it is used as a value: a
--- binding in scope, else a global of the standard library.
local function head_of(request: Request, scope: {string: Scopes.Var}, name: string): Types.Type?, Types.Decl?, boolean
  local program = request.program
  local var = scope[name]
  if var ~= nil then
    local checked = request.outcome.checked
    local t: Types.Type? = nil
    if checked ~= nil then t = checked.vars[var.id] end
    local typed, value = receiver_of(t)
    if typed ~= nil then return t, typed, value end
    local lowered = request.outcome.lowered
    if lowered ~= nil then
      local entry = lowered.entries[var.id]
      if entry ~= nil and entry.decl ~= nil then return t, entry.decl, true end
    end
    if var.module ~= "" then
      local root = Report.root_of(program, var.module)
      if root ~= nil then return t, root, true end
    end
    return t, nil, false
  end
  local entry = program.globals[name]
  if entry ~= nil and entry.decl ~= nil then return nil, entry.decl, true end
  local overloads = program.values[name]
  if overloads ~= nil then
    local decl, value = receiver_of(overloads[1])
    return overloads[1], decl, value
  end
  return nil, nil, false
end

--- A receiver typed: its type where it has one, and the declaration its members are read from.
local record Typed
  type: Types.Type?
  decl: Types.Decl?
  value: boolean
end

--- What typing the receiver of a request reads.
local record Ground
  request: Request
  scope: {string: Scopes.Var}
  reading: check.Reading
  --- The text the reading was of, and the text of the document now.
  old: string
  new: string
  --- The lines of `new` that differ from `old` ([`changed_lines`]).
  edited: string
  --- The tokens of the text the receiver was parsed from, and what to add to a byte of it to find the byte in `new`.
  tokens: Lexer.Tokens
  delta: integer
end

local function typed_of(t: Types.Type?): Typed
  local decl, value = receiver_of(t)
  return { type = t, decl = decl, value = value }
end

--- `t` without its `nil`, where that leaves one type.
local function stripped(t: Types.Type?): Types.Type?
  if t ~= nil and t.tag == "union" and #t.members == 1 then return t.members[1] end
  return t
end

--- The first value a function of type `t` answers.
local function returned(t: Types.Type?): Types.Type?
  local fn = stripped(t)
  if fn == nil or fn.tag ~= "fn" then return nil end
  local alt = fn.rets[1]
  if alt == nil then return nil end
  local first = alt.items[1]
  if first ~= nil then return first end
  return alt.tail
end

--- The type the last check gave the expression `node` of the receiver, when the text it was of has the same text at the
--- same place: the checker's own, which the narrowing there has been applied to. nil where it has none.
local function located(ground: Ground, node: Ast.Node): Types.Type?
  local from = Lexer.offset(ground.tokens, node.first) + ground.delta
  local to = Lexer.stop(ground.tokens, node.last) - 1 + ground.delta
  local old, new = ground.old, ground.new
  local first = earlier_count(old, new, from - 1) + 1
  local last = earlier_count(old, new, to)
  if from < 1 or last - first ~= to - from or old:sub(first, last) ~= new:sub(from, to) then
    return nil
  end
  local outcome = ground.request.outcome
  local tokens = outcome.chunk.tokens
  local start = check.checker_offset(ground.reading, first)
  local finish = check.checker_offset(ground.reading, last)
  local low, high = token_near(tokens, start), token_near(tokens, finish)
  if Lexer.offset(tokens, low) ~= start or Lexer.stop(tokens, high) - 1 ~= finish then
    return nil
  end
  -- The deepest node that spans those tokens and was typed.
  local found: Types.Type? = nil
  local at: Ast.Node = outcome.chunk
  local descending = true
  while descending do
    if at.first == low and at.last == high then found = outcome.types[at.id] or found end
    local inside: mut {Ast.Node} = {}
    Ast.children(at, function(child: Ast.Node)
      if child.first <= low and high <= child.last then inside[1] = child end
    end)
    local child = inside[1]
    if child == nil then
      descending = false
    else
      at = child
    end
  end
  -- A type name used as a value is `invalid` there: the declaration is read by name.
  if found ~= nil and found.tag == "invalid" then return nil end
  return found
end

--- The member `name` of `base`, typed.
local function member_typed(request: Request, base: Typed, name: string): Typed?
  local t = stripped(base.type)
  if t ~= nil and t.tag == "map" then return typed_of(t.value) end
  if base.decl == nil then return nil end
  local found: Types.Type? = nil
  for _, member in ipairs(members_of(request.program, base.decl, base.value)) do
    if member.name == name then found = member.type end
  end
  if found == nil then return nil end
  return typed_of(found)
end

--- The expression `node`, typed: as the last check typed it where the text has it at that place, else from what its parts
--- are declared to be. nil where it is not known.
local function typed_node(ground: Ground, node: Ast.Node): Typed?
  if node.kind == "Name" and declares(ground.edited, node.text) then return nil end
  local known = located(ground, node)
  if known ~= nil then return typed_of(known) end
  if node.kind == "Paren" then return typed_node(ground, node.inner) end
  if node.kind == "Name" then
    -- A name declared again in the text typed since the last parse is not the binding that parse saw.
    if declares(ground.edited, node.text) then return nil end
    local t, decl, value = head_of(ground.request, ground.scope, node.text)
    return { type = t, decl = decl, value = value }
  end
  if node.kind == "Field" then
    local base = typed_node(ground, node.object)
    if base == nil then return nil end
    return member_typed(ground.request, base, node.name)
  end
  if node.kind == "Index" then
    local base = typed_node(ground, node.object)
    if base == nil then return nil end
    local t = stripped(base.type)
    if t ~= nil and t.tag == "array" then return typed_of(t.element) end
    if t ~= nil and t.tag == "map" then return typed_of(t.value) end
    return nil
  end
  if node.kind == "Call" then
    local callee = typed_node(ground, node.callee)
    if callee == nil then return nil end
    return typed_of(returned(callee.type))
  end
  if node.kind == "MethodCall" then
    local base = typed_node(ground, node.object)
    if base == nil then return nil end
    local method = member_typed(ground.request, base, node.name)
    if method == nil then return nil end
    return typed_of(returned(method.type))
  end
  return nil
end

--- The prefix the docs spell a member of `decl` with: "" for a module's own record, the path under it for a nested one,
--- else the declaration's name; nil where the docs know no such owner.
local function symbol_prefix(program: Declarations.Program, decl: Types.Decl): string?
  local owner = Report.owner_of(program, decl)
  if owner ~= nil then return owner.path .. "." end
  local home = Report.home_of(program, decl)
  if home == nil then return nil end
  if home.path == "" then return "" end
  return home.path .. "."
end

--- The docs of the members `members` of `decl`, by name, where `decl` is declared in another module than `own`.
local function documented(request: Request, d: hover.Docs, decl: Types.Decl, members: {Member}): {string: docs.Entry}
  local out: mut {string: docs.Entry} = {}
  if decl.module == request.outcome.module or #members == 0 then return out end
  local prefix = symbol_prefix(request.program, decl)
  local view = hover.view(d)
  if prefix == nil or view == nil then return out end
  local symbols: mut {string} = {}
  for _, member in ipairs(members) do symbols[#symbols + 1] = prefix .. member.name end
  local found, _ = docs.named_all(view, symbols)
  if found == nil then return out end
  for _, entry in ipairs(found) do
    if entry.module == decl.module and out[entry.symbol:sub(#prefix + 1)] == nil then
      out[entry.symbol:sub(#prefix + 1)] = entry
    end
  end
  return out
end

--- The markup of `entry`'s text, nil where it has none.
local function markup(entry: docs.Entry?): protocol.MarkupContent?
  if entry == nil or entry.text == "" then return nil end
  return { kind = "markdown", value = entry.text }
end

-- TODO: offer a field whose type is an alias of a function as a function, once the rows carry the kind of a member's
-- resolved type: a row's type is as written, so only `function(` shows it.

--- The kind of item a member is.
local function member_kind(member: Member): integer
  local row = member.row
  if row ~= nil then
    if row.kind == "value" then return ENUM_MEMBER end
    if row.kind == "method" then return METHOD end
    if row.kind == "function" or row.type:sub(1, 9) == "function(" then return FUNCTION end
    return FIELD
  end
  local t = member.type
  if t == nil then return ENUM_MEMBER end
  if member.method then return METHOD end
  if t.tag == "fn" then return FUNCTION end
  return FIELD
end

--- The members of the type at `symbol` of `rows` (the interfaces it lists too), of its value when `value`, else of an
--- instance of it; nil where the rows do not hold the type, or a type it lists.
local function row_members(rows: source.Members, symbol: string, value: boolean, depth?: integer): {Member}?
  local owner = rows[symbol]
  if owner == nil or owner.kind == "" or (depth or 0) > 16 then return nil end
  local out: mut {Member} = {}
  local seen: mut {string: boolean} = {}
  for _, row in ipairs(owner.members) do
    local wanted = if value then row.scope ~= "instance" else row.scope ~= "value" end
    if wanted and seen[row.name] ~= true then
      seen[row.name] = true
      out[#out + 1] = { name = row.name, type = nil, method = row.kind == "method", row = row }
    end
  end
  if owner.kind == "interface" and not value then
    local parent = symbol:match("^(.*)%.[^.]*$")
    for _, listed in ipairs(owner.supers) do
      local named = if parent ~= nil and rows[parent .. "." .. listed] ~= nil then parent .. "." .. listed else listed end
      local inherited = if listed:find("[<.]") == nil then row_members(rows, named, false, (depth or 0) + 1) else nil end
      if inherited == nil then return nil end
      for _, member in ipairs(inherited) do
        if seen[member.name] ~= true then
          seen[member.name] = true
          out[#out + 1] = member
        end
      end
    end
  end
  table.sort(out, function(a: Member, b: Member): boolean return a.name < b.name end)
  return out
end

--- The members of `decl` its module's rows give, nil where there are none ([`source.members`]).
local function rows_of(request: Request, decl: Types.Decl, value: boolean): {Member}?
  local checker = request.checker
  local text: string? = nil
  if decl.module == request.outcome.module then text = request.text end
  local rows = source.members(checker.source, decl.module, check.open_files(checker), text)
  if rows == nil then return nil end
  return row_members(rows, decl.name, value)
end

--- The members offered after a separator.
local function member_items(request: Request, d: hover.Docs, decl: Types.Decl, value: boolean, context: Context,
                            out: mut {protocol.CompletionItem}, edit: protocol.Range)
  local tally = request.checker.source.tally
  local members = rows_of(request, decl, value)
  local from_rows = members ~= nil
  if members ~= nil then
    tally.member_rows = tally.member_rows + 1
  else
    tally.member_declarations = tally.member_declarations + 1
    members = members_of(request.program, decl, value)
  end
  local wanted: mut {Member} = {}
  for _, member in ipairs(members) do
    -- A `:` reads a method.
    if matches(member.name, context.prefix) and (not context.method or member.method) then
      wanted[#wanted + 1] = member
    end
  end
  -- The docs of the rows are the text's own: the docs database, the last build's, is no source for a member they hold.
  local entries: {string: docs.Entry} = {}
  if not from_rows then entries = documented(request, d, decl, wanted) end
  for _, member in ipairs(wanted) do
    local entry = entries[member.name]
    local t = member.type
    local row = member.row
    local detail: string? = nil
    local documentation = markup(entry)
    if row ~= nil then
      if row.type ~= "" then detail = row.type end
      if row.doc ~= "" then documentation = { kind = "markdown", value = row.doc } end
    elseif entry ~= nil and entry.signature ~= "" then
      detail = entry.signature
    elseif t ~= nil then
      detail = Types.display(t)
    end
    local item: protocol.CompletionItem = { label = member.name, kind = member_kind(member), detail = detail,
      documentation = documentation, sortText = nil, textEdit = { range = edit, newText = member.name } }
    out[#out + 1] = item
  end
end

--- The kind of item the binding `var` is, typed `t`.
local function var_kind(var: Scopes.Var, t: Types.Type?): integer
  local kind = var.kind
  if kind == "record" then return STRUCT end
  if kind == "class" then return CLASS end
  if kind == "interface" then return INTERFACE end
  if kind == "enum" then return ENUM end
  if kind == "alias" then return STRUCT end
  if kind == "typeparam" then return TYPE_PARAMETER end
  if kind == "import" or var.module ~= "" then return MODULE end
  if kind == "function" or (t ~= nil and t.tag == "fn") then return FUNCTION end
  return VARIABLE
end

--- Whether a binding of `space` can be named where a type is written (`types`) or a value is.
local function fits(space: Scopes.Space, types: boolean): boolean
  if space == "both" then return true end
  return (space == "type") == types
end

--- The names in scope, then the globals of the standard library, whose names start with the prefix typed.
local function name_items(request: Request, scope: {string: Scopes.Var}, types: boolean, context: Context,
                          out: mut {protocol.CompletionItem}, edit: protocol.Range)
  local checked = request.outcome.checked
  local names: mut {string} = {}
  for name in pairs(scope) do names[#names + 1] = name end
  table.sort(names)
  local program = request.program
  for _, name in ipairs(names) do
    local var = assert(scope[name])
    if matches(name, context.prefix) and fits(var.space, types) then
      local t: Types.Type? = nil
      if checked ~= nil then t = checked.vars[var.id] end
      local detail: string = var.kind
      if t ~= nil then detail = Types.display(t) end
      -- The nearer the scope, the earlier.
      local item: protocol.CompletionItem = { label = name, kind = var_kind(var, t), detail = detail,
        documentation = nil, sortText = string.format("0%02d", 99 - math.min(var.depth, 99)) .. name,
        textEdit = { range = edit, newText = name } }
      out[#out + 1] = item
    end
  end
  local globals: mut {string} = {}
  if types then
    for name in pairs(Scopes.primitives) do globals[#globals + 1] = name end
    for name, entry in pairs(program.globals) do
      if entry.decl ~= nil then globals[#globals + 1] = name end
    end
  else
    for name in pairs(program.values) do globals[#globals + 1] = name end
    for name, entry in pairs(program.globals) do
      if entry.decl ~= nil then globals[#globals + 1] = name end
    end
  end
  table.sort(globals)
  local last = ""
  for _, name in ipairs(globals) do
    if name ~= last and scope[name] == nil and matches(name, context.prefix) then
      last = name
      local kind = VARIABLE
      local entry = program.globals[name]
      local overloads = program.values[name]
      if types then
        kind = CLASS
      elseif entry ~= nil and entry.decl ~= nil then
        kind = MODULE
      elseif overloads ~= nil and overloads[1] ~= nil and assert(overloads[1]).tag == "fn" then
        kind = FUNCTION
      end
      out[#out + 1] = { label = name, kind = kind, detail = nil, documentation = nil, sortText = "1" .. name,
        textEdit = { range = edit, newText = name } }
    end
  end
end

--- The modules a `require` can name, whose names start with the prefix typed: the working database's and the docs'.
local function module_items(checker: check.Checker, d: hover.Docs, context: Context, out: mut {protocol.CompletionItem},
                            edit: protocol.Range)
  local names: mut {string: boolean} = {}
  for name, listed in pairs(checker.source.modules) do
    if listed.kind ~= "test" and listed.kind ~= "example" then names[name] = true end
  end
  local view = hover.view(d)
  if view ~= nil then
    local index, _ = docs.index(view)
    for _, summary in ipairs(index or {}) do names[summary.module] = true end
  end
  local sorted: mut {string} = {}
  for name in pairs(names) do
    if matches(name, context.prefix) then sorted[#sorted + 1] = name end
  end
  table.sort(sorted)
  for _, name in ipairs(sorted) do
    out[#out + 1] = { label = name, kind = MODULE, detail = nil, documentation = nil, sortText = nil,
      textEdit = { range = edit, newText = name } }
  end
end

--- The part of a module name typed, if the text before the cursor on its line ends inside the string of a `require(`.
local function required(before: string): string?
  local quote, wanted = before:match("require%s*%(?%s*([\"'])([%w_%.%-]*)$")
  if quote == nil then return nil end
  return wanted
end

--- The receiver of the separator at token `sep` of `tokens`, which are of `text`, parsed by itself: the node, the tokens it
--- is of and what to add to a byte of them to find it in `text`. nil where no receiver ends there.
local function receiver_at(document: check.Document, text: string, tokens: Lexer.Tokens, sep: integer):
    Ast.Exp?, Lexer.Tokens?, integer
  local first = receiver_start(tokens, sep - 1)
  if first == nil then return nil, nil, 0 end
  local from = Lexer.offset(tokens, first)
  local small = HEAD .. text:sub(from, Lexer.offset(tokens, sep) - 1) .. Lexer.text(tokens, sep) .. PLACEHOLDER
  local dialect: Ast.Dialect = "tl"
  if document.name:match("%.d%.tl$") ~= nil then dialect = "decl" end
  local chunk = Driver.parse(Driver.source(document.name, document.name, small, dialect)).chunk
  local stat = chunk.body.stats[1]
  if stat == nil or stat.kind ~= "Local" then return nil, nil, 0 end
  local value = stat.values[1]
  if value == nil then return nil, nil, 0 end
  if value.kind == "Field" or value.kind == "MethodCall" then
    return value.object, chunk.tokens, from - 1 - #HEAD
  end
  return nil, nil, 0
end

--- The completions at `where` of `document`, whose characters count in `encoding`'s units: nil where nothing is open there.
--- An empty list is a place where nothing can be typed, or nothing is known.
function completion.at(checker: check.Checker, d: hover.Docs, document: check.Document, where: protocol.Position,
                       encoding: string): protocol.CompletionList?
  local split = lines.lines_of(document.text)
  local line = split.texts[where.line + 1]
  local start = split.starts[where.line + 1]
  if line == nil or start == nil then return nil end
  local byte = lines.byte_of(line, where.character, encoding)
  local before = line:sub(1, byte - 1)
  local out: mut {protocol.CompletionItem} = {}
  -- The byte of the text the cursor is before.
  local cursor = start + byte - 1
  local prefix = before:match("[%a_][%w_]*$") or ""
  -- The text with the word being typed replaced by a name, as the parser recovers a tree of it. The rest of a word the
  -- cursor is inside of goes with it. It is lexed once, for the place of the cursor and for the tree.
  local rest = line:sub(byte):match("^[%w_]*") or ""
  local spliced = document.text:sub(1, cursor - 1 - #prefix) .. PLACEHOLDER .. document.text:sub(cursor + #rest)
  local dialect: Ast.Dialect = "tl"
  if document.name:match("%.d%.tl$") ~= nil then dialect = "decl" end
  local chunk = Driver.parse(Driver.source(document.name, document.name, spliced, dialect)).chunk
  local tokens = chunk.tokens
  local state = lexical(tokens, cursor - #prefix + #PLACEHOLDER)
  if state == "comment" or state == "string" then return { isIncomplete = false, items = out } end
  local context: Context = { what = "names", prefix = prefix, start = byte - #prefix, method = false }
  local wanted = required(before)
  if wanted ~= nil and state == "quoted" then
    context.what = "modules"
    context.prefix = wanted
    context.start = #before - #wanted + 1
  elseif state == "quoted" then
    return { isIncomplete = false, items = out }
  end
  local edit = protocol.range(lines.position(split, start + context.start - 1, encoding),
    lines.position(split, start + byte - 1, encoding))
  if context.what == "modules" then
    module_items(checker, d, context, out, edit)
    return { isIncomplete = false, items = out }
  end
  local last = check.last(checker, document)
  if last == nil then return { isIncomplete = false, items = out } end
  local outcome = last.reading.outcome
  -- The byte before the cursor, in the text the reading was of, then in the text the checker read.
  local earlier = earlier_count(last.text, document.text, cursor - 1)
  local token = token_near(outcome.chunk.tokens, check.checker_offset(last.reading, math.max(earlier, 1)))
  local request: Request = { program = last.reading.program, outcome = outcome, checker = checker, text = last.text }
  local scope = Scopes.in_scope(outcome.scoped, token)
  local at = token_near(tokens, cursor - #prefix)
  if Lexer.text(tokens, at) ~= PLACEHOLDER or Lexer.offset(tokens, at) ~= cursor - #prefix then
    name_items(request, scope, false, context, out, edit)
    return { isIncomplete = false, items = out }
  end
  local node = innermost(chunk, at)
  local sep: Lexer.Kind = "$EOF$"
  if at > 1 then sep = Lexer.kind(tokens, at - 1) end
  if node.kind == "TypeName" and #node.path == 1 and node.path[1] == PLACEHOLDER then
    name_items(request, scope, true, context, out, edit)
  elseif sep == "." or sep == ":" then
    context.what = "members"
    context.method = sep == ":"
    local receiver, small, delta = receiver_at(document, spliced, tokens, at - 1)
    if receiver ~= nil and small ~= nil then
      local ground: Ground = { request = request, scope = scope, reading = last.reading, old = last.text,
        new = document.text, edited = changed_lines(last.text, document.text), tokens = small, delta = delta }
      local typed = typed_node(ground, receiver)
      if typed ~= nil and typed.decl ~= nil then
        member_items(request, d, typed.decl, typed.value, context, out, edit)
      end
    end
  else
    name_items(request, scope, false, context, out, edit)
  end
  return { isIncomplete = false, items = out }
end

return completion
