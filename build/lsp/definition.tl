--- Go to definition for `cosmic lsp` ([`build.lsp.session`]): where the name under the cursor is declared, from the
--- checker's own report of the document ([`check.read`]: its tree, its scopes and the type of each node).
---
--- What it answers:
---
--- - A name that refers to a local, a parameter, a function or a type of the document: where that binding is declared.
--- - A type path ([`Stream.Reader`]) at its last name: the declaration of the type it names, in the module that declares it.
--- - A field, a method or an enum value (`shapes.sides`, `r:area()`, `{ sides = 3 }`, [`Color.red`]): where the type the
---   object has (or the interface it lists) declares it, or the `function R.f()` that adds it, in the module that
---   declares the type.
--- - A name that is declared where it stands (a binding, the name in a `function R.f`): itself.
---
--- Nothing is answered for a place the report does not know: a global the standard library declares, a name the
--- checker left unresolved, a module the working database does not list (the binary's own `cosmic.*` modules in a
--- project), a template, a text that does not parse, a document that requires a module the build refuses (a cycle of
--- imports, a module the project does not have), and a type declared inside a function.
---
--- A place in another module is found in that module's text as it is written ([`source.written`]), an open document's
--- or else the working database's, parsed here: the checker is served the module as a stub, whose positions are not
--- the file's. A place in the document is found in the text the checker read, which a build rewrites (the `splices` of
--- [`check.Reading`]), and put back in the document's own text.

-- TODO: answer a symbol of the binary's own `cosmic.*` modules, once the checker is served the positions of their sources: it
-- reads their declarations alone, so in a project the working database has no text for them ([`source.written`]) and
-- the answer is none.

-- TODO: answer a field of a type declared inside a function body, once the lowering names such a type by something that tells
-- it from another of the same name in the module: the declarations are found by their names at the top of the module and in
-- its `do` blocks, where the name is the type's alone.

-- TODO: answer the value of an enum that a string literal stands for, once the type report keeps the enum a literal was read
-- as: the report types the literal `"w"` as the string, and the enum's values are found only by a member access.

-- TODO: read the result of the last check in place of checking the document again, once the session's program keeps a
-- module's result across the check of another document ([`build.lsp.held`]): each request costs a check of the document.

local Ast = require("lang.ast")
local Driver = require("build.driver")
local Lexer = require("lang.lexer")
local Report = require("build.syntax_report")
local ShapeSpecs = require("build.syntax_shape_specs")
local Types = require("lang.types")
local check = require("build.lsp.check")
local lines = require("build.lsp.lines")
local protocol = require("build.lsp.protocol")
local source = require("build.lsp.source")
local syntax_read = require("build.lsp.syntax_read")

local record definition
  --- A module's tree, and the text the person has of it.
  record Place
    module: string
    chunk: Ast.Chunk
    --- The text the person has: the document's own, or the module's file.
    original: string
    --- What was put in `original` to make the text `chunk` was read from, as [`check.Reading`] has it: none for a file.
    splices: {ShapeSpecs.Splice}
    uri: string
  end

  --- A token of a place: what is declared there.
  record Site
    place: Place
    token: integer
  end

  --- What one request reads.
  record Request
    checker: check.Checker
    outcome: Driver.Outcome
    here: Place
    encoding: string
  end

  --- What a declaration holds that a name can be found in.
  record Declared
    name: Ast.Binding
    members: {Ast.Member}
  end
end

local type Place = definition.Place
local type Site = definition.Site
local type Request = definition.Request
local type Declared = definition.Declared

local function base_of(node: Ast.Node): Ast.Base
  return node
end

--- What the declaration `n` declares if it is the type `name`: nil for anything else.
local function declared(n: Ast.Node, name: string): Declared?
  if n.kind == "Record" and n.name.name == name then
    return { name = n.name, members = n.members }
  elseif n.kind == "Interface" and n.name.name == name then
    return { name = n.name, members = n.members }
  elseif n.kind == "Class" and n.name.name == name then
    return { name = n.name, members = n.members }
  elseif n.kind == "Enum" and n.name.name == name then
    return { name = n.name, members = {} }
  elseif n.kind == "Alias" and n.name.name == name then
    return { name = n.name, members = {} }
  elseif n.kind == "Import" and n.name.name == name then
    return { name = n.name, members = {} }
  end
  return nil
end

