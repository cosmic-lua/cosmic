--- Completion for `cosmic lsp` ([`build.lsp.session`]): what can be typed at the cursor.
---
--- What it offers, by what the text before the cursor on its line says:
---
--- - Inside `require("`: the modules the working database lists ([`source.View`]'s `modules`) and the public modules the docs
---   know, whose names start with what is typed.
--- - After `x.` or `x:`, where `x` is a name, or names joined by dots (`a.b.c`): the members of the type the receiver has. A
---   local, a parameter, a function or a type of the document, a module it requires and a global of the standard library
---   may head the chain. `.` offers a record's or class's fields and methods, an interface's (its own and those of the
---   interfaces it lists), the functions of a module or of a declaration used as a value, and an enum's values; `:` offers the
---   methods. A member's `detail` is its signature in the docs where they have it, else its type. Its `documentation` is the
---   docs' text of the same symbol, for a type of another module; the members themselves are the checker's declarations of
---   that module, which an open document or the stage's stub gives ([`build.lsp.source`]), so an unsaved module is
---   completed as the person has it.
--- - After a `:` and a space, a type position: the types in scope and the primitive types.
--- - Anywhere else, the names in scope: the locals, parameters, functions and types visible at the cursor
---   ([`Scopes.in_scope`]), then the globals of the standard library.
---
--- Names and members come from the document's last check that parsed ([`check.last`]): a text being typed (`p.`) does not
--- parse, so the cursor is placed in that text by what the two texts share, and the receiver is read from the line, as
--- written. A name declared in the text typed since is not offered. Nothing is offered in a comment or a string, or in a
--- document the checker read nothing of.

-- TODO: offer the names of a type position in all of them (after `is`, `<`, `{`, `->`, in a `local type` and a
-- `record ... is`), and the types nested in a record after `point.` in one, once the line is read by the parser's token
-- before the cursor (the partial expression it recovers) rather than by a pattern: only a `:` and a space is a type
-- position here.

-- TODO: take a receiver that is a call or an index (`f().x`, `a[1].x`) and the type of a name narrowed at the cursor, once
-- completion reads the partial expression the parser recovers: the receiver is only a name or names joined by dots, typed
-- as they were declared.

-- TODO: tell a comment or a string that spans lines (`--[[ ]]`, `[[ ]]`) from code, once the cursor's token is read from the
-- lexer: only a `--` or a quote before the cursor on its line is told.

-- TODO: offer the documentation of the members of the document's own module and of a module edited and unsaved, once the
-- derivation writes the docs rows of the scratch database ([`source.places`]): the docs are the last build's, so a member
-- the person has not built has none.

-- TODO: rank the items by how near they are and what was used (`sortText`), fill in `documentation` and `detail` at
-- `completionItem/resolve`, and offer snippets for a call's parameters, once a request needs them: names are ordered by
-- the depth of their scope and then by name, and every item carries its text.

local Declarations = require("lang.declarations")
local Driver = require("build.driver")
local Lexer = require("lang.lexer")
local Report = require("build.syntax_report")
local Scopes = require("lang.scopes")
local Types = require("lang.types")
local check = require("build.lsp.check")
local docs = require("build.docs")
local hover = require("build.lsp.hover")
local lines = require("build.lsp.lines")
local protocol = require("build.lsp.protocol")

local record completion
  --- What the text before the cursor says is typed.
  record Context
    --- "modules", "members", "types" or "names".
    what: string
    --- The part of the name typed already, and the byte of the line it starts at.
    prefix: string
    start: integer
    --- For "members": the names the receiver is, and whether the separator is `:`.
    chain: {string}
    method: boolean
  end

  --- A member of a declaration.
  record Member
    name: string
    --- Nil for an enum's value.
    type: Types.Type?
    method: boolean
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

--- Whether the end of `before`, the line up to the cursor, is in a comment or a string of its line.
local function quoted_or_commented(before: string): boolean
  local quote: string? = nil
  local at = 1
  while at <= #before do
    local c = before:sub(at, at)
    if quote ~= nil then
      if c == "\\" then
        at = at + 1
      elseif c == quote then
        quote = nil
      end
    elseif c == '"' or c == "'" then
      quote = c
    elseif c == "-" and before:sub(at + 1, at + 1) == "-" then
      return true
    end
    at = at + 1
  end
  return quote ~= nil
end

