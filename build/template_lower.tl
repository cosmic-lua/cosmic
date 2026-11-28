--- The lowering of [`Template.text`] before a module is checked: each call `T.text("...", data)`, where `T` is bound to
--- `require("cosmic.template")` and the template is one string literal, becomes `T.apply(function(d): string ... end,
--- data)`, the function being what [`Template.inline`] makes of the template. The checker then types `d` from `data`,
--- so a field the value has not got is a type error at the call, as in a `.tmpl`, and nothing reads a template when the
--- program runs.
---
--- Only two places of a call change: the field `text` becomes `apply`, and the literal becomes the function, on as
--- many lines as the literal took. Every other byte stays where it was, so a line of the module is the line it was,
--- and a place after a call on its line moves by what the call grew by ([`SourceParse.original`] gives it back). A template
--- that is refused is a problem at the literal, and the call is left as written: it raises if it runs.
local Ast = require("lang.ast")
local Lexer = require("lang.lexer")
local Scopes = require("lang.scopes")

local type SourceParse = require("build.source_parse")

local record Lower
end

--- Whether `e` is `require("cosmic.template")`.
local function requires_template(e: Ast.Exp): boolean
  if not (e.kind == "Call") then return false end
  local callee, named = e.callee, e.args[1]
  return callee.kind == "Name" and callee.text == "require" and #e.args == 1 and named ~= nil and named.kind == "String" and
    named.value == "cosmic.template"
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

--- `text`, whose tree is `chunk`, with each [`Template.text`] call of a literal lowered; nil where the module has none.
--- Only a module that requires [`cosmic.template`] is looked at. `name` heads the reasons.
function Lower.lower(text: string, name: string, chunk: Ast.Chunk): SourceParse.Lowered?
  local wanted = false
  for _, r in ipairs(chunk.requires) do
    if r.module == "cosmic.template" then wanted = true end
  end
  if not wanted then return nil end
  Scopes.build(chunk, name, {})
  -- The bindings that hold the module.
  local holders: mut {integer: boolean} = {}
  walk(chunk, function(node: Ast.Node)
    if node.kind == "Local" then
      for i, b in ipairs(node.bindings) do
        local v = node.values[i]
        if v ~= nil and requires_template(v) then holders[b.id] = true end
      end
    end
  end)
  --- A call to lower: the token of its field `text`, and its literal.
  local record Site
    field: integer
    literal: Ast.String
  end
  local calls: mut {Site} = {}
  walk(chunk, function(node: Ast.Node)
    if not (node.kind == "Call") then return end
    local callee = node.callee
    if not (callee.kind == "Field") or callee.name ~= "text" or #node.args ~= 2 then return end
    local object = callee.object
    local held = false
    if object.kind == "Name" then
      local binding = object.binding
      held = binding ~= nil and holders[binding] == true
    elseif object.kind == "Paren" then
      held = requires_template(object.inner)
    end
    local literal = node.args[1]
    if held and literal ~= nil and literal.kind == "String" then
      calls[#calls + 1] = { field = callee.last, literal = literal }
    end
  end)
  if #calls == 0 then return nil end
  local Template = require("cosmic.template")
  local tokens = chunk.tokens
  local splices: mut {SourceParse.Splice} = {}
  local refused: mut {SourceParse.Refused} = {}
  for _, call in ipairs(calls) do
    local literal = call.literal
    local at = literal.first
    local y = Lexer.y(tokens, at)
    local made, why = Template.inline(literal.value, name .. ":" .. tostring(y))
    if made == nil then
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
      local field = call.field
      splices[#splices + 1] = { offset = Lexer.offset(tokens, field), length = Lexer.length(tokens, field),
        text = "apply" }
      splices[#splices + 1] = { offset = Lexer.offset(tokens, at), length = Lexer.length(tokens, at), text = body }
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
