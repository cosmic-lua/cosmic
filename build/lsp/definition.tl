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
--- checker left unresolved, a module the working database does not list and the binary carries no places of (a
--- `cosmic.*` module generated from another file, as [`cosmic.sys`] is), a template, a text that does not parse, a document
--- that requires a module the build refuses (a cycle of imports, a module the project does not have), and a type declared
--- inside a function.
---
--- A place in another module is looked up by its symbol in the `places` the stage derived of the module's file
--- ([`source.places`]), and put in the module's text as it is written: the checker is served the
--- module as a stub, whose positions are not the file's. Only an open document that differs from the staged file is
--- parsed. A module generated from another file (the syscall modules, from `core/*.h`) is answered in that file, at the
--- line its `-- line` map gives. A symbol of the binary's own `cosmic.*` modules, which a project's working database does
--- not list, is looked up in the places the tool carries ([`source.places`]), and its location is a file the tool writes
--- below the build directory with the module's text ([`source.extracted`]), the binary having no source tree to point at.
--- A place in the document is found in the text the checker read, which a build rewrites (the `splices` of
--- [`check.Reading`]), and put back in the document's own text.

-- TODO: answer a field of a type declared inside a function body, once the lowering names such a type by something that tells
-- it from another of the same name in the module: the declarations are found by their names at the top of the module and in
-- its `do` blocks, where the name is the type's alone ([`build.syntax_places`]).

-- TODO: answer a symbol of the binary's own modules generated from another file ([`cosmic.sys`],
-- [`cosmic.internal.process`]) in a project, once the tool carries the header their `-- line` map names (`core/*.h`) with
-- their places: its `places` hold none ([`source.places`]).

-- TODO: answer the value of an enum that a string literal stands for, once the type report keeps the enum a literal was read
-- as: the report types the literal `"w"` as the string, and the enum's values are found only by a member access.

local Ast = require("lang.ast")
local Driver = require("build.driver")
local Lexer = require("lang.lexer")
local Places = require("build.syntax_places")
local Report = require("build.syntax_report")
local ShapeSpecs = require("build.syntax_shape_specs")
local Types = require("lang.types")
local check = require("build.lsp.check")
local lines = require("build.lsp.lines")
local protocol = require("build.lsp.protocol")
local source = require("build.lsp.source")
local syntax_read = require("build.lsp.syntax_read")

local record definition
  --- A module's text, and what its sites are in.
  record Place
    module: string
    --- The text the person has: the document's own, or the module's file.
    original: string
    --- What was put in `original` to make the text its sites are bytes of, as [`check.Reading`] has it: none for a file.
    splices: {ShapeSpecs.Splice}
    uri: string
  end

  --- Where a name is declared: the byte `offset` of the text of `place` (as spliced) its `length` bytes start at.
  record Site
    place: Place
    offset: integer
    length: integer
  end

  --- What one request reads.
  record Request
    checker: check.Checker
    outcome: Driver.Outcome
    here: Place
    encoding: string
    --- The first place of each symbol the document declares, once asked for.
    mut own?: {string:Places.Found}
  end
end

local type Site = definition.Site
local type Request = definition.Request

local function base_of(node: Ast.Node): Ast.Base
  return node
end

--- The site of the token `token` of the chunk the document's check read.
local function site_of_token(request: Request, token: integer): Site
  local tokens = request.outcome.chunk.tokens
  return { place = request.here, offset = Lexer.offset(tokens, token), length = Lexer.length(tokens, token) }
end

--- Where the module `module` declares `symbol` ([`build.syntax_places`]): in the document's own tree where it is the
--- document's module, else in the places of the module's file ([`source.places`]). nil where it declares none, or the
--- working database lists no such module.
local function place_of(request: Request, module: string, symbol: string): Site?
  if module == request.here.module then
    local own = request.own
    if own == nil then
      local built: mut {string:Places.Found} = {}
      for _, found in ipairs(Places.found(request.outcome.chunk)) do
        if built[found.symbol] == nil then built[found.symbol] = found end
      end
      own = built
      request.own = built
    end
    local found = own[symbol]
    if found == nil then return nil end
    return site_of_token(request, found.token)
  end
  local checker = request.checker
  local placed = source.places(checker.source, module, check.open_files(checker))
  if placed == nil then return nil end
  local spot = placed.spots[symbol]
  if spot == nil then return nil end
  local starts = lines.checker_starts(placed.text)
  local start = starts[spot.line]
  if start == nil then return nil end
  local uri: string
  if placed.carried ~= nil then
    local extracted = source.extracted(checker.source, placed)
    if extracted == nil then return nil end
    uri = protocol.uri_of(extracted)
  else
    uri = protocol.uri_of(checker.root .. "/" .. placed.file)
    local opened = checker.open[placed.file]
    if opened ~= nil then uri = opened.uri end
  end
  return { place = { module = module, original = placed.text, splices = {}, uri = uri },
    offset = start + spot.column - 1, length = spot.length }
end

--- Where the type `decl` is declared.
local function decl_site(request: Request, decl: Types.Decl): Site?
  return place_of(request, decl.module, decl.name)
end

--- Where the field or method `name` of the type `decl` is declared: in the type, or in the interface it lists
--- that declares it, or by a `function R.f()` statement of the module of either.
local function member_site(request: Request, decl: Types.Decl, name: string): Site?
  local owner = decl
  if not Report.has_member(decl, name) then owner = Report.declaring(decl, name) or decl end
  return place_of(request, owner.module, owner.name .. "." .. name)
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
  local scoped = outcome.scoped
  --- The binding the node with id `id` refers to, if the scopes resolved it.
  local function declaration(id: integer): Site?
    local var_id = scoped.resolved[id]
    if var_id == nil then return nil end
    local var = scoped.vars[var_id]
    if var == nil then return nil end
    return site_of_token(request, var.declared)
  end
  if leaf.kind == "Name" then
    local found = declaration(leaf.id)
    if found ~= nil then return found end
    -- The names after the first of `function R.f()` declare where they stand.
    if parent ~= nil and parent.kind == "Function" and parent.path[1] ~= leaf then
      return site_of_token(request, leaf.first)
    end
    return nil
  elseif leaf.kind == "Binding" then
    return site_of_token(request, leaf.first)
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

--- The range of `site`, in the units of the session's encoding, in the text the person has.
local function range_of(request: Request, site: Site): protocol.Range
  local place = site.place
  local first = site.offset
  local last = first + math.max(site.length, 1) - 1
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
  local offset = check.checker_offset(reading, start + lines.byte_of(line, where.character, encoding) - 1)
  local outcome = reading.outcome
  local request: Request = {
    checker = checker, outcome = outcome, encoding = encoding,
    here = { module = outcome.module, original = document.text, splices = reading.splices, uri = document.uri },
  }
  for _, tok in ipairs(tokens_at(outcome.chunk.tokens, offset)) do
    local site = target(request, tok)
    if site ~= nil then return { uri = site.place.uri, range = range_of(request, site) } end
  end
  return nil
end

return definition