--- What is typed at the end of `before`, the line up to the cursor, or nil where nothing is to be completed.
local function context_of(before: string): Context?
  local quote, wanted = before:match("require%s*%(?%s*([\"'])([%w_%.%-]*)$")
  if quote ~= nil and wanted ~= nil then
    return { what = "modules", prefix = wanted, start = #before - #wanted + 1, chain = {}, method = false }
  end
  if quoted_or_commented(before) then return nil end
  local word = before:match("[%a_][%w_]*$") or ""
  local head = before:sub(1, #before - #word)
  local start = #head + 1
  local sep = head:sub(-1)
  if (sep == "." and head:sub(-2) ~= "..") or (sep == ":" and head:sub(-2) ~= "::") then
    local receiver = head:sub(1, -2)
    local expr = receiver:match("[%a_][%w_%.]*$")
    if expr == nil then return nil end
    -- The end of a call, an index or a string is a receiver this does not read.
    local beyond = receiver:sub(#receiver - #expr, #receiver - #expr)
    if beyond:match("[%w_%)%]}\"'%.:]") ~= nil then return nil end
    local chain: mut {string} = {}
    for name in (expr .. "."):gmatch("([^%.]*)%.") do
      if name:match("^[%a_][%w_]*$") == nil then return nil end
      chain[#chain + 1] = name
    end
    return { what = "members", prefix = word, start = start, chain = chain, method = sep == ":" }
  end
  if head:match(":%s+$") ~= nil and head:match("::%s*$") == nil then
    return { what = "types", prefix = word, start = start, chain = {}, method = false }
  end
  return { what = "names", prefix = word, start = start, chain = {}, method = false }
end

--- Whether `name` starts with what was typed, in either case.
local function matches(name: string, prefix: string): boolean
  return name:sub(1, #prefix):lower() == prefix:lower()
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
    out[#out + 1] = { name = name, type = t, method = method }
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

--- The declaration the name `name` is at the token of the request, and whether it is used as a value: a binding in scope, else
--- a global of the standard library.
local function head_of(request: Request, scope: {string: Scopes.Var}, name: string): Types.Decl?, boolean
  local program = request.program
  local var = scope[name]
  if var ~= nil then
    local checked = request.outcome.checked
    local t: Types.Type? = nil
    if checked ~= nil then t = checked.vars[var.id] end
    local typed, value = receiver_of(t)
    if typed ~= nil then return typed, value end
    local lowered = request.outcome.lowered
    if lowered ~= nil then
      local entry = lowered.entries[var.id]
      if entry ~= nil and entry.decl ~= nil then return entry.decl, true end
    end
    if var.module ~= "" then
      local root = Report.root_of(program, var.module)
      if root ~= nil then return root, true end
    end
    return nil, false
  end
  local entry = program.globals[name]
  if entry ~= nil and entry.decl ~= nil then return entry.decl, true end
  local overloads = program.values[name]
  if overloads ~= nil then return receiver_of(overloads[1]) end
  return nil, false
end

--- The declaration `chain` names, with the members of each name read from the one before.
local function receiver_decl(request: Request, scope: {string: Scopes.Var}, chain: {string}): Types.Decl?, boolean
  local first = chain[1]
  if first == nil then return nil, false end
  local decl, value = head_of(request, scope, first)
  for at = 2, #chain do
    if decl == nil then return nil, false end
    local want = chain[at]
    local found: Types.Type? = nil
    for _, member in ipairs(members_of(request.program, decl, value)) do
      if member.name == want then found = member.type end
    end
    decl, value = receiver_of(found)
  end
  return decl, value
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

--- The kind of item a member is.
local function member_kind(member: Member): integer
  local t = member.type
  if t == nil then return ENUM_MEMBER end
  if member.method then return METHOD end
  if t.tag == "fn" then return FUNCTION end
  return FIELD
end

--- The members offered after a separator.
local function member_items(request: Request, d: hover.Docs, decl: Types.Decl, value: boolean, context: Context,
                            out: mut {protocol.CompletionItem}, edit: protocol.Range)
  local members = members_of(request.program, decl, value)
  local wanted: mut {Member} = {}
  for _, member in ipairs(members) do
    -- A `:` reads a method.
    if matches(member.name, context.prefix) and (not context.method or member.method) then
      wanted[#wanted + 1] = member
    end
  end
  local entries = documented(request, d, decl, wanted)
  for _, member in ipairs(wanted) do
    local entry = entries[member.name]
    local t = member.type
    local detail: string? = nil
    if entry ~= nil and entry.signature ~= "" then
      detail = entry.signature
    elseif t ~= nil then
      detail = Types.display(t)
    end
    local item: protocol.CompletionItem = { label = member.name, kind = member_kind(member), detail = detail,
      documentation = markup(entry), sortText = nil, textEdit = { range = edit, newText = member.name } }
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
local function name_items(request: Request, scope: {string: Scopes.Var}, context: Context,
                          out: mut {protocol.CompletionItem}, edit: protocol.Range)
  local types = context.what == "types"
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

--- The completions at `where` of `document`, whose characters count in `encoding`'s units: nil where nothing is open there.
--- An empty list is a place where nothing can be typed, or nothing is known.
function completion.at(checker: check.Checker, d: hover.Docs, document: check.Document, where: protocol.Position,
                       encoding: string): protocol.CompletionList?
  local split = lines.lines_of(document.text)
  local line = split.texts[where.line + 1]
  local start = split.starts[where.line + 1]
  if line == nil or start == nil then return nil end
  local byte = lines.byte_of(line, where.character, encoding)
  local context = context_of(line:sub(1, byte - 1))
  local out: mut {protocol.CompletionItem} = {}
  if context == nil then return { isIncomplete = false, items = out } end
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
  local before = earlier_count(last.text, document.text, start + byte - 2)
  local token = token_near(outcome.chunk.tokens, check.checker_offset(last.reading, math.max(before, 1)))
  local request: Request = { program = last.reading.program, outcome = outcome }
  local scope = Scopes.in_scope(outcome.scoped, token)
  if context.what == "members" then
    local decl, value = receiver_decl(request, scope, context.chain)
    if decl ~= nil then member_items(request, d, decl, value, context, out, edit) end
  else
    name_items(request, scope, context, out, edit)
  end
  return { isIncomplete = false, items = out }
end

return completion
