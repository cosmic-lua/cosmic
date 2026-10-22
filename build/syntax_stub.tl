--- The stub of a standard-library module: what a project's checker reads in place of its source to type a `require` of
--- it.
---
--- A stub is the module's source with every function body left out: each token it keeps stays at the line and column
--- it had, so a place the checker reports in the module means the same in either, and what it keeps of the source's
--- requires, types, records and top-level statements is as the source wrote it. Comments and the space between tokens
--- are dropped, since the checker reads neither; lexing them is a good part of what a module costs it.
---
--- Leaving a body out cannot change the module's type: a function's type is its signature, or, for a function literal,
--- the context it stands in. A literal written with no return list takes what its context expects of it, and nothing in
--- its signature says what that is, so its body is kept. A function declared `: never` must not reach its end, so its
--- stub body is `error()`.
---
--- A module that returns a name whose last top-level declaration spells its type (a record or another type it declares,
--- a local function, a local of a written type) keeps, besides, only the statements that type needs: what its
--- declaration and the signatures of its functions name, and so on, with the requires they reach. The rest is code only
--- bodies read, whose requires would make a project's checker load modules no type it sees names ([`unneeded`]). Any
--- other module keeps every statement, which cosmic's own build refuses of a standard-library module
--- ([`Stub.Made`]'s `pruned`).
local Ast = require("lang.ast")
local Lexer = require("lang.lexer")
local Declarations = require("lang.declarations")
local Node = require("build.syntax_node")
local Types = require("lang.types")

local record Stub
  --- A stub ([`Stub.made`]).
  record Made
    text: string
    --- Whether it is declaration-only: whether the module returns a name whose last top-level declaration spells its
    --- type, so the stub leaves out every statement that type needs none of. Cosmic's own build refuses a
    --- standard-library module whose stub is not: a project's checker would read every statement it holds, and load
    --- every module it requires.
    pruned: boolean
  end

  --- The stub of the module `chunk` holds. With `every`, every top-level statement is kept, leaving out only bodies,
  --- as for a module that returns no name whose declaration spells its type: what is kept of a statement is the same
  --- either way, which `cosmic lsp` reads the top-level calls of ([`build.lsp.check`]). The stub made is never `pruned`
  --- then.
  made: function(chunk: Ast.Chunk, every?: boolean): Made

  --- Where the types `module` has in `source`, a program that read its source, and in `stubbed`, a program that read its stub
  --- instead, differ: nil when the stub types the module as its source does, and otherwise a line that names the first
  --- declaration that differs and how. The declarations compared are those the module's answer reaches (the record it returns,
  --- or the type of the value it returns, and every declaration of the module those name, through their fields, methods,
  --- listings and type arguments): a declaration the module keeps to itself and nothing reaches is not part of its type. Two
  --- declarations are the same when their canonical text ([`Types.encode_declaration`]) is, which names every other module's
  --- declaration by its path, so a module whose stub differs is told of in its own comparison and not in each that names it.
  --- The port of [`build.stub`]'s `difference`, which walked the fork's type objects.
  difference: function(source: Declarations.Program, stubbed: Declarations.Program, module: string): string | nil
end

--- What stands for a `: never` function's body.
local NEVER_BODY <const> = "error()"

--- Where the stub has written to.
local record Cursor
  y: integer
  x: integer
end

--- Tokens left out, from token `first` to `last`, with what stands in their place at the first, if anything.
local record Span
  first: integer
  last: integer
  instead: string | nil
end

--- Whether `rets` is the single type `never`.
local function is_never(rets: Ast.Rets | nil): boolean
  if rets == nil or #rets.lists ~= 1 then
    return false
  end
  local list = rets.lists[1]
  local only = list[1]
  return #list == 1 and only ~= nil and only is Ast.TypeName and #only.path == 1 and only.path[1] == "never"
end

--- The span of the body `body` of a function with return list `rets`, or nil where it is kept: an empty body has
--- nothing to leave out, a `: never` one too short on its own line to hold [`NEVER_BODY`] is kept whole, and so is a
--- function literal's with no return list.
local function body_span(chunk: Ast.Chunk, body: Ast.Block, rets: Ast.Rets | nil, literal: boolean): Span | nil
  if #body.stats == 0 or (literal and rets == nil) then
    return nil
  end
  local tokens = chunk.tokens
  local never = is_never(rets)
  local opener, closer = body.first, body.close
  if never and Lexer.y(tokens, opener) >= Lexer.y(tokens, closer) and
      Lexer.x(tokens, closer) - Lexer.x(tokens, opener) <= #NEVER_BODY then
    return nil
  end
  return { first = opener, last = closer - 1, instead = never and NEVER_BODY or nil }
