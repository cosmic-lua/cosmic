--- Position is the manifest: whether a file can be reached from outside
--- its own directory is a question of where it sits, not of its name.
---
--- A directory that holds its own `init.tl` is a module in its own
--- right, the ordinary way Lua already resolves `require("a.b")` to
--- `a/b/init.tl`, and every other file directly inside that directory
--- is a sibling, reachable only from a file that itself sits inside it.
--- A flat file with no such directory around it has no sibling to
--- protect and is public by construction. This generalizes the
--- reservation `build.importer` makes for the whole `cosmic` directory
--- to every directory in the tree.
---
--- The `Module` shape lives here, not in `build.importer`, so this
--- check can be a plain function of a module list without the two
--- files requiring one another.

local type compiler = require("build.compiler")
local ast = require("build.ast")

local record positions
  --- One catalog entry: a literal `return nil, ...`/`return false, ...`
  --- message under a top-level function, with the function it is in
  --- -- see `catalog_of`. The guidance a match prints is that
  --- function's own documentation, found in `docs` by symbol.
  record CatalogEntry
    symbol: string
    --- The static text of the returned message, when any of it is a
    --- literal (empty when the whole expression is dynamic, in which
    --- case the entry is never produced at all -- see `static_text`).
    message: string
    line: integer
  end

  --- One documented symbol: a top-level function, a record, enum or
  --- type alias and each field or value it declares, a documented
  --- top-level value, or the module itself -- see `docs_of`.
  record DocEntry
    --- `"Fs.read"`, `"Sqlite.Value.text"`; `""` for the module.
    symbol: string
    --- `"module"`, `"function"`, `"method"`, `"record"`, `"interface"`,
    --- `"enum"`, `"type"`, `"field"`, `"value"`.
    kind: string
    --- The declaration as the source wrote it, one line.
    signature: string
    --- The doc comment, leaders stripped, one line per source line.
    text: string
    line: integer
  end

  --- One use of another module's member through a top-level alias:
  --- `Fs.read(...)` where `local Fs = require("cosmic.fs")` -- see
  --- `references_of`.
  record Reference
    module: string
    member: string
    line: integer
  end

  --- One worked example: a top-level `function Example.<name>()` --
  --- see `examples_of`. `name` is bare (`"read"`), the same name the
  --- paired module's own record declares it under; `build.writer`
  --- resolves the real symbol (`"Fs.read"`) at ship time, against that
  --- record's name, so nothing here has to know it.
  record ExampleEntry
    name: string
    --- The doc comment directly above it, leaders stripped, the same
    --- way `DocEntry.text` reads one -- what the example is FOR; the
    --- source below it is how, and is documentation in its own right.
    text: string
    --- The whole `function Example.<name>() ... end`, as written.
    source: string
    line: integer
  end

  --- What a single parse of a module's source tells the importer: its
  --- own test names, whether it also returns its own value at the top
  --- level and under what name, its catalog entries, its documented
  --- symbols, its worked examples, and what it refers to. Bundled into
  --- one record rather than returned as separate slots: `analyze`'s
  --- first return admits nil (source that fails to lex or parse), and
  --- a fallible return may declare at most two slots -- the extras
  --- ride on the value's record instead.
  record Analysis
    tests: {string}
    has_top_level_return: boolean
    --- The name the chunk's top-level `return` hands back, when it is a
    --- plain name (`return Fs`): what a reference through an alias of
    --- this module resolves against. `""` otherwise.
    export: string
    catalog: {CatalogEntry}
    docs: {DocEntry}
    examples: {ExampleEntry}
    references: {Reference}
  end

  record Module
    path: string
    file: string
    kind: string
    source: string
    source_hash: string
    requires: {string}
    --- The names the runner calls, bare: a `kind = "test"` module's own
    --- `local function test_*` names, or a `kind = "example"` module's
    --- `Example.<name>` names -- empty for any other kind. The two
    --- never mix in one module, since a file is only ever one kind.
    tests: {string}
    has_top_level_return: boolean
    --- True only for a module `build.doctest` produced from a
    --- `doc/guides/*.md` file rather than read off disk as `.tl`
    --- source: `build.importer.compile` widens its warning discount for
    --- exactly this module, and only this one, to cover the one
    --- `print`-shadowing warning that generated shape always carries --
    --- see `discount_doctest_shadow_warnings`.
    generated: boolean
    key: string
    --- The compiled Lua, once `build.importer.compile` has it: made
    --- this run or read back from the cache under the same key.
    lua: string
  end
