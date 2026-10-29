--- The scopes of a chunk as [`build.syntax_analyzer`]'s references through an alias and [`build.link_text`]'s names a comment
--- sees read them, over [`lang.scopes`]: the bindings it resolved, with where each is in scope, and each `alias.member`
--- whose `alias` is still the module a direct `require` bound.
---
--- [`lang.scopes`] decides what a name refers to; this module only puts its answer in the two shapes those readers ask
--- for, so the one place that decides is the scope builder. It requires nothing of the analyzer's own, so what reaches
--- link_text (the writer's identity, [`build.work`]) does not reach the analyzer.
local Ast = require("lang.ast")
local Lexer = require("lang.lexer")
local Node = require("build.syntax_node")
local Resolved = require("lang.scopes")

local record Lexical
  --- A name a block binds, and the places it is in scope, from [`position`] `from` to `to`: from past the statement
  --- that declares it (from its name, for a function's or a type's, which its own body sees; from itself, for a
  --- parameter or a loop's variable) to the end of the block that binds it (`math.maxinteger` for the chunk's own).
  record Binding
    name: string
    --- The module a `local name = require("m")` binds it to; "" for any other binding.
    module: string
    from: integer
    to: integer
    --- The start of the line of the statement that declares it, where a doc comment above that statement stands
    --- ([`in_scope`]'s `heading`); 0 for a parameter or a loop's variable.
    head: integer
    --- Whether the chunk's own block binds it.
    top: boolean
    --- Whether its declaration gives it a type of its own (`local B: T = require("m")`), which a type written `B.X`
    --- names instead of the module's.
    annotated: boolean
  end

  --- A place in the source as one integer, ordered as the places are: columns stay below 2^20.
  position: function(y: integer, x: integer): integer

  --- Every name `chunk` binds, which `scoped` resolved: each local, local function, type declaration, parameter, loop
  --- variable and `match` binding, at any depth, with where its scope starts and ends, in the order the scope builder
  --- declared them. Ask it once of a file and [`Lexical.in_scope`] of it for each place.
  bindings_of: function(chunk: Ast.Chunk, scoped: Resolved.Scoped): {Binding}

  --- As [`Lexical.bindings_of`], and, with `member`, each `alias.member` whose `alias` still resolves to a lexical
  --- direct require binding and each `require("module").member` while `require` is not shadowed, handed to it with the
  --- line it is on. An assignment to the alias ends the reads that count, from the end of its statement, wherever
  --- the assignment is.
  walk: function(chunk: Ast.Chunk, scoped: Resolved.Scoped,
                 member: (function(module: string, name: string, line: integer))?): {Binding}

  --- The names `bindings` holds in scope at line `y`, column `x`, each with the module it is an alias of, or "": the
  --- innermost binding of each, as Lua reads it there. With `heading`, the place is a doc comment's above a statement
  --- starting on line `y`, which sees the names that statement declares too.
  in_scope: function(bindings: {Binding}, y: integer, x: integer, heading: boolean): {string: string}
end

function Lexical.position(y: integer, x: integer): integer
  return y * 1048576 + x
end

--- What a binding of the declared kinds is for the readers: a name a block binds. A type parameter, a type nested in
--- another and a global of a declaration file are no binding of a block.
local function counted(v: Resolved.Var): boolean
  return v.kind ~= "typeparam" and not v.nested and not v.exported
end

--- What the statements say of the bindings they declare.
local record Declared
  head: integer
  annotated: boolean
end

local function declared_by(chunk: Ast.Chunk): {integer: Declared}
  local out: mut {integer: Declared} = {}
  Node.walk(chunk, function(node: Ast.Node)
    local function head_of(): integer
      return Lexical.position(Lexer.y(chunk.tokens, Node.base(node).first), 0)
    end
    if (node.kind == "Local") then
      for i, b in ipairs(node.bindings) do
        out[Node.base(b).id] = { head = head_of(), annotated = node.types[i] ~= nil }
      end
    elseif (node.kind == "LocalFunction") then
      out[Node.base(node.name).id] = { head = head_of(), annotated = false }
    else
      local declared = Node.declared(node)
      if declared ~= nil then
        out[Node.base(declared.name).id] = { head = head_of(), annotated = false }
      end
    end
  end)
  return out
end

function Lexical.bindings_of(chunk: Ast.Chunk, scoped: Resolved.Scoped): {Lexical.Binding}
  local declared = declared_by(chunk)
  local tokens = chunk.tokens
  local out: mut {Lexical.Binding} = {}
  for _, v in ipairs(scoped.list) do
    if counted(v) then
      -- A loop's variable is in scope from its own name, as a parameter is: the header's iterators see it.
      local from = v.kind == "loop" and v.declared or v.from
      local here = declared[v.id]
      local limit = math.maxinteger
      if not v.top then
        limit = Lexical.position(Lexer.yend(tokens, v.to), Lexer.xend(tokens, v.to))
      end
      local start = Lexical.position(Lexer.y(tokens, from), Lexer.x(tokens, from))
      if v.kind == "local" and (v.from == v.to or tokens.kind[from] == "$EOF$") then
        -- The last local of a block is in scope from the end of the word that closes it, and the chunk's last from nowhere.
        start = tokens.kind[from] == "$EOF$" and math.maxinteger or
          Lexical.position(Lexer.yend(tokens, from), Lexer.xend(tokens, from))
      end
      out[#out + 1] = {
        name = v.name, module = v.module, from = start, to = limit,
        head = here ~= nil and here.head or 0, top = v.top, annotated = here ~= nil and here.annotated,
      }
    end
  end
  return out
end

--- A read `object.name` found, to settle once every assignment is known.
local record Read
  var: integer
  module: string
  name: string
  line: integer
  token: integer
end

function Lexical.walk(chunk: Ast.Chunk, scoped: Resolved.Scoped,
                      member: (function(module: string, name: string, line: integer))?): {Lexical.Binding}
  local bindings = Lexical.bindings_of(chunk, scoped)
  if member == nil then
    return bindings
  end
  local reads: mut {Read} = {}
  -- The token an assignment to each variable ends at, the first.
  local ends: mut {integer: integer} = {}
  -- What an assignment's targets hold is written, not read: `Fs.stderr = fd` is no reference to `stderr`.
  local written: mut {integer: boolean} = {}
  Node.walk(chunk, function(node: Ast.Node)
    if (node.kind == "Assign") then
      for _, target in ipairs(node.targets) do
        Node.walk(target, function(under: Ast.Node)
          written[Node.base(under).id] = true
        end)
        if (target.kind == "Name") then
          local bound = target.binding
          if bound ~= nil then
            local held = ends[bound]
            local last = Node.base(node).last
            if held == nil or last < held then
              ends[bound] = last
            end
          end
        end
      end
    elseif (node.kind == "Field") and written[Node.base(node).id] ~= true then
      local object = node.object
      local line = assert(chunk.tokens.y[Node.base(object).first])
      if (object.kind == "Name") then
        local bound = object.binding
        local v = if bound ~= nil then scoped.vars[bound] else nil end
        if v ~= nil and v.module ~= "" then
          table.insert(reads, { var = v.id, module = v.module, name = node.name, line = line, token = Node.base(node).first })
        end
      elseif (object.kind == "Call") then
        local callee = object.callee
        local only = object.args[1]
        if (callee.kind == "Name") and callee.text == "require" and callee.binding == nil and #object.args == 1 and
            only ~= nil and (only.kind == "String") then
          table.insert(reads, { var = 0, module = only.value, name = node.name, line = line, token = Node.base(node).first })
        end
      end
    end
  end)
  for _, read in ipairs(reads) do
    local ended = ends[read.var]
    if read.var == 0 or ended == nil or read.token <= ended then
      member(read.module, read.name, read.line)
    end
  end
  return bindings
end

function Lexical.in_scope(bindings: {Lexical.Binding}, y: integer, x: integer, heading: boolean): {string: string}
  local at = Lexical.position(y, x)
  local line = Lexical.position(y, 0)
  local out: mut {string: string} = {}
  local from: mut {string: integer} = {}
  for _, each in ipairs(bindings) do
    local seen = each.from <= at or heading and each.head == line
    local prior = from[each.name]
    if seen and at <= each.to and (prior == nil or each.from >= prior) then
      out[each.name] = each.module
      from[each.name] = each.from
    end
  end
  return out
end

return Lexical
