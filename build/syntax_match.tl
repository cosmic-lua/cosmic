--- Structural pattern matching over the syntax tree of [`lang.ast`], ast-grep style: `$NAME` and `$$$NAME` in a
--- pattern's source are metavariables, matched against nodes of a tree [`lang.parser`] built.
---
--- A pattern is parsed with the same parser as the code it is matched against, so it is a real tree and not text. A
--- node matches a pattern node of its kind when every field the pattern sets matches, recursively; a field the
--- pattern leaves nil (an optional one: a return list, a `step`, an `else`) is not consulted, and a list matches when
--- it has the pattern's length. A metavariable stands for a node (`f($X)`), for a type (`$X as $T`), for a binding
--- (`local $X = 1`), or for the name of a field or a method (`mod.$F(1)`, `obj:$M()`), and a repeated name must match
--- the same source text each time. A `$$$NAME` that ends a list takes the rest of the list, none included: as an
--- argument (`f($$$ARGS)`), an item of a table, or, in a block, written as a call (`$$$BODY()`), since a bare name is
--- no statement.
---
--- A capture may carry a Lua pattern on its name, `$F:^test_`, which the text of what it binds must match: the text
--- of a node of one token, or of the first token of a type. The predicate cannot stay in the identifier the parser
--- reads, so [`Match.desugar`] strips it and [`Match.compile`] attaches it to each capture of that name.
---
--- A pattern that is a call statement (`os.execute($X)`) is the call, and matches a call wherever it stands: in a
--- statement or in an expression.
local Ast = require("lang.ast")
local Lexer = require("lang.lexer")
local Node = require("build.syntax_node")

local record Match
  --- What a metavariable bound: the tokens `first` to `last` of the tree it was matched in (`last < first` where it
  --- took no node) and the nodes it took, in source order. A name of a field or a method has the token of the name and
  --- no node.
  record Capture
    first: integer
    last: integer
    nodes: {Ast.Node}
  end

  --- A compiled pattern.
  record Pattern
    --- The node matched: the pattern's statement, or the call of a call statement.
    root: Ast.Node
    --- The Lua pattern each capture of a name must satisfy, by the desugared name (`_F`).
    predicates: {string: string}
  end

  --- What a match found: a node and the captures of the pattern, by desugared name (`$CMD` is `_CMD`).
  record Hit
    node: Ast.Node
    caps: {string: Capture}
  end

  --- `source` with each `$NAME` and `$$$NAME` written as an identifier, `_NAME` and `___NAME`. A predicate
  --- (`$NAME:pattern`, ended by a space, a parenthesis or a comma) is removed.
  desugar: function(source: string): string

  --- The pattern `source` spells, or nil and why the source does not parse. A source that is no statement is read as
  --- the expression of a `return`, so `$X as $T` is a pattern.
  compile: function(source: string): Pattern?, string

  --- The captures of `pattern` if `node` of `chunk` matches it, else nil.
  matches: function(pattern: Pattern, chunk: Ast.Chunk, node: Ast.Node): {string: Capture}?

  --- Every node under `root` that `pattern` matches, in source order (an outer node before one it holds that starts at
  --- the same token).
  find_all: function(pattern: Pattern, chunk: Ast.Chunk, root: Ast.Node): {Hit}

  --- The text of the tokens of `capture` in `source`, as written.
  text: function(chunk: Ast.Chunk, source: string, capture: Capture): string
end

local CAPTURE <const> = "^_[A-Z][A-Z0-9_]*$"
local REST <const> = "^___[A-Z][A-Z0-9_]*$"

function Match.desugar(source: string): string
  local out = source:gsub("%$%$%$([%u_][%w_]*)", "___%1")
  out = out:gsub("%$([%u_][%w_]*):([^%s%(%),]+)", "_%1")
  out = out:gsub("%$([%u_][%w_]*)", "_%1")
  return out
end

--- The Lua patterns of the captures that carry one, by desugared name.
local function predicates_of(source: string): {string: string}
  local out: mut {string: string} = {}
  local rest = source:gsub("%$%$%$([%u_][%w_]*)", "___%1")
  for name, pred in rest:gmatch("%$([%u_][%w_]*):([^%s%(%),]+)") do
    out["_" .. name] = pred
  end
  return out
end

--- The fields of a node by name, for a walk over [`Ast.fields`] that reads each.
local function fields_of(node: any): {string: any}
  if node is {string: any} then
    return node
  end
  return {}
end