end

--- A `return nil, $MSG`-shaped statement's message expression, reduced
--- to whatever of it is a literal: a plain string leaf reads as its own
--- text, a `..` concatenation reads as both sides joined the same way,
--- and anything else (a call, a variable) contributes nothing. A
--- message built entirely from such a case (`return nil, describe(e)`)
--- reduces to `""`, which `catalog_of` treats as nothing to catalog --
--- there is no text a person's error could ever contain to match it
--- against.
local function static_text(node: ast.Node): string
  if node == nil then
    return ""
  end
  if node.kind == "string" then
    return node.conststr or ""
  end
  if node.kind == "op" and node.op ~= nil and node.op.op == ".." then
    return static_text(node.e1) .. static_text(node.e2)
  end
  return ""
end

--- One comment's text with its leader gone: `---`, `--`, and the one
--- space that conventionally follows either.
local function comment_body(c: compiler.Comment): string
  return c.text:match("^%-%-%-?%s?(.*)$") or c.text
end

--- The doc comment that ends on the line before `line`, out of the
--- comments tl attached to the token there: the last run of
--- consecutive comment lines, when it is adjacent. Comments separated
--- from a declaration by a blank line belong to something else (the
--- module, most often) and are not its documentation. One line per
--- comment line, leaders stripped, so a paragraph break survives.
local function doc_before(comments: {compiler.Comment}, line: integer): string
  if comments == nil or #comments == 0 then
    return ""
  end
  local last = comments[#comments]
  if last.y ~= line - 1 then
    return ""
  end
  local first = #comments
  while first > 1 and comments[first - 1].y == comments[first].y - 1 do
    first = first - 1
  end
  local parts: {string} = {}
  for index = first, #comments do
    parts[#parts + 1] = comment_body(comments[index])
  end
  return table.concat(parts, "\n")
end

--- Whether a statement is one whose own doc comment sits directly
--- above it: a function or a type declaration. A `local x = ...`
--- opening the file directly under a comment run is not documented
--- by it; the run is the module's.
local function takes_a_doc_comment(stmt: ast.Node): boolean
  local kind = stmt.kind
  return kind == "local_function" or kind == "record_function"
    or kind == "global_function" or kind == "local_type" or kind == "global_type"
end

--- The module's own documentation: the run of comment lines that opens
--- the file, read off the first token, which carries every comment
--- before it (a statement is handed only the run adjacent to it). A
--- run that ends right above a function or type declaration is that
--- declaration's, not the module's.
local function module_doc(parsed: ast.Parsed): string
  local first_token = parsed.tokens[1]
  local comments = first_token ~= nil and first_token.comments or nil
  if comments == nil or #comments == 0 or comments[1].y ~= 1 then
    return ""
  end
  local last = 1
  while last < #comments and comments[last + 1].y == comments[last].y + 1 do
    last = last + 1
  end
  local first_stmt = parsed.node[1]
  if first_stmt ~= nil and takes_a_doc_comment(first_stmt)
     and comments[last].y == first_stmt.y - 1 then
    return ""
  end
  local parts: {string} = {}
  for index = 1, last do
    parts[#parts + 1] = comment_body(comments[index])
  end
  return table.concat(parts, "\n")
end

--- `source` split into its lines, once per analysis.
local function lines_of(source: string): {string}
  local out: {string} = {}
  for line in (source .. "\n"):gmatch("(.-)\n") do
    out[#out + 1] = line
  end
  return out
end

--- One line of `source`, trimmed, or `""` past its end.
local function line_at(lines: {string}, y: integer): string
  local line = lines[y]
  if line == nil then
    return ""
  end
  return (line:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- The source text from one position up to just before another, its
--- lines joined by a single space and runs of whitespace collapsed:
--- how a declaration's own head reads on one line however the source
--- wrapped it.
local function span_text(lines: {string}, y: integer, x: integer,
                         until_y: integer, until_x: integer): string
  local parts: {string} = {}
  for line_no = y, until_y do
    local line = lines[line_no] or ""
    local from = line_no == y and x or 1
    local to = line_no == until_y and until_x - 1 or #line
    parts[#parts + 1] = line:sub(from, to)
  end
  local joined = table.concat(parts, " ")
  return (joined:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", ""))
end

--- A declared function's own name: a `local_function`'s name alone, or
--- a `record_function`'s owner and name joined by `:`/`.` the way it
--- was declared, e.g. `"Sqlite.run"`.
local function symbol_of(stmt: ast.Node): string
  local fn_name = stmt.name
  local tk = fn_name ~= nil and fn_name.tk or nil
  if stmt.kind == "local_function" then
    return tk or ""
  end
  local owner = stmt.fn_owner
  local owner_tk = owner ~= nil and owner.tk or nil
  local sep = stmt.is_method and ":" or "."
  return (owner_tk or "") .. sep .. (tk or "")
end

--- A function declaration's head, from its first token to just before
--- its body: `function Fs.read(path: string): string | nil, string`.
local function function_signature(lines: {string}, stmt: ast.Node): string
  local body = stmt.body
  if body == nil then
    return line_at(lines, stmt.y)
  end
  return span_text(lines, stmt.y, stmt.x, body.y, body.x)
end

--- Every node under a function declared inside `body` -- a nested
--- `local function`, a method, or an anonymous `function` value -- so a
--- hit found there can be told from one in `body`'s own blocks.
--- `ast.find_all` walks the whole subtree and offers no way to stop at
--- a function boundary, so the boundary is drawn here instead.
local function nodes_under_inner_functions(body: ast.Node): {ast.Node: boolean}
  local inner: {ast.Node: boolean} = {}
  ast.walk(body, function(n: ast.Node)
    if n.kind == "local_function" or n.kind == "record_function"
       or n.kind == "global_function" or n.kind == "function" then
      ast.walk(n, function(under: ast.Node)
        inner[under] = true
      end)
    end
  end)
  return inner
end

--- Every honest-return failure inside `stmt`'s own body that carries
--- literal text: `return nil, ...` (a value) and `return false, ...`
--- (an effect) alike, `patterns` carrying one compiled pattern for
--- each. Searches the whole body, nested blocks included (an error
--- return three `if`s deep is exactly as cataloguable as a top-level
--- one) -- but never crosses into a function declared inside it, since
--- that inner function's own returns are not this function's failures.
local function catalog_in_body(body: ast.Node, patterns: {ast.Node},
    symbol: string): {positions.CatalogEntry}
  local out: {positions.CatalogEntry} = {}
  local inner = nodes_under_inner_functions(body)
  for _, pattern in ipairs(patterns) do
    for _, hit in ipairs(ast.find_all(body, pattern)) do
      local msg = hit.caps["_MSG"]
      local text = msg ~= nil and static_text(msg) or ""
      -- A handful of significant characters or better: enough to anchor
      -- an FTS match, so a mostly-interpolated message ("parameter " ..
      -- index .. ": " .. trouble, reduced to "parameter : ") is left
      -- out rather than shipped as a near-universal false match.
      if not inner[hit.node] and #(text:gsub("%A", "")) >= 6 then
        out[#out + 1] = { symbol = symbol, message = text, line = hit.node.y }
      end
    end
  end
  return out
end

--- Every catalog entry a chunk's own top-level functions carry: each
--- `local_function`/`record_function`, paired with the literal text of
--- every honest-return failure its own body returns. Top-level only,
--- the same boundary `analysis_of` already draws for test names -- a
--- function nested inside another statement is reached when THAT
--- statement's own entry is walked, never here.
local function catalog_of(built: compiler, parsed: ast.Parsed): {positions.CatalogEntry}, string
  local patterns: {ast.Node} = {}
  for _, source in ipairs({ "return nil, $MSG", "return false, $MSG" }) do
    local pattern, trouble = ast.compile_pattern(built, source)
    if pattern == nil then
      return {}, trouble
    end
    patterns[#patterns + 1] = pattern
  end
  local out: {positions.CatalogEntry} = {}
  for _, stmt in ipairs(parsed.node) do
    if (stmt.kind == "local_function" or stmt.kind == "record_function")
       and stmt.body ~= nil then
      local symbol = symbol_of(stmt)
      for _, entry in ipairs(catalog_in_body(stmt.body, patterns, symbol)) do
        out[#out + 1] = entry
      end
    end
  end
  return out, ""
end

--- The values of an enum, in a stable order: tl keeps them as a set.
local function enum_values(def: ast.TypeNode): {string}
  local out: {string} = {}
  local set = def.enumset
  if set == nil then
    return out
  end
  for value in pairs(set) do
    out[#out + 1] = value
  end
  table.sort(out)
  return out
end

--- A type declaration's definition, with a generic's type arguments
--- looked through.
local function definition_of(typedecl: ast.TypeNode): ast.TypeNode
  local def = typedecl.def
  if def ~= nil and def.typename == "generic" and def.t ~= nil then
    return def.t
  end
  return def
end

--- Adds the entries for one record, interface, or enum body under
--- `symbol`: one per field, in declaration order, with a nested
--- record or enum recursing under its own name.
local function record_docs(lines: {string}, symbol: string,
                           def: ast.TypeNode, out: {positions.DocEntry})
  if def.typename == "enum" then
    local value_comments = def.value_comments
    for _, value in ipairs(enum_values(def)) do
      local text = ""
      if value_comments ~= nil then
        local comments = value_comments[value]
        if comments ~= nil and #comments > 0 then
          text = doc_before(comments, comments[#comments].y + 1)
        end
      end
      out[#out + 1] = { symbol = symbol .. "." .. value, kind = "value",
        signature = string.format("%q", value), text = text, line = def.y }
    end
    return
  end
  local order = def.field_order
  local fields = def.fields
  local field_comments = def.field_comments
  if order == nil or fields == nil then
    return
  end
  for _, name in ipairs(order) do
    local field = fields[name]
    if field ~= nil then
      local comments: {compiler.Comment} = nil
      if field_comments ~= nil then
        local lists = field_comments[name]
        if lists ~= nil then
          comments = lists[1]
        end
      end
      local field_symbol = symbol .. "." .. name
      local nested = field.typename == "typedecl" and definition_of(field) or nil
      if nested ~= nil and (nested.typename == "record"
         or nested.typename == "interface" or nested.typename == "enum") then
        out[#out + 1] = { symbol = field_symbol, kind = nested.typename,
          signature = line_at(lines, field.y),
          text = doc_before(comments, field.y), line = field.y }
        record_docs(lines, field_symbol, nested, out)
      else
        out[#out + 1] = { symbol = field_symbol, kind = "field",
          signature = line_at(lines, field.y),
          text = doc_before(comments, field.y), line = field.y }
      end
    end
  end
end

--- Whether `stmt` is a top-level `function Example.<name>()` --
--- `examples_of`'s own shape, kept out of `docs_of` so a worked
--- example is never also shipped as a trivial doc entry of its own.
local function is_example_function(stmt: ast.Node): boolean
  local owner = stmt.fn_owner
  return stmt.kind == "record_function" and owner ~= nil and owner.tk == "Example"
end

--- Every documented symbol a chunk declares at its top level, in
--- source order: the module itself when the file opens with a comment
--- of its own, each function, each record, interface, enum or alias
--- and the fields and values under it, and each `local` whose
--- declaration carries a doc comment. Every function is here, whether
--- or not it is documented, so `cosmic docs` can find where an
--- undocumented one lives; a bare `local x = ...` is not, since a
--- module's private bindings are not its surface. A worked example
--- (`examples_of`) is not either -- it documents another module's
--- symbol, not this one's.
local function docs_of(lines: {string}, parsed: ast.Parsed): {positions.DocEntry}
  local out: {positions.DocEntry} = {}
  local opening = module_doc(parsed)
  if #opening > 0 then
    out[#out + 1] = { symbol = "", kind = "module", signature = "",
      text = opening, line = 1 }
  end
  for _, stmt in ipairs(parsed.node) do
    if (stmt.kind == "local_function" or stmt.kind == "record_function"
        or stmt.kind == "global_function") and not is_example_function(stmt) then
      out[#out + 1] = { symbol = symbol_of(stmt),
        kind = stmt.is_method and "method" or "function",
        signature = function_signature(lines, stmt),
        text = doc_before(stmt.comments, stmt.y), line = stmt.y }
    elseif stmt.kind == "local_type" or stmt.kind == "global_type" then
      local var = stmt.var
      local value = stmt.value
      local typedecl = value ~= nil and value.kind == "newtype" and value.newtype or nil
      if var ~= nil and typedecl ~= nil then
        local symbol = var.tk or ""
        local def = definition_of(typedecl)
        local kind = "type"
        if not typedecl.is_alias and def ~= nil and (def.typename == "record"
           or def.typename == "interface" or def.typename == "enum") then
          kind = def.typename
        end
        out[#out + 1] = { symbol = symbol, kind = kind,
          signature = line_at(lines, stmt.y),
          text = doc_before(stmt.comments, stmt.y), line = stmt.y }
        if kind ~= "type" and def ~= nil then
          record_docs(lines, symbol, def, out)
        end
      end
    elseif stmt.kind == "local_declaration" and stmt.vars ~= nil
           and stmt.vars[1] ~= nil then
      local text = doc_before(stmt.comments, stmt.y)
      -- The run above the file's first `local` is the module's (see
      -- `module_doc`), never that value's.
      if stmt == parsed.node[1] and #opening > 0 then
        text = ""
      end
      if #text > 0 then
        out[#out + 1] = { symbol = stmt.vars[1].tk or "", kind = "value",
          signature = line_at(lines, stmt.y), text = text, line = stmt.y }
      end
    end
  end
  return out
end

--- The source from one top-level statement's own start up to just
--- before the next one's, or to the end of the chunk for the last --
--- an example is always exactly one top-level statement, so this is
--- its whole, as-written text, lines and indentation kept, unlike
--- `span_text`'s one-line collapse. A trailing blank or comment-only
--- line belongs to whatever sits after it, not to this statement, so
--- it is trimmed rather than shown as part of the example.
local function block_text(lines: {string}, y: integer, x: integer,
                          until_y: integer, until_x: integer): string
  local parts: {string} = {}
  for line_no = y, until_y do
    local line = lines[line_no] or ""
    local from = line_no == y and x or 1
    local to = line_no == until_y and (until_x - 1) or #line
    parts[#parts + 1] = line:sub(from, to)
  end
  while #parts > 0 and (parts[#parts]:match("^%s*$") ~= nil
     or parts[#parts]:match("^%s*%-%-") ~= nil) do
    parts[#parts] = nil
  end
  return table.concat(parts, "\n")
end

--- Every worked example a chunk declares at its top level: a
--- `function Example.<name>()`, found the same structural way
--- `docs_of` already finds `function Fs.read(...)` -- no tag names the
--- association, only the shape of the declaration itself. `name` is
--- bare; `build.writer`'s `insert_examples` resolves it against the
--- paired module's own record name at ship time. Its own doc comment
--- is read the same way `docs_of` reads one, since an example is
--- documentation too -- what it is for in the comment, how in the
--- code below it.
local function examples_of(lines: {string}, parsed: ast.Parsed): {positions.ExampleEntry}
  local out: {positions.ExampleEntry} = {}
  local nodes = parsed.node
  for index, stmt in ipairs(nodes) do
    if is_example_function(stmt) then
      local name = stmt.name
      local tk = name ~= nil and name.tk or nil
      if tk ~= nil then
        local after = nodes[index + 1]
        local until_y = after ~= nil and after.y or (#lines + 1)
        local until_x = after ~= nil and after.x or 1
        out[#out + 1] = { name = tk,
          text = doc_before(stmt.comments, stmt.y),
          source = block_text(lines, stmt.y, stmt.x, until_y, until_x),
          line = stmt.y }
      end
    end
  end
  return out
end

--- The names a chunk binds at its top level to a `require`, each to
--- the module it names: `local Fs = require("cosmic.fs")` binds `Fs`.
--- Only this narrow shape, sitting directly among the top-level
--- statements -- the same slice `build.ast.requires` draws, for every
--- prefix rather than `cosmic.` alone.
local function aliases_of(built: compiler, parsed: ast.Parsed): {string: string}, string
  local pattern, trouble = ast.compile_pattern(built, "local $ALIAS = require($M)")
  if pattern == nil then
    return {}, trouble
  end
  local top_level: {ast.Node: boolean} = {}
  for _, stmt in ipairs(parsed.node) do
    top_level[stmt] = true
  end
  local out: {string: string} = {}
  for _, hit in ipairs(ast.find_all(parsed.node, pattern)) do
    local alias = hit.caps["_ALIAS"]
    local named = hit.caps["_M"]
    if top_level[hit.node] and alias ~= nil and alias.tk ~= nil
       and named ~= nil and named.kind == "string" and named.conststr ~= nil then
      out[alias.tk] = named.conststr
    end
  end
  return out, ""
end

--- Every `alias.member` a chunk reads, where `alias` is one of its
--- top-level require aliases: a reference from this module to that
--- member of the module the alias names, at the line it sits on. One
--- entry per member per line, in source order.
local function references_of(built: compiler, parsed: ast.Parsed): {positions.Reference}, string
  local aliases, trouble = aliases_of(built, parsed)
  if trouble ~= "" then
    return {}, trouble
  end
  local seen: {string: boolean} = {}
  local out: {positions.Reference} = {}
  ast.walk(parsed.node, function(n: ast.Node)
    if n.kind == "op" and n.op ~= nil and n.op.op == "." and n.e1 ~= nil
       and n.e2 ~= nil and n.e1.kind == "variable" and n.e1.tk ~= nil
       and n.e2.tk ~= nil then
      local module = aliases[n.e1.tk]
      if module ~= nil then
        local id = module .. "\n" .. n.e2.tk .. "\n" .. n.e1.y
        if not seen[id] then
          seen[id] = true
          out[#out + 1] = { module = module, member = n.e2.tk, line = n.e1.y }
        end
      end
    end
  end)
  table.sort(out, function(p: positions.Reference, q: positions.Reference): boolean
    if p.line ~= q.line then
      return p.line < q.line
    end
    if p.module ~= q.module then
      return p.module < q.module
    end
    return p.member < q.member
  end)
  return out, ""
end

--- The same facts, read off a chunk something else already parsed, so a
--- caller that needs the parse for another question too pays for it
--- once. `built` is needed only to compile the patterns the catalog
--- and the references match against; a pattern-compile failure (which
--- nothing in this tree's own source should ever trigger) is reported
--- as an ordinary failure rather than silently dropping them. `source`
--- is the text `parsed` came from, for the signatures the docs quote.
function positions.analysis_of(built: compiler, parsed: ast.Parsed,
                               source: string): positions.Analysis | nil, string
  local names: {string} = {}
  local has_return = false
  local export = ""
  for _, stmt in ipairs(parsed.node) do
    if stmt.kind == "local_function" then
      local fn_name = stmt.name
      local tk = fn_name ~= nil and fn_name.tk or nil
      if tk ~= nil and tk:match("^test_") ~= nil then
        names[#names + 1] = tk
      end
    elseif stmt.kind == "return" then
      has_return = true
      local exps = stmt.exps
      local returned = exps ~= nil and exps[1] or nil
      if returned ~= nil and returned.kind == "variable" and returned.tk ~= nil then
        export = returned.tk
      end
    end
  end
  local catalog, catalog_trouble = catalog_of(built, parsed)
  if catalog_trouble ~= "" then
    return nil, catalog_trouble
  end
  local references, reference_trouble = references_of(built, parsed)
  if reference_trouble ~= "" then
    return nil, reference_trouble
  end
  local lines = lines_of(source)
  return {
    tests = names, has_top_level_return = has_return, export = export,
    catalog = catalog, docs = docs_of(lines, parsed),
    examples = examples_of(lines, parsed), references = references,
  }, ""
end

--- Both facts an importer needs from a `kind = "test"` module's source,
--- from one parse: the name of every top-level `local function test_*`,
--- in the order they appear, and whether the chunk also has a genuine
--- top-level (chunk-level) `return` statement -- the two are read
--- together off the same parsed chunk's own top-level statement array
--- so the source is never parsed twice for the two questions.
---
--- A test name is any direct element of that array (never a recursive
--- walk) whose kind is `"local_function"` and whose declared name
--- matches `^test_`. An indented one lives inside some OTHER
--- statement's own body, not the chunk's own array part, so it is
--- never reached here; a source SAMPLE held as a string literal is
--- never parsed as a statement at all, so there is no bracket-tracking
--- left to get wrong.
---
--- A genuine top-level return is any direct element of that same array
--- whose kind is `"return"`. Lua requires a `return` to be the last
--- statement of the block it sits in, so a module that type-checks at
--- all can only have one as its own chunk's final statement -- never
--- one a nested `if`, loop, or function body left behind, since those
--- parse as children of that inner block's own "statements" node,
--- never as an element of the chunk's own array.
---
--- An ordinary snake_case identifier or call starting with the six
--- letters `return` (`return_code = 1`, `return_value(x)`) parses to
--- an `"assignment"` or `"op"` node, never `"return"` -- there is no
--- text boundary to get wrong the way a pattern match over raw source
--- has to draw one by hand.
--- @param built compiler The loaded compiler capsule (`build.teal.load()`)
--- @param source string
--- @param name string Filename for parse diagnostics
--- @return Analysis | nil Every top-level test name plus the top-level-return fact
--- @return string Error message when `source` fails to lex or parse
function positions.analyze(built: compiler, source: string,
                           name: string): positions.Analysis | nil, string
  local parsed, trouble = ast.parse(built, source, name)
  if parsed == nil then
    return nil, trouble
  end
  return positions.analysis_of(built, parsed, source)
end

--- The file's own name, with no directory in front of it.
local function basename(file: string): string
  return file:match("([^/]+)$") or file
end

--- The directory a file sits in, or "" when it sits at the tree's root.
local function dirname(file: string): string
  return file:match("^(.*)/[^/]+$") or ""
end

--- Whether every require in `modules` respects sibling privacy, and if
--- not, which one and why.
--- @param modules every module the tree holds, with its requires
function positions.check(modules: {positions.Module}): boolean, string
  local by_path: {string:positions.Module} = {}
  local private_dirs: {string:boolean} = {}
  for _, m in ipairs(modules) do
    by_path[m.path] = m
    if basename(m.file) == "init.tl" then
      local dir = dirname(m.file)
      if dir ~= "" then
        private_dirs[dir] = true
      end
    end
  end
  for _, m in ipairs(modules) do
    for _, name in ipairs(m.requires) do
      local other = by_path[name]
      if other ~= nil then
        local dir = dirname(other.file)
        if private_dirs[dir] and other.file ~= dir .. "/init.tl" then
          local inside = m.file:sub(1, #dir + 1) == dir .. "/"
          if not inside then
            return false, m.file .. ": " .. name .. " is private to " ..
              dir .. "/; only a file inside it may import it"
          end
        end
      end
    end
  end
  return true, ""
end

return positions
