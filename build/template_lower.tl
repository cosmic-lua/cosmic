--- The lowering of a call that takes a template, before a module is checked. A function takes a template where its
--- first parameter is declared [`Template.Source`] and its second is the value the template reads ([`Template.text`],
--- [`Host.reply`]). Each call `M.f("...", data)` of one, where `M` is bound to the `require` of its module and the
--- template is one string literal, becomes `M.f(require("cosmic.template").fill(function(d): string ... end, data))`,
--- the function being what [`Template.inline`] makes of the template. The checker then types `d` from `data`, so a field
--- the value has not got is a type error at the call, as in a `.tmpl`, and nothing reads a template when the program
--- runs. A call of the literal alone, `M.f("...")`, stays as written where the literal has no `{{`, and is refused
--- where it has one, since a slot needs data.
---
--- Which functions take a template is read from the declarations of the modules a module requires ([`Lower.takers`]),
--- so a module that takes a template the same way declares it, and nothing here names it.
---
--- Only three places of a call change: `require("cosmic.template").fill(` goes before the literal, the literal becomes
--- the function, on as many lines as the literal took, and `)` goes after the data. Every other byte stays where it
--- was, so a line of the module is the line it was, and a place after a call on its line moves by what the call grew by
--- ([`SourceParse.original`] gives it back). A template that is refused is a problem at the literal, and the call is
--- left as written: it raises if it runs.
local Ast = require("lang.ast")
local Lexer = require("lang.lexer")
local Scopes = require("lang.scopes")

local type SourceParse = require("build.source_parse")

local record Lower
end

--- The module of templates, which declares [`Template.Source`].
local TEMPLATE <const> = "cosmic.template"

--- The module `e` requires, where `e` is `require("...")`; nil otherwise.
local function required(e: Ast.Exp): string?
  if not (e.kind == "Call") then return nil end
  local callee, named = e.callee, e.args[1]
  if callee.kind == "Name" and callee.text == "require" and #e.args == 1 and named ~= nil and named.kind == "String" then
    return named.value
  end
  return nil
end

--- The fields of `module`, whose tree is `chunk`, that are functions that take a template: each a top-level
--- `function M.f(p: T.Source, data?: any)`, where `T` is bound to `require("cosmic.template")` (or is the module's own
--- record, in [`cosmic.template`]). The data is optional and of any type, since a lowered call gives the function the
--- template filled and no data.
function Lower.takers(module: string, chunk: Ast.Chunk): {string: boolean}
  local out: mut {string: boolean} = {}
  local templates: mut {string: boolean} = {}
  for _, s in ipairs(chunk.body.stats) do
    if s.kind == "Local" then
      for i, b in ipairs(s.bindings) do
        local v = s.values[i]
        if v ~= nil and required(v) == TEMPLATE then templates[b.name] = true end
      end
    elseif s.kind == "Function" and #s.path == 2 and #s.fn.params == 2 then
      local first, second = s.fn.params[1], s.fn.params[2]
      local ty, data = first.type, second.type
      local any = data ~= nil and data.kind == "TypeName" and #data.path == 1 and data.path[1] == "any"
      if second.optional and any and ty ~= nil and ty.kind == "TypeName" and #ty.path == 2 and ty.path[2] == "Source" then
        local t = ty.path[1]
        if templates[t] == true or (module == TEMPLATE and t == s.path[1].text) then
          out[s.path[2].text] = true
        end
      end
    end
  end
  return out
end

