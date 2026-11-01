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
---   After `point.` there, the types nested in the declaration `point` is ([`Declarations.Program`]'s `entries`), and no
---   field or function of it.
--- - Anywhere else, the names in scope: the locals, parameters, functions and types visible at the cursor
---   ([`Scopes.in_scope`]), then the globals of the standard library.
---
--- The items are ordered (`sortText`) by how near the scope of a name is, then by how often the text uses it; the members of
--- a type and the modules of a `require` by how often the text uses them. An editor that asks for the documentation of an
--- item when it is chosen (`resolveSupport`) is given a list without the docs database's text of a member, and the place to
--- ask again ([`completion.resolve`]); one that takes snippets is given a function as a call with a placeholder for each
--- parameter, unless a `(` follows the cursor.
---
--- A text being typed (`p.`) does not parse, so what the checker knows of it is found in one of two ways. The text is made to
--- parse where it can: the word being typed is replaced by a placeholder name, and a receiver on a line of its own (`p.`) is
--- made the value of a statement, and it is checked as if the person had typed it ([`check.probe`]); the types are then the
--- checker's of that text, with the narrowing at the cursor, the results of generic calls and the names declared since. Where
--- it still does not parse, the names and members are those of the document's last check that parsed ([`check.last`]), and the
--- cursor is placed in that text by the lines the two texts share ([`lines.align`]), which holds after any number of edits and
--- a change of line endings. A name bound on a line edited since, told by the scopes of the tree the parser recovers of the
--- text typed, is not typed by the binding the last check saw, and one declared since is not offered there.
--- What is typed at the cursor is read from the text as it is, with the placeholder where the word being typed is: the lexer
--- says whether the cursor is in a comment or a string, and the parser says what node the placeholder is in. Nothing is
--- offered in a document the checker read nothing of.

-- TODO: type a name narrowed at the cursor, and a call receiver, in a text typed that does not parse even with the word
-- replaced and a receiver made a statement (another statement of it is broken), once the checker reads a tree the parser
-- recovered of a text with errors: the last text that parsed answers there, and where it has no read of a name at that
-- place its declared type is used, and a call takes its function's declared result, with the type parameters of a
-- generic function left unsolved. Likewise a string literal as a receiver (`("x"):len()`) offers nothing until the
-- members of `string` can be read as those of a value.

-- TODO: complete the members of the standard library's `cosmic.*` modules from rows too, once the binary's own modules have
-- `members` and `docs` rows in a database the session reads: the working database lists none of them, so their members are
-- the checker's declarations of the module and their docs the docs database's.

-- TODO: resolve an interface a declaration lists from another module, or with type arguments, in the rows, once the rows
-- name a listed interface by the module that declares it: the members are then the checker's declarations.

-- TODO: name the placeholders of a call inserted for a function after its parameters where its type is the checker's and
-- not written (a local function, a global of the standard library, a member the rows do not hold), once a function type
-- carries the names of its parameters ([`Types.Param`]): they are `arg1`, `arg2`, ... there.

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
  --- What the editor takes of a completion, and the document it is of.
  record Options
    uri: string
    --- Whether a function is inserted with a placeholder for each of its parameters.
    snippets: boolean
    --- Whether the documentation of an item is left out of the list, to be asked for when the item is chosen
    --- ([`completion.resolve`]).
    lazy: boolean
  end

  --- What is typed at the cursor.
  record Context
    --- "modules", "members", "types" or "names".
    mut what: string
    --- The part of the name typed already, and the byte of the line it starts at.
    mut prefix: string
    mut start: integer
    --- For "members": whether the separator is `:`.
    mut method: boolean
    --- For "members": whether the cursor is in a type position (`local p: point.`), where only the types nested in the
    --- receiver's declaration are offered.
    mut types: boolean
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
local function receiver_start(tokens: Lexer.Tokens, last: integer, types: boolean): integer?
  local at = last
  while at >= 1 do
    local kind = Lexer.kind(tokens, at)
    if kind == "identifier" then
      local sep = at - 1
      -- In a type position a `:` annotates (`local v: shapes.`) and is no method call.
      if sep > 1 and (Lexer.kind(tokens, sep) == "." or (Lexer.kind(tokens, sep) == ":" and not types)) then
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

--- How often a text uses a name, a member (a name after `.` or `:`) and a module (the string of a `require`), by name.
local record Uses
  names: {string: integer}
  members: {string: integer}
  modules: {string: integer}
end

--- The uses ([`Uses`]) in the text `tokens` are of.
local function uses_of(tokens: Lexer.Tokens): Uses
  local names: mut {string: integer} = {}
  local members: mut {string: integer} = {}
  local modules: mut {string: integer} = {}
  for at = 1, Lexer.count(tokens) do
    local kind = Lexer.kind(tokens, at)
    if kind == "identifier" then
      local text = Lexer.text(tokens, at)
      local before: Lexer.Kind = "$EOF$"
      if at > 1 then before = Lexer.kind(tokens, at - 1) end
      if before == "." or before == ":" then
        members[text] = (members[text] or 0) + 1
      else
        names[text] = (names[text] or 0) + 1
      end
    elseif kind == "string" and at > 2 and Lexer.text(tokens, at - 2) == "require" then
      local quoted = Lexer.text(tokens, at):match("^[\"'](.*)[\"']$")
      if quoted ~= nil then modules[quoted] = (modules[quoted] or 0) + 1 end
    end
  end
  return { names = names, members = members, modules = modules }
end

--- What one request reads.
local record Request
  options: completion.Options
  uses: Uses
  --- The place completion was asked at, which an item that is left incomplete holds to be completed there.
  data: protocol.ResolveData
  --- Whether a function is inserted as a call with a placeholder for each parameter: the editor takes snippets and no `(`
  --- follows the cursor.
  call: boolean
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
  --- How the lines of `new` correspond to those of `old`.
  alignment: lines.Alignment
  --- Whether a name is bound at the cursor in the text typed since otherwise than the text last checked has it: the binding is
  --- declared on a line that was added or edited since, or is gone.
  rebound: function(name: string): boolean
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
  local first = lines.earlier(ground.alignment, from - 1) + 1
  local last = lines.earlier(ground.alignment, to)
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
  if node.kind == "Name" and ground.rebound(node.text) then return nil end
  local known = located(ground, node)
  if known ~= nil then return typed_of(known) end
  if node.kind == "Paren" then return typed_node(ground, node.inner) end
  if node.kind == "Name" then
    -- A name declared again in the text typed since the last parse is not the binding that parse saw.
    if ground.rebound(node.text) then return nil end
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

--- The names of the parameters in `written`, a function type as written (`function(self: P, a: T, b?: U): R`), without the
--- first when it is `self` and the item is a call by `:`; nil where `written` is no function type.
local function written_params(written: string, colon: boolean): {string}?
  local list = written:match("^function[^%(]*(%b())")
  if list == nil then return nil end
  local names: mut {string} = {}
  local depth = 0
  local start = 2
  local function add(to: integer)
    local name = list:sub(start, to):match("^%s*([%a_][%w_]*)%s*%??%s*:") or list:sub(start, to):match("^%s*([%a_][%w_]*)%s*$")
    if name ~= nil then names[#names + 1] = name end
  end
  for at = 2, #list - 1 do
    local c = list:sub(at, at)
    if c == "(" or c == "<" or c == "{" or c == "[" then
      depth = depth + 1
    elseif c == ")" or c == ">" or c == "}" or c == "]" then
      depth = depth - 1
    elseif c == "," and depth == 0 then
      add(at - 1)
      start = at + 1
    end
  end
  add(#list - 1)
  if colon and names[1] == "self" then table.remove(names, 1) end
  return names
end

--- The text inserted for a call of `name` with a placeholder for each of `params`, as a snippet.
local function call_snippet(name: string, params: {string}): string
  if #params == 0 then return name .. "($0)" end
  local parts: mut {string} = {}
  for at, param in ipairs(params) do
    parts[#parts + 1] = "${" .. tostring(at) .. ":" .. param .. "}"
  end
  return name .. "(" .. table.concat(parts, ", ") .. ")"
end

--- The names to put in a call of a function of type `t` that is not written: one for each parameter.
local function typed_params(t: Types.Type?, drop: boolean): {string}?
  local fn = stripped(t)
  if fn == nil or fn.tag ~= "fn" then return nil end
  local names: mut {string} = {}
  local first = 1
  if drop then first = 2 end
  for n = first, #fn.params do
    local name = "arg" .. tostring(n - first + 1)
    names[#names + 1] = name
  end
  return names
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
  -- A list that leaves the documentation to `completionItem/resolve` does not ask the docs database for it.
  local lazy = request.options.lazy and not from_rows
  local entries: {string: docs.Entry} = {}
  if not from_rows and not lazy then entries = documented(request, d, decl, wanted) end
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
    local kind = member_kind(member)
    local uses = math.min(request.uses.members[member.name] or 0, 99)
    local item: protocol.CompletionItem = { label = member.name, kind = kind, detail = detail,
      documentation = documentation, sortText = string.format("%02d%s", 99 - uses, member.name),
      textEdit = { range = edit, newText = member.name }, insertTextFormat = nil, data = nil }
    if lazy then item.data = request.data end
    -- A function by `.` is called with all its parameters, a method by `:` without its `self`.
    if request.call and ((kind == FUNCTION and not context.method) or (kind == METHOD and context.method)) then
      local params: {string}? = nil
      if row ~= nil then
        params = written_params(row.type, context.method)
      elseif entry ~= nil and entry.signature ~= "" then
        params = written_params(entry.signature:gsub("^function%s+[%w_.:]*", "function"), context.method)
      end
      if params == nil then params = typed_params(t, context.method and member.method) end
      if params ~= nil then
        item.textEdit = { range = edit, newText = call_snippet(member.name, params) }
        item.insertTextFormat = 2
      end
    end
    out[#out + 1] = item
  end
end

--- The types nested in `decl` ([`Declarations.Program`]'s `entries`), by name, as items: a declaration or an alias, which a
--- type position after `decl.` names.
local function nested_items(request: Request, decl: Types.Decl, context: Context, out: mut {protocol.CompletionItem},
                            edit: protocol.Range)
  local found: mut {string: integer} = {}
  for _, entry in pairs(request.program.entries) do
    local names = entry.names
    if entry.module == decl.module and #names == #decl.names + 1 then
      local inside = true
      for at, name in ipairs(decl.names) do
        if names[at] ~= name then inside = false end
      end
      local own = names[#names]
      if inside and own ~= nil and matches(own, context.prefix) then
        local kind = STRUCT
        local made = entry.decl
        if made ~= nil then
          if made.kind == "class" then kind = CLASS end
          if made.kind == "interface" then kind = INTERFACE end
          if made.kind == "enum" then kind = ENUM end
        end
        found[own] = kind
      end
    end
  end
  local sorted: mut {string} = {}
  for name in pairs(found) do sorted[#sorted + 1] = name end
  table.sort(sorted)
  for _, name in ipairs(sorted) do
    local kind = assert(found[name])
    out[#out + 1] = { label = name, kind = kind, detail = nil, documentation = nil, sortText = nil,
      textEdit = { range = edit, newText = name }, insertTextFormat = nil, data = nil }
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
      -- Ordered by how near the scope is, then by how often the text uses it (its declaration is no use), then by name.
      local used = math.min(math.max((request.uses.names[name] or 0) - 1, 0), 99)
      local kind = var_kind(var, t)
      local item: protocol.CompletionItem = { label = name, kind = kind, detail = detail, documentation = nil,
        sortText = string.format("0%02d%02d%s", 99 - math.min(var.depth, 99), 99 - used, name),
        textEdit = { range = edit, newText = name }, insertTextFormat = nil, data = nil }
      if request.call and kind == FUNCTION and not types then
        local params = typed_params(t, false)
        if params ~= nil then
          item.textEdit = { range = edit, newText = call_snippet(name, params) }
          item.insertTextFormat = 2
        end
      end
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
      local used = math.min(request.uses.names[name] or 0, 99)
      local item: protocol.CompletionItem = { label = name, kind = kind, detail = nil, documentation = nil,
        sortText = string.format("1%02d%s", 99 - used, name), textEdit = { range = edit, newText = name },
        insertTextFormat = nil, data = nil }
      if request.call and kind == FUNCTION and overloads ~= nil then
        local params = typed_params(overloads[1], false)
        if params ~= nil then
          item.textEdit = { range = edit, newText = call_snippet(name, params) }
          item.insertTextFormat = 2
        end
      end
      out[#out + 1] = item
    end
  end
end

--- The modules a `require` can name, whose names start with the prefix typed: the working database's and the docs'.
local function module_items(checker: check.Checker, d: hover.Docs, uses: Uses, context: Context,
                            out: mut {protocol.CompletionItem}, edit: protocol.Range)
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
  -- The modules the text requires already come first.
  for _, name in ipairs(sorted) do
    local used = math.min(uses.modules[name] or 0, 99)
    local order = string.format("%02d%s", 99 - used, name)
    out[#out + 1] = { label = name, kind = MODULE, detail = nil, documentation = nil, sortText = order,
      textEdit = { range = edit, newText = name }, insertTextFormat = nil, data = nil }
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
local function receiver_at(document: check.Document, text: string, tokens: Lexer.Tokens, sep: integer, types: boolean):
    Ast.Exp?, Lexer.Tokens?, integer
  local first = receiver_start(tokens, sep - 1, types)
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

--- The text that is checked in place of the document's `spliced` text, which does not parse as the person is typing: it
--- and the bytes added before the cursor, "" where no text that parses is made. The text with the placeholder in the word
--- typed is tried first; a receiver typed on a line of its own (`p.`, no statement) is then made the value of one
--- ([`HEAD`]). `parsed` is the parse of `spliced`, `tokens` its tokens, `at` the placeholder's, `sep` the token before it
--- and `node` the node it is in.
local function probe_text(document: check.Document, spliced: string, parsed: Driver.Parsed, tokens: Lexer.Tokens,
                          at: integer, sep: Lexer.Kind, node: Ast.Node): string, integer
  if #parsed.syntax == 0 then return spliced, 0 end
  if sep ~= "." and sep ~= ":" then return "", 0 end
  local first = receiver_start(tokens, at - 2, node.kind == "TypeName")
  if first == nil then return "", 0 end
  local from = Lexer.offset(tokens, first)
  local text = spliced:sub(1, from - 1) .. HEAD .. spliced:sub(from)
  local dialect: Ast.Dialect = "tl"
  if document.name:match("%.d%.tl$") ~= nil then dialect = "decl" end
  if #Driver.parse(Driver.source(document.name, document.name, text, dialect)).syntax > 0 then
    return "", 0
  end
  return text, #HEAD
end

--- What was left out of the completion item `label` that [`completion.at`] gave at the place `data` names of `document`, which
--- the editor now asks for: its detail and documentation as the docs database has them. Nothing where the place has no such
--- item any more.
function completion.resolve(checker: check.Checker, d: hover.Docs, document: check.Document, label: string,
                            data: protocol.ResolveData, encoding: string, given: completion.Options):
    protocol.ResolvedItem
  local options: completion.Options = { uri = given.uri, snippets = false, lazy = false }
  local listed = completion.at(checker, d, document, { line = data.line, character = data.character }, encoding, options)
  if listed ~= nil then
    for _, item in ipairs(listed.items) do
      if item.label == label then
        return { label = label, detail = item.detail, documentation = item.documentation }
      end
    end
  end
  return { label = label, detail = nil, documentation = nil }
end

--- The completions at `where` of `document`, whose characters count in `encoding`'s units: nil where nothing is open there.
--- An empty list is a place where nothing can be typed, or nothing is known.
function completion.at(checker: check.Checker, d: hover.Docs, document: check.Document, where: protocol.Position,
                       encoding: string, given?: completion.Options): protocol.CompletionList?
  local options: completion.Options = given or { uri = document.uri, snippets = false, lazy = false }
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
  local parsed = Driver.parse(Driver.source(document.name, document.name, spliced, dialect))
  local chunk = parsed.chunk
  local tokens = chunk.tokens
  local state = lexical(tokens, cursor - #prefix + #PLACEHOLDER)
  if state == "comment" or state == "string" then return { isIncomplete = false, items = out } end
  local context: Context = { what = "names", prefix = prefix, start = byte - #prefix, method = false, types = false }
  local wanted = required(before)
  if wanted ~= nil and state == "quoted" then
    context.what = "modules"
    context.prefix = wanted
    context.start = #before - #wanted + 1
  elseif state == "quoted" then
    return { isIncomplete = false, items = out }
  end
  -- A call is not written where the name is followed by one.
  local continues = line:sub(byte + #rest):match("^%s*%(") ~= nil
  local edit = protocol.range(lines.position(split, start + context.start - 1, encoding),
    lines.position(split, start + byte - 1, encoding))
  if context.what == "modules" then
    module_items(checker, d, uses_of(tokens), context, out, edit)
    return { isIncomplete = false, items = out }
  end
  local at = token_near(tokens, cursor - #prefix)
  local placed = Lexer.text(tokens, at) == PLACEHOLDER and Lexer.offset(tokens, at) == cursor - #prefix
  local node: Ast.Node = chunk
  local sep: Lexer.Kind = "$EOF$"
  if placed then
    node = innermost(chunk, at)
    if at > 1 then sep = Lexer.kind(tokens, at - 1) end
  end
  local last = check.last(checker, document)
  -- Where the cursor is in the text the reading is of: its byte before the cursor, then in the text the checker read. A
  -- text that is not the document's own is checked where the document does not parse (`probed`).
  local alignment: lines.Alignment? = nil
  local probed = false
  local shift = 0
  if placed and (last == nil or last.text ~= document.text) then
    local text, added = probe_text(document, spliced, parsed, tokens, at, sep, node)
    local reading: check.Reading? = nil
    if text ~= "" then reading = check.probe(checker, document, text) end
    if reading ~= nil then
      last = { reading = reading, text = text }
      probed = true
      shift = added
      alignment = lines.align(text, text)
    end
  end
  if last == nil then return { isIncomplete = false, items = out } end
  local outcome = last.reading.outcome
  local aligned = alignment or lines.align(last.text, document.text)
  local earlier = lines.earlier(aligned, cursor - 1)
  -- The probe text has the placeholder where the word is, so the cursor is at its start.
  if probed then earlier = cursor - #prefix + shift end
  local token = token_near(outcome.chunk.tokens, check.checker_offset(last.reading, math.max(earlier, 1)))
  local request: Request = { options = options, uses = uses_of(tokens), call = options.snippets and not continues,
    data = { uri = document.uri, line = where.line, character = where.character }, program = last.reading.program,
    outcome = outcome, checker = checker, text = last.text }
  local scope = Scopes.in_scope(outcome.scoped, token)
  if not placed then
    name_items(request, scope, false, context, out, edit)
    return { isIncomplete = false, items = out }
  end
  -- The names in scope in the tree the parser recovers of the text typed, where the reading is not of that text: a name
  -- bound on a line added or edited since is not the binding the reading has.
  local rebound = function(_: string): boolean return false end
  if not probed then
    local recovered = Scopes.in_scope(Scopes.build(chunk, document.name, last.reading.program:scope_globals()), at)
    local word = cursor - #prefix
    rebound = function(name: string): boolean
      local var = recovered[name]
      if var == nil then return scope[name] ~= nil end
      local offset = Lexer.offset(tokens, var.declared)
      if offset >= word + #PLACEHOLDER then
        offset = offset - #PLACEHOLDER + #prefix + #rest
      elseif offset >= word then
        offset = cursor
      end
      return aligned.same_as[lines.position(split, offset, "utf-8").line + 1] == 0
    end
  end
  if node.kind == "TypeName" and #node.path == 1 and node.path[1] == PLACEHOLDER then
    name_items(request, scope, true, context, out, edit)
  elseif sep == "." or sep == ":" then
    context.what = "members"
    context.method = sep == ":"
    context.types = node.kind == "TypeName"
    local receiver, small, delta = receiver_at(document, spliced, tokens, at - 1, context.types)
    if receiver ~= nil and small ~= nil then
      -- A receiver is found in the probe text, which the reading is of, and nothing was edited since.
      local now, moved = document.text, delta
      if probed then now, moved = last.text, delta + shift end
      local ground: Ground = { request = request, scope = scope, reading = last.reading, old = last.text, new = now,
        alignment = aligned, rebound = rebound, tokens = small, delta = moved }
      local typed = typed_node(ground, receiver)
      if typed ~= nil and typed.decl ~= nil then
        if context.types then
          nested_items(request, typed.decl, context, out, edit)
        else
          member_items(request, d, typed.decl, typed.value, context, out, edit)
        end
      end
    end
  else
    name_items(request, scope, false, context, out, edit)
  end
  return { isIncomplete = false, items = out }
end

return completion