local function as_node(value: any): Ast.Node?
  if value ~= nil and (value.kind == "Chunk" or value.kind == "Block" or value.kind == "Local" or value.kind == "LocalFunction" or value.kind == "Function" or value.kind == "Assign" or value.kind == "CallStat" or value.kind == "Return" or value.kind == "Do" or value.kind == "Break" or value.kind == "Continue" or value.kind == "While" or value.kind == "Repeat" or value.kind == "If" or value.kind == "Arm" or value.kind == "Match" or value.kind == "MatchArm" or value.kind == "PatBool" or value.kind == "PatBind" or value.kind == "ForNum" or value.kind == "ForIn" or value.kind == "Name" or value.kind == "Nil" or value.kind == "Boolean" or value.kind == "Integer" or value.kind == "Float" or value.kind == "String" or value.kind == "Vararg" or value.kind == "Paren" or value.kind == "FunctionLit" or value.kind == "Table" or value.kind == "Positional" or value.kind == "Named" or value.kind == "Keyed" or value.kind == "Field" or value.kind == "Index" or value.kind == "Call" or value.kind == "MethodCall" or value.kind == "Unary" or value.kind == "Binary" or value.kind == "IsTest" or value.kind == "Cast" or value.kind == "IfExp" or value.kind == "ExpArm" or value.kind == "Fn" or value.kind == "Rets" or value.kind == "Param" or value.kind == "Binding" or value.kind == "TypeName" or value.kind == "TypeBool" or value.kind == "TypeNil" or value.kind == "TypeError" or value.kind == "TypeArray" or value.kind == "TypeMap" or value.kind == "TypeUnion" or value.kind == "TypeOptional" or value.kind == "TypeMut" or value.kind == "TypeFunction" or value.kind == "PType" or value.kind == "Narrows" or value.kind == "TypeParam" or value.kind == "Record" or value.kind == "Interface" or value.kind == "Class" or value.kind == "Enum" or value.kind == "EnumValue" or value.kind == "Alias" or value.kind == "Import" or value.kind == "FieldDecl" or value.kind == "Method" or value.kind == "Userdata" or value.kind == "Error") then
    return value
  end
  return nil
end

--- The name a node stands for in a pattern when it is a capture, else nil: a name, a one-word type or a binding spelled
--- `_NAME`.
local function capture_of(node: Ast.Node): string?
  local f = fields_of(node)
  local kind = f["kind"]
  local text: any = nil
  if kind == "Name" then
    text = f["text"]
  elseif kind == "Binding" then
    text = f["name"]
  elseif kind == "TypeName" then
    local path = f["path"]
    local args = f["args"]
    if path is {string} and #path == 1 and args is {any} and #args == 0 then
      text = path[1]
    end
  end
  if text is string and (text:match(CAPTURE) ~= nil or text:match(REST) ~= nil) then
    return text
  end
  return nil
end

--- The name of the rest capture a list element is, else nil: a name, a type, the name as an item of a table, or a call
--- of the name with no arguments as a statement.
local function rest_of(node: Ast.Node): string?
  local f = fields_of(node)
  local kind = f["kind"]
  if kind == "Positional" then
    local value = as_node(f["value"])
    return value ~= nil and rest_of(value) or nil
  elseif kind == "CallStat" then
    local call = fields_of(f["call"])
    local args = call["args"]
    local callee = as_node(call["callee"])
    if call["kind"] == "Call" and args is {any} and #args == 0 and callee ~= nil then
      return rest_of(callee)
    end
    return nil
  end
  local name = capture_of(node)
  if name ~= nil and name:match(REST) ~= nil then
    return name
  end
  return nil
end

--- State of one match.
local record State
  pattern: Match.Pattern
  chunk: Ast.Chunk
  caps: mut {string: Match.Capture}
end