end

--- The bodies of `stat` left out, in source order. What a body left out holds is not walked.
local function bodies_of(chunk: Ast.Chunk, stat: Ast.Stat, found: {Span})
  Node.walk_until(stat, function(node: Ast.Node): boolean
    local span: Span | nil = nil
    if node is Ast.LocalFunction then
      span = body_span(chunk, node.fn.body, node.fn.rets, false)
    elseif node is Ast.Function then
      span = body_span(chunk, node.fn.body, node.fn.rets, false)
    elseif node is Ast.FunctionLit then
      span = body_span(chunk, node.fn.body, node.fn.rets, true)
    elseif node is Ast.Method then
      span = body_span(chunk, node.body, node.rets, false)
    end
    if span ~= nil then
      found[#found + 1] = span
      return false
    end
    return true
  end)
end

--- Whether a statement may be left out of a declaration-only stub: a declaration, an assignment, a call, a block or a
--- loop. None changes the type of a record declared as such, beside what the names it declares do: an assignment adds
--- no field to one. Three things would. An assignment to a name declared as a value with no type written infers that
--- value's type, but `unneeded` prunes only a module whose returned name's last declaration spells its type. An `if`,
--- an `assert` or an assignment may narrow the union a local is written to be, which a build refuses. A require of a
--- module that declares a global would bring a type in by no name the stub spells, but a build refuses a module that
--- declares one. A statement of any other kind is kept wherever it is.
local function droppable(s: Ast.Stat): boolean
  local declared = Node.declared(s)
  if s is Ast.Local then
    return s.scope == "local"
  elseif s is Ast.Function then
    return #s.path >= 2
  elseif declared ~= nil then
    return declared.scope == "local"
  end
  return s is Ast.LocalFunction or s is Ast.Assign or s is Ast.CallStat or s is Ast.If or s is Ast.ForNum or
    s is Ast.ForIn or s is Ast.While or s is Ast.Repeat or s is Ast.Do or s is Ast.Match
end

--- The names the top-level statement `s` declares, and, for a `function M.f`, the name it adds a field to ("" for any
--- other statement).
local function names_of(s: Ast.Stat): {string}, string
  local declared: {string} = {}
  local type_declared = Node.declared(s)
  if s is Ast.Local and s.scope == "local" then
    for _, b in ipairs(s.bindings) do
      declared[#declared + 1] = b.name
    end
  elseif s is Ast.LocalFunction then
    declared[1] = s.name.name
  elseif type_declared ~= nil and type_declared.scope == "local" then
    declared[1] = type_declared.name.name
  elseif s is Ast.Function and #s.path >= 2 then
    return declared, s.path[1].text
  end
  return declared, ""
end

--- The names the top-level statement `s`, an assignment, writes as plain names (`feed = function() ... end`).
local function written_names(s: Ast.Stat): {string}
  local written: {string} = {}
  if s is Ast.Assign then
    for _, target in ipairs(s.targets) do
      if target is Ast.Name then
        written[#written + 1] = target.text
      end
    end
  end
  return written
end

--- Whether the top-level statement `s` gives the one name it declares a type no later statement can change: a type
--- declaration, a local function, whose type is its signature, or a local whose type is written. Nothing infers any of
--- these from what follows, though a later statement may narrow a local's union (see [`droppable`]).
local function spells_its_type(s: Ast.Stat): boolean
  local declared = Node.declared(s)
  if s is Ast.LocalFunction then
    return true
  elseif declared ~= nil then
    return declared.scope == "local"
  end
  return s is Ast.Local and s.scope == "local" and #s.bindings == 1 and #s.types == 1
end

--- The top-level statements of `chunk` a declaration of the module needs none of, as spans to leave out, where the
--- module returns a name whose last top-level declaration spells its type ([`spells_its_type`]); nil for any other
--- module, whose stub keeps every statement. Such a module's type is that declaration's, with what each `function M.f`
--- on it adds, so the stub keeps the `return`, then what a kept statement names, to a fixed point: the declaration of
--- each name one of its tokens spells (outside a body `bodies` left out), and each `function M.f` whose `M` is kept. A
--- name is taken for a reference wherever it is spelt, as a field's name too, which keeps a statement at worst.
local function unneeded(chunk: Ast.Chunk, bodies: {Span}): {Span} | nil
  local statements = chunk.body.stats
  local tokens = chunk.tokens
  local last = statements[#statements]
  local value = last ~= nil and last is Ast.Return and #last.values == 1 and last.values[1] or nil
  local returned = value ~= nil and value is Ast.Name and value.text or nil
  if returned == nil then
    return nil
  end
  local declares: {{string}} = {}
  local writes: {{string}} = {}
  local owners: {string} = {}
  local typed = false
  for i, s in ipairs(statements) do
    declares[i], owners[i] = names_of(s)
    writes[i] = written_names(s)
    -- The returned name's last top-level declaration decides what it is.
    for _, name in ipairs(declares[i]) do
      if name == returned then
        typed = spells_its_type(s)
      end
    end
  end
  if not typed then
    return nil
  end
  local left_out: {integer: boolean} = {}
  for _, span in ipairs(bodies) do
    for k = span.first, span.last do
      left_out[k] = true
    end
  end
  -- The names each statement's tokens outside a body spell.
  local spelt: {{string: boolean}} = {}
  for i, s in ipairs(statements) do
    local names: {string: boolean} = {}
    for k = Node.base(s).first, Node.base(s).last do
      if tokens.kind[k] == "identifier" and left_out[k] ~= true then
        names[Lexer.text(tokens, k)] = true
      end
    end
    spelt[i] = names
  end
  local kept: {integer: boolean} = { [#statements] = true }
  local wanted: {string: boolean} = {}
  local grew = true
  while grew do
    grew = false
    for i in pairs(kept) do
      for name in pairs(spelt[i]) do
        wanted[name] = true
      end
    end
    for i, s in ipairs(statements) do
      if kept[i] == nil then
        local keep = not droppable(s) or wanted[owners[i]] == true
        for _, name in ipairs(declares[i]) do
          keep = keep or wanted[name] == true
        end
        -- The assignment of a name a kept statement spells stays: a local declared with no value is read in the stub
        -- only if the stub assigns it, as the source does.
        for _, name in ipairs(writes[i]) do
          keep = keep or wanted[name] == true
        end
        if keep then
          kept[i], grew = true, true
        end
      end
    end
  end
  local out: {Span} = {}
  for i = 1, #statements - 1 do
    if kept[i] == nil then
      out[#out + 1] = { first = Node.base(statements[i]).first, last = Node.base(statements[i]).last, instead = nil }
    end
  end
  return out
end

function Stub.made(chunk: Ast.Chunk, every?: boolean): Stub.Made
  local tokens = chunk.tokens
  local bodies: {Span} = {}
  for _, s in ipairs(chunk.body.stats) do
    bodies_of(chunk, s, bodies)
  end
  local spans: {Span} = {}
  for _, span in ipairs(bodies) do
    spans[#spans + 1] = span
  end
  local dropped: {Span} | nil = nil
  if every ~= true then dropped = unneeded(chunk, bodies) end
  for _, span in ipairs(dropped or {}) do
    spans[#spans + 1] = span
  end
  -- A token is left out when a span holds it; the first token of a span that has something instead gives it.
  local out_of: {integer: boolean} = {}
  local instead: {integer: string} = {}
  for _, span in ipairs(spans) do
    for k = span.first, span.last do
      out_of[k] = true
    end
    if span.instead ~= nil then
      instead[span.first] = span.instead
    end
  end
  local out: {string} = {}
  local cursor: Cursor = { y = 1, x = 1 }
  local function put(at_y: integer, at_x: integer, text: string)
    if at_y > cursor.y then
      out[#out + 1] = ("\n"):rep(at_y - cursor.y)
      cursor.y, cursor.x = at_y, 1
    end
    if at_x > cursor.x then
      out[#out + 1] = (" "):rep(at_x - cursor.x)
    end
    out[#out + 1] = text
    -- A long string may span lines.
    local last = 0
    for at in text:gmatch("()\n") do
      cursor.y = cursor.y + 1
      last = math.tointeger(at) or 0
    end
    cursor.x = last > 0 and #text - last + 1 or at_x + #text
  end
  for k, kind in ipairs(tokens.kind) do
    if kind == "$EOF$" then
      break
    end
    if out_of[k] ~= true then
      put(Lexer.y(tokens, k), Lexer.x(tokens, k), Lexer.text(tokens, k))
    elseif instead[k] ~= nil then
      put(Lexer.y(tokens, k), Lexer.x(tokens, k), instead[k])
    end
  end
  return { text = table.concat(out) .. "\n", pruned = dropped ~= nil }
end

--- The declarations of `module` that its answer in `program` reaches, by name, and the names in the order they were found;
--- and the canonical text of the type of the value it returns when that is no declaration.
local record Reached
  decls: {string: Types.Decl}
  order: {string}
  value: string
  --- The canonical text of the type of each function written `function M.f(...)`, by declaration and then by name: they are
  --- members of the declaration used as a value, and the declaration's own text ([`Types.encode_declaration`]) holds none.
  statics: {string: {string: string}}
end

local function reached(program: Declarations.Program, module: string): Reached
  local out: Reached = { decls = {}, order = {}, value = "", statics = {} }
  local seen: {integer: boolean} = {}
  local add: function(d: Types.Decl)
  local function walk(t: Types.Type)
    if seen[t.id] then
      return
    end
    seen[t.id] = true
    if t is Types.Named then
      add(t.decl)
    end
    for _, part in ipairs(Types.parts(t)) do
      walk(part)
    end
  end
  add = function(d: Types.Decl)
    if d.module ~= module or out.decls[d.name] ~= nil then
      return
    end
    out.decls[d.name] = d
    out.order[#out.order + 1] = d.name
    local body = d.body
    if body == nil then
      return
    end
    for _, super in ipairs(body.supers) do
      walk(super)
    end
    for _, field in ipairs(body.fields) do
      walk(field.type)
    end
    for _, method in ipairs(body.methods) do
      walk(method.type)
    end
    local array = body.array
    if array ~= nil then
      walk(array)
    end
    for _, param in ipairs(body.tparams) do
      local bound = param.bound
      if bound ~= nil then
        walk(bound)
      end
    end
    -- The functions written `function R.f(...)` are members of the declaration used as a value.
    local statics = program.statics[d] or {}
    local names: {string} = {}
    for name in pairs(statics) do
      names[#names + 1] = name
    end
    table.sort(names)
    local texts: {string: string} = {}
    for _, name in ipairs(names) do
      walk(statics[name].type)
      texts[name] = Types.encode(statics[name].type)
    end
    out.statics[d.name] = texts
  end
  local known = program.modules[module]
  if known ~= nil then
    local export = known.export
    if export ~= nil then
      local root = export.decl
      if root ~= nil then
        add(root)
      end
    end
    local value = known.value
    if value ~= nil then
      walk(value)
      out.value = Types.encode(value)
    end
  end
  return out
end

--- The first place two texts differ, with a few characters of each around it.
local function first_difference(a: string, b: string): string
  local at = 1
  while at <= #a and at <= #b and a:byte(at) == b:byte(at) do
    at = at + 1
  end
  local from = math.max(1, at - 20)
  return "`" .. a:sub(from, at + 30) .. "` in the source, `" .. b:sub(from, at + 30) .. "` in the stub"
end

function Stub.difference(source: Declarations.Program, stubbed: Declarations.Program, module: string): string | nil
  local a, b = reached(source, module), reached(stubbed, module)
  local names: {string} = {}
  local listed: {string: boolean} = {}
  for _, list in ipairs({ a.order, b.order }) do
    for _, name in ipairs(list) do
      if listed[name] ~= true then
        listed[name] = true
        names[#names + 1] = name
      end
    end
  end
  for _, name in ipairs(names) do
    local from, to = a.decls[name], b.decls[name]
    if to == nil then
      return name .. ": declared by the source and not by the stub"
    elseif from == nil then
      return name .. ": declared by the stub and not by the source"
    elseif (from.body == nil) ~= (to.body == nil) then
      return name .. ": defined by the " .. (from.body == nil and "stub" or "source") .. " only"
    elseif from.body ~= nil then
      local text, stubbed_text = Types.encode_declaration(from), Types.encode_declaration(to)
      if text ~= stubbed_text then
        return name .. ": " .. first_difference(text, stubbed_text)
      end
      local ours, theirs = a.statics[name] or {}, b.statics[name] or {}
      local static_names: {string} = {}
      for static in pairs(ours) do
        static_names[#static_names + 1] = static
      end
      for static in pairs(theirs) do
        if ours[static] == nil then
          static_names[#static_names + 1] = static
        end
      end
      table.sort(static_names)
      for _, static in ipairs(static_names) do
        if theirs[static] == nil then
          return name .. "." .. static .. ": a function of the source and not of the stub"
        elseif ours[static] == nil then
          return name .. "." .. static .. ": a function of the stub and not of the source"
        elseif ours[static] ~= theirs[static] then
          return name .. "." .. static .. ": " .. first_difference(ours[static], theirs[static])
        end
      end
    end
  end
  if a.value ~= b.value then
    return "the value it returns: " .. first_difference(a.value, b.value)
  end
  return nil
end

return Stub
