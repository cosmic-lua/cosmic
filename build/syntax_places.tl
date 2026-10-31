--- Where a source declares the types and the members of types that another module can name, read off its syntax tree: the
--- rows of `places` ([`build.work`]), which `cosmic lsp`'s go to definition looks a declaration up in
--- ([`build.lsp.source`]'s `places`) in place of reading the module again, and which it reads off the text of an open
--- document that differs from the staged file ([`build.lsp.definition`]).
---
--- A symbol is the dotted path from the top of the module: a type `R`, one nested in it `R.Inner`, a field or method `R.f`,
--- and a `function R.f` statement, which adds to the type `R` outside its declaration. A type declared in a `do` block of
--- the module has the path from that block. Declared members come before the `function` statements, so that the first of
--- a symbol's places is the one a declaration gives and not an addition to it.
local Ast = require("lang.ast")
local Lexer = require("lang.lexer")

local record Places
  --- What a place declares.
  enum Form
    "type"
    "field"
    "method"
    "function"
  end

  --- One declaration: its dotted `symbol`, and its name's token in the chunk, at `line` and `column` (1-based, a column
  --- counts bytes, as [`lang.lexer`] does) and `length` bytes long.
  record Found
    symbol: string
    kind: Form
    token: integer
    line: integer
    column: integer
    length: integer
  end

  --- Every declaration of `chunk`, in the order they are looked up in: the first of a symbol is the one that stands.
  found: function(chunk: Ast.Chunk): {Found}
end

--- What a type declaration holds that a symbol is made of: its name and its members.
local record Declared
  name: Ast.Binding
  members: {Ast.Member}
end

--- What the node `n` declares if it declares a type, nil for anything else.
local function declared(n: Ast.Node): Declared?
  if n.kind == "Record" then
    return { name = n.name, members = n.members }
  elseif n.kind == "Interface" then
    return { name = n.name, members = n.members }
  elseif n.kind == "Class" then
    return { name = n.name, members = n.members }
  elseif n.kind == "Enum" then
    return { name = n.name, members = {} }
  elseif n.kind == "Alias" then
    return { name = n.name, members = {} }
  elseif n.kind == "Import" then
    return { name = n.name, members = {} }
  end
  return nil
end

function Places.found(chunk: Ast.Chunk): {Places.Found}
  local tokens = chunk.tokens
  local out: mut {Places.Found} = {}
  --- Adds the declaration of `symbol` whose name is the token `token`.
  local function add(symbol: string, kind: Places.Form, token: integer)
    local found: Places.Found = { symbol = symbol, kind = kind, token = token, line = Lexer.y(tokens, token),
      column = Lexer.x(tokens, token), length = Lexer.length(tokens, token) }
    out[#out + 1] = found
  end
  --- Adds the type `held` is at `symbol`, then its members and the types nested in it.
  local function add_type(held: Declared, symbol: string)
    add(symbol, "type", held.name.first)
    for _, member in ipairs(held.members) do
      if member.kind == "FieldDecl" then
        add(symbol .. "." .. member.name.name, "field", member.name.first)
      elseif member.kind == "Method" then
        add(symbol .. "." .. member.name.name, "method", member.name.first)
      else
        local nested = declared(member)
        if nested ~= nil then add_type(nested, symbol .. "." .. nested.name.name) end
      end
    end
  end
  --- Adds the types of `stats`, and of the `do` blocks in them.
  local function add_types(stats: {Ast.Stat})
    for _, stat in ipairs(stats) do
      if stat.kind == "Do" then
        add_types(stat.body.stats)
      else
        local held = declared(stat)
        if held ~= nil then add_type(held, held.name.name) end
      end
    end
  end
  --- Adds the `function R.f` statements of `stats`, and of the `do` blocks in them. A bare `function f` declares no
  --- member, and a longer path does not parse.
  local function add_functions(stats: {Ast.Stat})
    for _, stat in ipairs(stats) do
      if stat.kind == "Function" and #stat.path >= 2 then
        local names: mut {string} = {}
        for _, part in ipairs(stat.path) do names[#names + 1] = part.text end
        local last = stat.path[#stat.path]
        if last ~= nil then add(table.concat(names, "."), "function", last.first) end
      elseif stat.kind == "Do" then
        add_functions(stat.body.stats)
      end
    end
  end
  add_types(chunk.body.stats)
  add_functions(chunk.body.stats)
  return out
end

return Places
