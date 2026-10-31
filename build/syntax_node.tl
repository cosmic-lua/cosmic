--- Reading source into the new checker's syntax tree for the `build/` readers: [`lang.lexer`] and [`lang.parser`]
--- ([`lang.ast`]), and [`lang.scopes`] for the readers that need to know which binding a name refers to; walking it,
--- where a node is, its parent, and the modules a file requires. The tree is a range of tokens for each node, so a place
--- is read from the tokens ([`Ast.span`]) and a node holds no parent: [`Node.parents`] makes the map for a reader that
--- asks. Walks keep their own stack, so a chain of any length ([`Ast.number`]) is walked.
---
--- The readers named `build.syntax_*` work on the tree: a reader takes the
--- tree and its tokens, never the compiler. Each replaced a reader of the same name
--- of the fork's tree ([`build/syntax_scopes.tl`] for its scopes, [`build/syntax_node.tl`] for its walks and requires).
local Ast = require("lang.ast")
local Lexer = require("lang.lexer")
local Parser = require("lang.parser")
local Scopes = require("lang.scopes")

local record Node
  --- The name and the scope of a type declaration: a record, interface, class, enum, alias or import.
  record Declared
    name: Ast.Binding
    scope: Ast.Scope?
  end

  --- What every node holds: its kind, its tokens and its id.
  base: function(node: Ast.Node): Ast.Base

  --- The tree of `source`, a program (`tl`) or, for a file named `*.d.tl` when `dialect` is not given, a declaration
  --- file. nil and the first error, worded `file:line:column: message (code): fix`, where the source has one: a
  --- reader works on a tree that is whole.
  parse: function(source: string, name: string, dialect?: Ast.Dialect): Ast.Chunk?, string

  --- The names of `chunk` resolved against the globals `declared`, none by default: it sets `binding` on each
  --- [`Ast.Name`] that refers to a binding and answers the facts. The chunk must come from [`Node.parse`].
  scope: function(chunk: Ast.Chunk, name: string, declared?: {string: Scopes.Global}): Scopes.Scoped

  --- The line and column where `node` starts, and the line and column of its last byte.
  span: function(chunk: Ast.Chunk, node: Ast.Node): Ast.Span

  --- The declaration `node` is, if it declares a type.
  declared: function(node: Ast.Node): Declared?
  --- A range of bytes of the source, 1-based and inclusive.
  record Range
    first: integer
    last: integer
  end

  --- Calls `visit` with each node of the tree under `root`, `root` first, in source order (pre-order, which is the
  --- order of the nodes' ids).
  walk: function(root: Ast.Node, visit: function(Ast.Node))

  --- As [`Node.walk`], and where `visit` answers false the nodes under that node are not visited.
  walk_until: function(root: Ast.Node, visit: function(Ast.Node): boolean)

  --- The nodes directly under `node`, in source order.
  children: function(node: Ast.Node): {Ast.Node}

  --- The parent of each node under `root` and of `root` itself where it has one, by node id. The chunk's numbering
  --- ([`Ast.number`]) keys it, so the tree must come from [`lang.parser`].
  parents: function(root: Ast.Node): {integer: Ast.Node}

  --- The bytes of `node`, 1-based and inclusive: its first byte and its last. A node of no token (a failed
  --- production) is empty at the token it stands before, and its last byte is the one before its first.
  range: function(chunk: Ast.Chunk, node: Ast.Node): Range

  --- Every module `chunk` requires, in source order, each name once: the literal `require("m")` and
  --- `pcall(require, "m")` calls anywhere in the file and the type imports (`local type T = require("m")`), whether or
  --- not they feed a top-level local, so that `store = require("cosmic.internal.store")` in a branch, a probe for a
  --- module that may be absent and a type-only import are dependencies as well. A call whose name is no string literal
  --- contributes nothing, since its target is unknown until the program runs: the parser refuses one
  --- (`computed_require`), so a tree that parses has none. Text in a string or a comment is no call.
  --- [`build.importer`] builds its import order and the recompilation key from this.
  requires: function(chunk: Ast.Chunk): {string}

  --- A `require` of a module: the module it names, and the line and column of the string that names it.
  record Site
    name: string
    y: integer
    x: integer
  end

  --- Every module `chunk` requires, as [`Node.requires`] finds them, each at its first call or import (line and column
  --- 0 where the tree holds no such node).
  require_sites: function(chunk: Ast.Chunk): {Site}
end

function Node.base(node: Ast.Node): Ast.Base
  return node
end

function Node.declared(node: Ast.Node): Node.Declared?
  if (node.kind == "Record") then
    return { name = node.name, scope = node.scope }
  elseif (node.kind == "Interface") then
    return { name = node.name, scope = node.scope }
  elseif (node.kind == "Class") then
    return { name = node.name, scope = node.scope }
  elseif (node.kind == "Enum") then
    return { name = node.name, scope = node.scope }
  elseif (node.kind == "Alias") then
    return { name = node.name, scope = node.scope }
  elseif (node.kind == "Import") then
    return { name = node.name, scope = node.scope }
  end
  return nil
end

function Node.parse(source: string, name: string, dialect?: Ast.Dialect): Ast.Chunk?, string
  local kind: Ast.Dialect = "tl"
  if dialect ~= nil then
    kind = dialect
  elseif name:find("%.d%.tl$") ~= nil then
    kind = "decl"
  end
  local parsed = Parser.parse(Lexer.lex(source, name), name, kind)
  local first = parsed.errors[1]
  if first ~= nil then
    return nil, name .. ":" .. tostring(first.y) .. ":" .. tostring(first.x) .. ": " .. first.msg .. " (" ..
      tostring(first.code) .. "): " .. first.fix
  end
  return parsed.chunk, ""
end

function Node.scope(chunk: Ast.Chunk, name: string, declared?: {string: Scopes.Global}): Scopes.Scoped
  return Scopes.build(chunk, name, declared or {})
end

function Node.span(chunk: Ast.Chunk, node: Ast.Node): Ast.Span
  return Ast.span(chunk, node)
end

function Node.children(node: Ast.Node): {Ast.Node}
  local out: mut {Ast.Node} = {}
  Ast.children(node, function(child: Ast.Node)
    out[#out + 1] = child
  end)
  return out
end

function Node.walk_until(root: Ast.Node, visit: function(Ast.Node): boolean)
  local stack: mut {Ast.Node} = { root }
  -- One buffer for each node's children, emptied as they go on the stack, rather than a table made for each node: a walk
  -- of a tree meets every node, and a build walks every tree several times.
  local kids: mut {Ast.Node} = {}
  local function push(child: Ast.Node)
    kids[#kids + 1] = child
  end
  while #stack > 0 do
    local node = stack[#stack]
    stack[#stack] = nil
    if visit(node) then
      Ast.children(node, push)
      -- The children are met in source order and go on in the reverse, so that the first is the next node taken.
      while true do
        local child = table.remove(kids)
        if child == nil then
          break
        end
        stack[#stack + 1] = child
      end
    end
  end
end

function Node.walk(root: Ast.Node, visit: function(Ast.Node))
  Node.walk_until(root, function(node: Ast.Node): boolean
    visit(node)
    return true
  end)
end

function Node.parents(root: Ast.Node): {integer: Ast.Node}
  local out: mut {integer: Ast.Node} = {}
  Node.walk(root, function(node: Ast.Node)
    Ast.children(node, function(child: Ast.Node)
      out[Node.base(child).id] = node
    end)
  end)
  return out
end

function Node.range(chunk: Ast.Chunk, node: Ast.Node): Node.Range
  local base = Node.base(node)
  local tokens = chunk.tokens
  local first = assert(tokens.offset[base.first], "every token has an offset")
  if base.last < base.first then
    return { first = first, last = first - 1 }
  end
  return { first = first, last = Lexer.stop(tokens, base.last) - 1 }
end

function Node.require_sites(chunk: Ast.Chunk): {Node.Site}
  local found: mut {Ast.Require} = {}
  local wanted: mut {integer: boolean} = {}
  for _, r in ipairs(chunk.requires) do
    found[#found + 1] = r
    wanted[r.node] = true
  end
  table.sort(found, function(a: Ast.Require, b: Ast.Require): boolean
    return a.node < b.node
  end)
  local nodes: mut {integer: Ast.Base} = {}
  Node.walk(chunk, function(node: Ast.Node)
    local base = Node.base(node)
    if wanted[base.id] == true then nodes[base.id] = base end
  end)
  local seen: mut {string: boolean} = {}
  local out: mut {Node.Site} = {}
  for _, r in ipairs(found) do
    if seen[r.module] == nil then
      seen[r.module] = true
      -- The module's name is the first string of the call or the import: `require("m")` is all of a call, and an
      -- import's name and `=` come before it.
      local y, x = 0, 0
      local base = nodes[r.node]
      if base ~= nil then
        for k = base.first, base.last do
          if chunk.tokens.kind[k] == "string" then
            y, x = Lexer.y(chunk.tokens, k), Lexer.x(chunk.tokens, k)
            break
          end
        end
      end
      out[#out + 1] = { name = r.module, y = y, x = x }
    end
  end
  return out
end

function Node.requires(chunk: Ast.Chunk): {string}
  local out: mut {string} = {}
  for _, site in ipairs(Node.require_sites(chunk)) do
    out[#out + 1] = site.name
  end
  return out
end

return Node