--- Calls `visit` with each node under `root`, `root` first.
local function walk(root: Ast.Node, visit: function(Ast.Node))
  local stack: mut {Ast.Node} = { root }
  while #stack > 0 do
    local node = assert(stack[#stack], "the stack is not empty")
    stack[#stack] = nil
    visit(node)
    local children: mut {Ast.Node} = {}
    Ast.children(node, function(child: Ast.Node) children[#children + 1] = child end)
    for i = #children, 1, -1 do
      stack[#stack + 1] = assert(children[i], "a child the walk gave")
    end
  end
end

--- Where the template's `line` and `column` are in the source, for a literal whose token is `at`: line 1 begins after
--- the literal's opening quote or bracket. A column after an escape is near, not exact.
local function source_place(tokens: Lexer.Tokens, at: integer, line: integer, column: integer): (integer, integer)
  local raw = Lexer.text(tokens, at)
  local y, x = Lexer.y(tokens, at), Lexer.x(tokens, at)
  local open = raw:match("^%[=*%[") or raw:sub(1, 1)
  -- A long string drops a newline that directly follows its opening.
  local skips = raw:sub(#open + 1, #open + 1) == "\n" and #open > 1
  if skips then
    return y + line, column
  end
  if line == 1 then
    return y, x + #open + column - 1
  end
  return y + line - 1, column
end

--- `text`, whose tree is `chunk`, with each call of a literal to a function that takes a template lowered; nil where
--- the module has none. `takes` says which functions of the modules it requires take one. `name` heads the reasons.
function Lower.lower(text: string, name: string, chunk: Ast.Chunk, takes: SourceParse.Takes): SourceParse.Lowered?
  -- A call of a string literal to a field of a name bound to a `require`, or of a `require` itself, by the names: what
  -- is looked at before the scopes are built, which most modules need not.
  -- A local anywhere in the module that is bound to a `require` may hold a module whose function takes a template.
  local requires: mut {string: mut {string}} = {}
  walk(chunk, function(node: Ast.Node)
    if node.kind == "Local" then
      for i, b in ipairs(node.bindings) do
        local v = node.values[i]
        local module = if v ~= nil then required(v) else nil end
        if module ~= nil then
          local held: mut {string} = requires[b.name] or {}
          requires[b.name] = held
          held[#held + 1] = module
        end
      end
    end
  end)
  --- Whether a call's callee object may name a module with `field` that takes a template, by its text alone.
  local function may_take(object: Ast.Exp, field: string): boolean
    if object.kind == "Name" then
      for _, module in ipairs(requires[object.text] or {}) do
        if takes(module, field) then return true end
      end
    elseif object.kind == "Paren" then
      local module = required(object.inner)
      return module ~= nil and takes(module, field)
    end
    return false
  end
  local found = false
  walk(chunk, function(node: Ast.Node)
    if found or not (node.kind == "Call") then return end
    local callee, literal = node.callee, node.args[1]
    if callee.kind == "Field" and (#node.args == 1 or #node.args == 2) and literal ~= nil and literal.kind == "String" then
      found = may_take(callee.object, callee.name)
    end
  end)
  if not found then return nil end
  Scopes.build(chunk, name, {})
  -- The bindings that hold a module, and the module each holds.
  local holders: mut {integer: string} = {}
  walk(chunk, function(node: Ast.Node)
    if node.kind == "Local" then
      for i, b in ipairs(node.bindings) do
        local v = node.values[i]
        local module = if v ~= nil then required(v) else nil end
        if module ~= nil then holders[b.id] = module end
      end
    end
  end)
  --- A call to lower: its literal, its data, if it has any.
  local record Site
    literal: Ast.String
    data?: Ast.Exp
  end
  local calls: mut {Site} = {}
  walk(chunk, function(node: Ast.Node)
    if not (node.kind == "Call") then return end
    local callee = node.callee
    if not (callee.kind == "Field") or (#node.args ~= 1 and #node.args ~= 2) then return end
    local object = callee.object
    local module: string? = nil
    if object.kind == "Name" then
      local binding = object.binding
      module = if binding ~= nil then holders[binding] else nil end
    elseif object.kind == "Paren" then
      module = required(object.inner)
    end
    local literal = node.args[1]
    if module ~= nil and literal ~= nil and literal.kind == "String" and takes(module, callee.name) then
      calls[#calls + 1] = { literal = literal, data = node.args[2] }
    end
  end)
  if #calls == 0 then return nil end
  local Template = require("cosmic.template")
  local tokens = chunk.tokens
  local splices: mut {SourceParse.Splice} = {}
  local refused: mut {SourceParse.Refused} = {}
  for _, call in ipairs(calls) do
    local literal = call.literal
    local data = call.data
    local at = literal.first
    local y = Lexer.y(tokens, at)
    local made, why = Template.inline(literal.value, name .. ":" .. tostring(y))
    if data == nil and literal.value:find("{{", 1, true) == nil then
      -- No slot and no data: the text is the template as it is, and the call stays as written.
    elseif data == nil then
      refused[#refused + 1] = { message = "the template has slots and no data: give the value its slots read " ..
          "as the second argument", y = y, x = Lexer.x(tokens, at), offset = Lexer.offset(tokens, at),
        length = Lexer.length(tokens, at) }
    elseif made == nil then
      local ty, tx = source_place(tokens, at, why.line or 1, why.column or 1)
      refused[#refused + 1] = { message = why.message, y = ty, x = tx, offset = Lexer.offset(tokens, at),
        length = Lexer.length(tokens, at) }
    else
      -- The function takes as many lines as the literal: one where it is one line, else line N on line N.
      local raw = Lexer.text(tokens, at)
      local _, lines = raw:gsub("\n", "")
      local body = made
      if raw:find("^%[=*%[\n") ~= nil then
        body = "\n" .. made
      end
      local _, made_lines = body:gsub("\n", "")
      if made_lines ~= lines then
        -- The template's lines are not the literal's (a `\n` escape, a `\` before a newline): one line, then the
        -- literal's newlines, so the lines after the call stay where they were.
        body = made:gsub("\n", " ") .. string.rep("\n", lines)
      end
      splices[#splices + 1] = { offset = Lexer.offset(tokens, at), length = Lexer.length(tokens, at),
        text = 'require("' .. TEMPLATE .. '").fill(' .. body }
      local after = Lexer.offset(tokens, data.last) + Lexer.length(tokens, data.last)
      splices[#splices + 1] = { offset = after, length = 0, text = ")" }
    end
  end
  table.sort(splices, function(a: SourceParse.Splice, b: SourceParse.Splice): boolean
    return a.offset < b.offset
  end)
  local parts: mut {string} = {}
  local from = 1
  for _, s in ipairs(splices) do
    parts[#parts + 1] = text:sub(from, s.offset - 1)
    parts[#parts + 1] = s.text
    from = s.offset + s.length
  end
  parts[#parts + 1] = text:sub(from)
  return { text = table.concat(parts), splices = splices, refused = refused }
end

return Lower