local function range_text(chunk: Ast.Chunk, first: integer, last: integer): string
  local parts: mut {string} = {}
  for i = first, last do
    parts[#parts + 1] = Lexer.text(chunk.tokens, i)
  end
  return table.concat(parts, " ")
end

--- Binds the capture `name` to `target`, or to the token `token` where it is a name in a field: false where the name is
--- bound to other text or its predicate refuses.
local function bind(st: State, name: string, target: Ast.Node?, token: integer): boolean
  local first, last = token, token
  local nodes: mut {Ast.Node} = {}
  if target ~= nil then
    local base = Node.base(target)
    first, last = base.first, base.last
    nodes[1] = target
  end
  local predicate = st.pattern.predicates[name]
  if predicate ~= nil then
    local text = ""
    if first == last or (target ~= nil and target.kind:sub(1, 4) == "Type") then
      text = Lexer.text(st.chunk.tokens, first)
    else
      return false
    end
    if text:match(predicate) == nil then
      return false
    end
  end
  local held = st.caps[name]
  if held ~= nil then
    return range_text(st.chunk, held.first, held.last) == range_text(st.chunk, first, last)
  end
  st.caps[name] = { first = first, last = last, nodes = nodes }
  return true
end

local match_node: function(st: State, p: Ast.Node, n: Ast.Node): boolean

--- The token of the name in a field or a method call: the second token after the object.
local function name_token(node: Ast.Node): integer
  local object = as_node(fields_of(node)["object"])
  return if object ~= nil then Node.base(object).last + 2 else 0 end
end

local function match_list(st: State, pl: {any}, nl: {any}, depth: integer): boolean
  if depth == 2 then
    if #pl ~= #nl then
      return false
    end
    for i = 1, #pl do
      local a, b = pl[i], nl[i]
      if not (a is {any} and b is {any} and match_list(st, a, b, 1)) then
        return false
      end
    end
    return true
  end
  local count = #pl
  local rest: string? = nil
  local tail = count > 0 and as_node(pl[count]) or nil
  if tail ~= nil then
    rest = rest_of(tail)
  end
  if rest ~= nil then
    count = count - 1
    if #nl < count then
      return false
    end
  elseif #nl ~= count then
    return false
  end
  for i = 1, count do
    local a, b = as_node(pl[i]), as_node(nl[i])
    if a == nil then
      -- A list of scalars, as a type's path is.
      if pl[i] ~= nl[i] then
        return false
      end
    elseif b == nil or not match_node(st, a, b) then
      return false
    end
  end
  if rest ~= nil then
    local taken: mut {Ast.Node} = {}
    for i = count + 1, #nl do
      local item = as_node(nl[i])
      if item ~= nil then
        taken[#taken + 1] = item
      end
    end
    local first, last = 0, -1
    if #taken > 0 then
      first = Node.base((assert(taken[1], "taken is not empty"))).first
      last = Node.base((assert(taken[#taken], "taken is not empty"))).last
    end
    local held = st.caps[rest]
    if held ~= nil then
      return range_text(st.chunk, held.first, held.last) == range_text(st.chunk, first, last)
    end
    st.caps[rest] = { first = first, last = last, nodes = taken }
  end
  return true
end

--- Whether the value of a field matches the pattern's: a name that is a capture binds the token of the name, a scalar
--- is equal, a node matches, a list matches.
local function match_field(st: State, kind: string, field: string, depth: integer, pv: any, nv: any,
                           nnode: Ast.Node): boolean
  if depth == 0 then
    if pv is {string: any} then
      local a, b = as_node(pv), as_node(nv)
      return a ~= nil and b ~= nil and match_node(st, a, b)
    end
    if pv is string and pv:match(CAPTURE) ~= nil and field == "name" and (kind == "Field" or kind == "MethodCall") then
      return nv is string and bind(st, pv, nil, name_token(nnode))
    end
    if kind == "String" and field == "long" then
      return true
    end
    return pv == nv
  end
  return pv is {any} and nv is {any} and match_list(st, pv, nv, depth)
end

match_node = function(st: State, p: Ast.Node, n: Ast.Node): boolean
  local capture = capture_of(p)
  if capture ~= nil then
    return bind(st, capture, n, 0)
  end
  local pf, nf = fields_of(p), fields_of(n)
  local kind = pf["kind"]
  if kind ~= nf["kind"] or not (kind is string) then
    return false
  end
  -- An `if` is its arms and an `else` that is not one of them: a pattern without the `else` is the whole statement, which
  -- a rewrite replaces, so it does not match one that has it.
  if kind == "If" and pf["else_body"] == nil and nf["else_body"] ~= nil then
    return false
  end
  local names = assert(Ast.fields[kind], "a node's kind has its fields")
  local depths = assert(Ast.depths[kind], "a node's kind has its depths")
  for i, name in ipairs(names) do
    local pv = pf[name]
    if pv ~= nil and not match_field(st, kind, name, assert(depths[i], "a field has its depth"), pv, nf[name], n) then
      return false
    end
  end
  return true
end

function Match.compile(source: string): Match.Pattern?, string
  local desugared = Match.desugar(source)
  local predicates = predicates_of(source)
  local chunk, why = Node.parse(desugared, "<pattern>")
  if chunk ~= nil then
    local first = chunk.body.stats[1]
    if first ~= nil then
      if (first.kind == "CallStat") then
        return { root = first.call, predicates = predicates }, ""
      end
      return { root = first, predicates = predicates }, ""
    end
    return nil, "<pattern>: the pattern is empty"
  end
  -- An expression that is no statement is read as what a `return` gives; the first parse's error is the one told.
  local wrapped, _ = Node.parse("return " .. desugared, "<pattern>")
  if wrapped ~= nil then
    local ret = wrapped.body.stats[1]
    if ret ~= nil and (ret.kind == "Return") then
      local root = ret.values[1]
      if root ~= nil then
        return { root = root, predicates = predicates }, ""
      end
    end
  end
  return nil, why
end

function Match.matches(pattern: Match.Pattern, chunk: Ast.Chunk, node: Ast.Node): {string: Match.Capture}?
  local st: State = { pattern = pattern, chunk = chunk, caps = {} }
  if match_node(st, pattern.root, node) then
    return st.caps
  end
  return nil
end

function Match.find_all(pattern: Match.Pattern, chunk: Ast.Chunk, root: Ast.Node): {Match.Hit}
  local hits: mut {Match.Hit} = {}
  Node.walk(root, function(node: Ast.Node)
    local caps = Match.matches(pattern, chunk, node)
    if caps ~= nil then
      hits[#hits + 1] = { node = node, caps = caps }
    end
  end)
  return hits
end

function Match.text(chunk: Ast.Chunk, source: string, capture: Match.Capture): string
  if capture.last < capture.first then
    return ""
  end
  local tokens = chunk.tokens
  return source:sub(Lexer.offset(tokens, capture.first), Lexer.stop(tokens, capture.last) - 1)
end

return Match