--- The type declared at the path `names` (a name, then the names nested under it) in the statements `stats`, at the top
--- of the module or in a `do` block of it.
local function type_in(stats: {Ast.Stat}, names: {string}): Declared?
  local head = names[1]
  if head == nil then return nil end
  local current: Declared? = nil
  for _, stat in ipairs(stats) do
    if stat.kind == "Do" then
      current = type_in(stat.body.stats, { head })
    else
      current = declared(stat, head)
    end
    if current ~= nil then break end
  end
  for i = 2, #names do
    if current == nil then return nil end
    local want = assert(names[i])
    local nested: Declared? = nil
    for _, member in ipairs(current.members) do
      nested = declared(member, want)
      if nested ~= nil then break end
    end
    current = nested
  end
  return current
end

--- The token of the field or method `name` of the declaration `held`.
local function member_token(held: Declared, name: string): integer?
  for _, member in ipairs(held.members) do
    if member.kind == "FieldDecl" and member.name.name == name then return member.name.first end
    if member.kind == "Method" and member.name.name == name then return member.name.first end
  end
  return nil
end

--- The token of the last name of the statement `function <path>(...)`, at the top of the module or in a `do` block of it.
local function function_token(stats: {Ast.Stat}, path: string): integer?
  for _, stat in ipairs(stats) do
    if stat.kind == "Function" then
      local names: mut {string} = {}
      for _, part in ipairs(stat.path) do names[#names + 1] = part.text end
      local last = stat.path[#stat.path]
      if last ~= nil and table.concat(names, ".") == path then return last.first end
    elseif stat.kind == "Do" then
      local found = function_token(stat.body.stats, path)
      if found ~= nil then return found end
    end
  end
  return nil
end

--- The module `module`, as a place to find declarations in: the document's own where it is the document's module, else the
--- module's file as written, parsed. nil where the working database lists none.
local function place_of(request: Request, module: string): Place?
  if module == request.here.module then return request.here end
  local checker = request.checker
  local written = source.written(checker.source, module, check.open_files(checker))
  if written == nil then return nil end
  local dialect: Ast.Dialect = "tl"
  if written.file:match("%.d%.tl$") ~= nil then dialect = "decl" end
  local parsed = Driver.parse(Driver.source(module, written.file, written.text, dialect))
  local opened = checker.open[written.file]
  local uri = protocol.uri_of(checker.root .. "/" .. written.file)
  if opened ~= nil then uri = opened.uri end
  return { module = module, chunk = parsed.chunk, original = parsed.text, splices = {}, uri = uri }
end

--- Where the type `decl` is declared.
local function decl_site(request: Request, decl: Types.Decl): Site?
  local place = place_of(request, decl.module)
  if place == nil then return nil end
  local held = type_in(place.chunk.body.stats, decl.names)
  if held == nil then return nil end
  return { place = place, token = held.name.first }
end

--- Where the field or method `name` of the type `decl` is declared: in the type, or in the interface it lists
--- that declares it, or by a `function R.f()` statement of the module of either.
local function member_site(request: Request, decl: Types.Decl, name: string): Site?
  local owner = decl
  if not Report.has_member(decl, name) then owner = Report.declaring(decl, name) or decl end
  local place = place_of(request, owner.module)
  if place == nil then return nil end
  local stats = place.chunk.body.stats
  local held = type_in(stats, owner.names)
  local token: integer? = nil
  if held ~= nil then token = member_token(held, name) end
  if token == nil then token = function_token(stats, owner.name .. "." .. name) end
  if token == nil then return nil end
  return { place = place, token = token }
end

--- The declaration the type `t` is, or is an optional of.
local function decl_of_type(t: Types.Type?): Types.Decl?
  if t == nil then return nil end
  if t.tag == "union" then
    for _, member in ipairs(t.members) do
      local found = Report.decl_of(member)
      if found ~= nil then return found end
    end
    return nil
  end
  return Report.decl_of(t)
end

--- The nodes of `chunk` that hold the token `tok`, the chunk first and the innermost last.
local function chain(chunk: Ast.Chunk, tok: integer): {Ast.Node}
  local out: mut {Ast.Node} = { chunk }
  local current: Ast.Node = chunk
  while true do
    local inside: mut {Ast.Node} = {}
    Ast.children(current, function(child: Ast.Node)
      local base = base_of(child)
      if #inside == 0 and base.first <= tok and tok <= base.last then inside[1] = child end
    end)
    local next_node = inside[1]
    if next_node == nil then return out end
    out[#out + 1] = next_node
    current = next_node
  end
end

--- The tokens the byte `offset` of the checker's text is in, or at the end of: the one it is in first.
local function tokens_at(tokens: Lexer.Tokens, offset: integer): {integer}
  local out: mut {integer} = {}
  local count = Lexer.count(tokens)
  --- The last token that starts at or before `at`, if `at` is one of its bytes.
  local function holding(at: integer): integer?
    local low, high = 1, count
    local found: integer = 0
    while low <= high do
      local middle = (low + high) // 2
      if Lexer.offset(tokens, middle) <= at then
        found = middle
        low = middle + 1
      else
        high = middle - 1
      end
    end
    if found == 0 or at >= Lexer.offset(tokens, found) + Lexer.length(tokens, found) then
      return nil
    end
    return found
  end
  local here = holding(offset)
  if here ~= nil then out[#out + 1] = here end
  local before = holding(offset - 1)
  if before ~= nil and before ~= here then out[#out + 1] = before end
  return out
end

--- Where the name at the token `tok` of the document is declared.
local function target(request: Request, tok: integer): Site?
  local outcome = request.outcome
  local checked = outcome.checked
  if checked == nil then return nil end
  local types = checked.types
  local nodes = chain(outcome.chunk, tok)
  local leaf = nodes[#nodes]
  local parent = nodes[#nodes - 1]
  if leaf == nil then return nil end
  local here = request.here
  local scoped = outcome.scoped
  --- The binding the node with id `id` refers to, if the scopes resolved it.
  local function declaration(id: integer): Site?
    local var_id = scoped.resolved[id]
    if var_id == nil then return nil end
    local var = scoped.vars[var_id]
    if var == nil then return nil end
    return { place = here, token = var.declared }
  end
  if leaf.kind == "Name" then
    local found = declaration(leaf.id)
    if found ~= nil then return found end
    -- The names after the first of `function R.f()` declare where they stand.
    if parent ~= nil and parent.kind == "Function" and parent.path[1] ~= leaf then
      return { place = here, token = leaf.first }
    end
    return nil
  elseif leaf.kind == "Binding" then
    return { place = here, token = leaf.first }
  elseif leaf.kind == "TypeName" then
    local offset = tok - leaf.first
    local index = offset // 2 + 1
    if offset % 2 ~= 0 or index > #leaf.path then return nil end
    if index == 1 then
      local found = declaration(leaf.id)
      if found ~= nil then return found end
    end
    if index == #leaf.path then
      local decl = decl_of_type(types[leaf.id])
      if decl ~= nil then return decl_site(request, decl) end
    end
    return nil
  elseif leaf.kind == "Field" and tok == leaf.last then
    local decl = decl_of_type(types[leaf.object.id])
    if decl == nil then return nil end
    return member_site(request, decl, leaf.name)
  elseif leaf.kind == "MethodCall" and tok == leaf.object.last + 2 then
    local decl = decl_of_type(types[leaf.object.id])
    if decl == nil then return nil end
    return member_site(request, decl, leaf.name)
  elseif leaf.kind == "Named" and tok == leaf.first and parent ~= nil and parent.kind == "Table" then
    local decl = decl_of_type(types[parent.id])
    if decl == nil then return nil end
    return member_site(request, decl, leaf.name)
  end
  return nil
end

--- The range of the token of `site`, in the units of the session's encoding, in the text the person has.
local function range_of(request: Request, site: Site): protocol.Range
  local place = site.place
  local tokens = place.chunk.tokens
  local first = Lexer.offset(tokens, site.token)
  local last = first + math.max(Lexer.length(tokens, site.token), 1) - 1
  local split = lines.lines_of(place.original)
  return protocol.range(
    lines.position(split, syntax_read.unspliced(place.splices, first), request.encoding),
    lines.position(split, syntax_read.unspliced(place.splices, last) + 1, request.encoding))
end

--- The location of the declaration of the name at `where` in `document`, whose characters count in `encoding`'s units, or
--- nil where the report knows none.
function definition.at(checker: check.Checker, document: check.Document, where: protocol.Position,
                       encoding: string): protocol.Location?
  local reading = check.read(checker, document)
  if reading == nil then return nil end
  local split = lines.lines_of(document.text)
  local line = split.texts[where.line + 1]
  local start = split.starts[where.line + 1]
  if line == nil or start == nil then return nil end
  local offset = start + lines.byte_of(line, where.character, encoding) - 1
  -- What a build put in the text before the checker read it moves the bytes after it.
  for _, splice in ipairs(reading.splices) do
    if splice.at < offset then offset = offset + #splice.text end
  end
  local outcome = reading.outcome
  local request: Request = {
    checker = checker, outcome = outcome, encoding = encoding,
    here = { module = outcome.module, chunk = outcome.chunk, original = document.text, splices = reading.splices,
      uri = document.uri },
  }
  for _, tok in ipairs(tokens_at(outcome.chunk.tokens, offset)) do
    local site = target(request, tok)
    if site ~= nil then return { uri = site.place.uri, range = range_of(request, site) } end
  end
  return nil
end

return definition
