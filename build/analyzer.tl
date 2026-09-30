--- The source analyzer: what one parse of a module's source tells the
--- importer about it -- its own test names, whether it returns its own
--- value at the top level and under what name, the failure messages it
--- catalogs, the symbols it documents, its worked examples, and the
--- members of other modules it refers to. See [`analyzer.analyze`], and
--- [`analyzer.analysis_of`] for a chunk already parsed.

local type compiler = require("build.compiler")
local ast = require("build.ast")
local String = require("cosmic.string")
local Test = require("cosmic.test")
local cache_names = require("build.cache_names")

local record analyzer
  --- One catalog entry: a literal `return nil, ...`/`return false, ...`
  --- message under a top-level function, with the function it is in
  --- -- see [`catalog_of`]. The guidance a match prints is that
  --- function's own documentation, found in `docs` by symbol.
  record CatalogEntry
    symbol: string
    --- The literal text of the returned message, its dynamic parts left
    --- out ([`static_text`]). An entry exists only when at least six of
    --- its characters are letters ([`catalog_in_body`]).
    message: string
    line: integer
  end

  --- One documented symbol: a top-level function, a record, enum or
  --- type alias and each field or value it declares, a documented
  --- top-level value, or the module itself -- see [`docs_of`].
  record DocEntry
    --- Canonical exported path (`"read"`, `"Value.text"`), or the
    --- declaration spelling for a private entry; `""` for the module.
    symbol: string
    --- The declaration spelling (`"Fs.read"`) retained for display and
    --- source navigation. This is not identity.
    source_symbol: string
    --- Whether `symbol` is reachable through the returned module value.
    exported: boolean
    --- `"module"`, `"function"`, `"method"`, `"record"`, `"interface"`,
    --- `"enum"`, `"type"`, `"field"`, `"metamethod"`, `"value"`.
    kind: string
    --- The declaration as the source wrote it, one line.
    signature: string
    --- The doc comment, leaders stripped, one line per source line.
    text: string
    line: integer
  end

  --- One use of another module's member through a top-level alias:
  --- `Fs.read(...)` where `local Fs = require("cosmic.fs")` -- see
  --- [`references_of`].
  record Reference
    module: string
    member: string
    line: integer
  end

  --- One worked example: a top-level `function Example.<name>()` --
  --- see [`examples_of`]. `name` is a free label, not a symbol. Which
  --- symbol an example demonstrates is decided when [`build.docs`] reads
  --- it, by matching the example's text and source against the
  --- symbol's name: its code calls the function it demonstrates.
  record ExampleEntry
    name: string
    --- The doc comment directly above it, leaders stripped, the same
    --- way [`DocEntry.text`] reads one -- what the example is FOR; the
    --- source below it is how, and is documentation in its own right.
    text: string
    --- The whole `function Example.<name>() ... end`, as written, under
    --- the file's top-level `require` lines it uses and, for the file's
    --- first example, its top-level calls ([`examples_of`]).
    source: string
    line: integer
  end

  --- A test module's `needs` declaration ([`cosmic.test`]), read as
  --- data -- see [`inputs_of`]. A flag declared `false` reads as one never
  --- declared.
  record Declared
    --- The line the declaration starts on.
    line: integer
    reads: {string}
    host: {string}
    env: {string}
    network: {string}
    tool: boolean
    nests: boolean
    store: boolean
    system: boolean
    caches: {string}
  end

  --- What a single parse of a module's source tells the importer: its
  --- own test names, whether it also returns its own value at the top
  --- level and under what name, its catalog entries, its documented
  --- symbols, its worked examples, and what it refers to. They come in
  --- one record because `analyze`'s first return admits nil (source that
  --- fails to lex or parse), and a fallible return may declare at most
  --- two slots.
  record Analysis
    tests: {string}
    --- The chunk's `Test.needs { ... }` declaration, or nil for none.
    inputs: Declared | nil
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
end

--- A `return nil, $MSG`-shaped statement's message expression, reduced
--- to whatever of it is a literal: a plain string leaf reads as its own
--- text, a `..` concatenation reads as both sides joined the same way,
--- and anything else (a call, a variable) contributes nothing. A
--- message built entirely from such a case (`return nil, describe(e)`)
--- reduces to `""`, which [`catalog_of`] treats as nothing to catalog --
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

--- Whether a comment is a `---` doc comment.
local function is_doc(c: compiler.Comment): boolean
  return c.text:sub(1, 3) == "---"
end

--- The body of each comment in `run` (a run of consecutive lines) that
--- is documentation: the `---` lines when the run has any, so a `--`
--- note beside them (a `TODO:`) stays out of the doc text, and every
--- line of a run of `--` alone, which documents a script or a module.
local function doc_bodies(run: {compiler.Comment}): {string}
  local any = false
  for _, c in ipairs(run) do
    if is_doc(c) then any = true end
  end
  local parts: {string} = {}
  for _, c in ipairs(run) do
    if is_doc(c) or not any then
      parts[#parts + 1] = comment_body(c)
    end
  end
  return parts
end

--- Whether a comment trails code on its own line (`s: string -- why`)
--- rather than standing on lines of its own. A trailing comment is a note
--- on what it follows, never the documentation of the declaration below:
--- as everywhere in this tree, a doc comment is the run above.
local function trails_code(lines: {string}, c: compiler.Comment): boolean
  local line = lines[c.y]
  return line ~= nil and String.trim(line:sub(1, c.x - 1)) ~= ""
end

--- The doc comment that ends on the line before `line`, out of the
--- comments tl attached to the token there: the last run of
--- consecutive comment lines, when it is adjacent. Comments separated
--- from a declaration by a blank line belong to something else (the
--- module, most often) and are not its documentation, and a comment
--- trailing the code before it ([`trails_code`]) is not part of the run
--- it starts. One line per comment line, leaders stripped, so a
--- paragraph break survives.
local function doc_before(lines: {string}, all: {compiler.Comment}, line: integer): string
  if all == nil or #all == 0 then
    return ""
  end
  local comments: {compiler.Comment} = {}
  for _, c in ipairs(all) do
    if not trails_code(lines, c) then
      comments[#comments + 1] = c
    end
  end
  if #comments == 0 then
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
  local run: {compiler.Comment} = {}
  for index = first, #comments do
    run[#run + 1] = comments[index]
  end
  return table.concat(doc_bodies(run), "\n")
end

--- Whether a statement is a function declaration, whose own doc comment
--- sits directly above it. A run of comments ending right above a
--- record or a type is the module's as well as that declaration's, when
--- it opens the file; above a function it is the function's alone.
local function takes_a_doc_comment(stmt: ast.Node): boolean
  local kind = stmt.kind
  return kind == "local_function" or kind == "record_function"
    or kind == "global_function"
end

--- The module's own documentation: the run of comment lines that opens
--- the file, read off the first token, which carries every comment
--- before it (a statement is handed only the run adjacent to it), and
--- the line it starts on. A leading `#!` line is no token of the code
--- (the lexer keeps it as one of its own), so the run is read off the
--- token after it; blank lines before the run do not end it. A run that
--- ends right above a function declaration is that function's, not the
--- module's; above a record or a type it is both's.
local function module_doc(parsed: ast.Parsed): string, integer
  local at = 1
  local shebang = parsed.tokens[1]
  if shebang ~= nil and shebang.tk:sub(1, 2) == "#!" then
    at = 2
  end
  local first_token = parsed.tokens[at]
  local comments = first_token ~= nil and first_token.comments or nil
  if comments == nil or #comments == 0 then
    return "", 1
  end
  local last = 1
  while last < #comments and comments[last + 1].y == comments[last].y + 1 do
    last = last + 1
  end
  local first_stmt = parsed.node[1]
  if first_stmt ~= nil and takes_a_doc_comment(first_stmt)
     and comments[last].y == first_stmt.y - 1 then
    return "", 1
  end
  local run: {compiler.Comment} = {}
  for index = 1, last do
    run[#run + 1] = comments[index]
  end
  return table.concat(doc_bodies(run), "\n"), comments[1].y
end

--- `source` split into its lines, once per analysis.
local function lines_of(source: string): {string}
  return String.split(source, "\n")
end

--- One line of `source`, trimmed, or `""` past its end.
local function line_at(lines: {string}, y: integer): string
  local line = lines[y]
  if line == nil then
    return ""
  end
  return String.trim(line)
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
  return String.trim((joined:gsub("%s+", " ")))
end

--- A `record_function`'s owner spelled in full: a plain name (`Thing`)
--- carries its own `tk`, and a nested record's (`Thing.Box`) is a chain
--- of `.` operators the parser built from the declaration's names.
local function owner_name(owner: ast.Node | nil): string
  if owner == nil then
    return ""
  end
  if owner.tk ~= nil then
    return owner.tk
  end
  local op, member = owner.op, owner.e2
  if owner.kind == "op" and op ~= nil and op.op == "." and member ~= nil
     and member.tk ~= nil then
    return owner_name(owner.e1) .. "." .. member.tk
  end
  return ""
end

--- A declared function's own name: a `local_function`'s name alone, or
--- a `record_function`'s owner, in full, and name joined by `:`/`.` the
--- way it was declared, e.g. `"Sqlite.run"`, `"Thing.Box:grow"`.
local function symbol_of(stmt: ast.Node): string
  local fn_name = stmt.name
  local tk = fn_name ~= nil and fn_name.tk or nil
  if stmt.kind == "local_function" then
    return tk or ""
  end
  local sep = stmt.is_method and ":" or "."
  return owner_name(stmt.fn_owner) .. sep .. (tk or "")
end

--- The tokens' index of the one at `y`, `x`, or nil when none starts there.
local function token_at(tokens: {compiler.Token}, y: integer, x: integer): integer | nil
  local low, high = 1, #tokens
  while low <= high do
    local mid = (low + high) // 2
    local token = tokens[mid]
    if token.y == y and token.x == x then
      return mid
    elseif token.y < y or (token.y == y and token.x < x) then
      low = mid + 1
    else
      high = mid - 1
    end
  end
  return nil
end

--- A function declaration's head, from its first token to just before
--- its body: `function Fs.read(path: string): string | nil, string`. It
--- ends at the head's own last token, not at the body's first statement,
--- so a comment that opens the body (`-- A tail call: ...`) is not read
--- as part of the head; a comment inside the head is left out too, as it
--- would swallow the words after it once the lines are joined.
local function function_signature(lines: {string}, tokens: {compiler.Token},
                                  stmt: ast.Node): string
  local body = stmt.body
  if body == nil then
    return line_at(lines, stmt.y)
  end
  local first = token_at(tokens, stmt.y, stmt.x)
  local start = token_at(tokens, body.y, body.x)
  if first == nil or start == nil or start <= first then
    return span_text(lines, stmt.y, stmt.x, body.y, body.x)
  end
  local last = tokens[start - 1]
  -- The head's own lines, each comment in it (a `--` one to its line's
  -- end, a `--[[ ]]` one over its own text) blanked out, so it cannot
  -- swallow the words after it once the lines are joined.
  local head: {integer: string} = {}
  for line_no = stmt.y, last.y do
    head[line_no] = lines[line_no] or ""
  end
  for at = first + 1, start - 1 do
    for _, comment in ipairs(tokens[at].comments or {}) do
      local line_no, column = comment.y, comment.x
      for piece in (comment.text .. "\n"):gmatch("(.-)\n") do
        local line = head[line_no]
        if line ~= nil then
          head[line_no] = line:sub(1, column - 1) .. string.rep(" ", #piece) ..
            line:sub(column + #piece)
        end
        line_no, column = line_no + 1, 1
      end
    end
  end
  local parts: {string} = {}
  for line_no = stmt.y, last.y do
    local line = head[line_no]
    local from = line_no == stmt.y and stmt.x or 1
    local to = line_no == last.y and last.x + #last.tk - 1 or #line
    parts[#parts + 1] = line:sub(from, to)
  end
  -- A parameter list wrapped after its `(` or before its `)` reads as
  -- if written tight.
  local joined = String.trim((table.concat(parts, " "):gsub("%s+", " ")))
  return (joined:gsub("%( ", "("):gsub(" %)", ")"))
end

--- Every node under a function declared inside `body` -- a nested
--- `local function`, a method, or an anonymous `function` value -- so a
--- hit found there can be told from one in `body`'s own blocks.
--- [`ast.find_all`] walks the whole subtree and offers no way to stop at
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
    symbol: string): {analyzer.CatalogEntry}
  local out: {analyzer.CatalogEntry} = {}
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
--- the boundary [`analysis_of`] draws for test names: a function nested
--- inside another statement is reached through that statement's own
--- entry, never here.
local function catalog_of(built: compiler, parsed: ast.Parsed): {analyzer.CatalogEntry}, string
  local patterns: {ast.Node} = {}
  for _, source in ipairs({ "return nil, $MSG", "return false, $MSG" }) do
    local pattern, trouble = ast.compile_pattern(built, source)
    if pattern == nil then
      return {}, trouble
    end
    patterns[#patterns + 1] = pattern
  end
  local out: {analyzer.CatalogEntry} = {}
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

--- A record field's declaration on one line, however many the source
--- spent on it: from the field's name to the end of its type. `field`
--- is the type; its tokens run until one at bracket depth 0 opens a new
--- line without the previous token asking for more (a `,` or `|`, or
--- itself a `|`), which is the next field or the record's `end`.
local function field_signature(lines: {string}, tokens: {compiler.Token},
                               field: ast.TypeNode): string
  local first = token_at(tokens, field.y, field.x)
  if first == nil then
    return line_at(lines, field.y)
  end
  local depth = 0
  local last = first
  -- Where a comment starts on each line the type spans: a comment inside
  -- a signature is left out, as it would swallow the words after it
  -- once the lines are joined.
  local comment_at: {integer: integer} = {}
  for at = first, #tokens do
    local token = tokens[at]
    local tk = token.tk
    local previous = tokens[at - 1]
    if at > first and depth <= 0 and token.y > previous.y and tk ~= "|"
       and previous.tk ~= "," and previous.tk ~= "|" and previous.tk ~= ":" then
      break
    end
    if token.comments ~= nil and at > first then
      for _, comment in ipairs(token.comments) do
        if comment_at[comment.y] == nil then
          comment_at[comment.y] = comment.x
        end
      end
    end
    if tk == "(" or tk == "{" or tk == "[" or tk == "<" then
      depth = depth + 1
    elseif tk == ")" or tk == "}" or tk == "]" or tk == ">" then
      depth = depth - 1
    elseif tk == ">>" then
      depth = depth - 2
    end
    last = at
  end
  local end_token = tokens[last]
  if end_token.y == field.y then
    return line_at(lines, field.y)
  end
  local parts: {string} = {}
  for line_no = field.y, end_token.y do
    local line = lines[line_no] or ""
    local to = line_no == end_token.y and end_token.x + #end_token.tk - 1 or #line
    local cut = comment_at[line_no]
    if cut ~= nil and line_no ~= end_token.y and cut - 1 < to then
      to = cut - 1
    end
    parts[#parts + 1] = line:sub(1, to)
  end
  return String.trim((table.concat(parts, " "):gsub("%s+", " ")))
end

-- Declared ahead: [`fields_docs`] and `record_docs` call each other.
local record_docs: function(lines: {string}, tokens: {compiler.Token}, symbol: string,
                           def: ast.TypeNode, out: {analyzer.DocEntry})

--- Adds the entries for one group of a record's or interface's fields
--- under `symbol`, in the order given, with a nested record or enum
--- recursing under its own name. `metamethod` marks the group the
--- `metamethod` declarations are: their kind is `"metamethod"`, and
--- their signature keeps the keyword, as the source spells it.
local function fields_docs(lines: {string}, tokens: {compiler.Token}, symbol: string,
                           order: {string}, fields: {string: ast.TypeNode},
                           field_comments: {string: {{compiler.Comment}}},
                           metamethod: boolean, out: {analyzer.DocEntry})
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
      if field.typename == "generic" and field.t ~= nil then
        field = field.t
      end
      local start = token_at(tokens, field.y, field.x)
      local nested = field.typename == "typedecl" and definition_of(field) or nil
      if metamethod then
        -- The `__is` a `where` clause makes up has no line of its own: its
        -- type sits at the `where`.
        if start == nil or tokens[start].tk ~= "where" then
          out[#out + 1] = { symbol = field_symbol, source_symbol = field_symbol,
            exported = false, kind = "metamethod",
            signature = field_signature(lines, tokens, field),
            text = doc_before(lines, comments, field.y), line = field.y }
        end
      elseif nested ~= nil and (nested.typename == "record"
         or nested.typename == "interface" or nested.typename == "enum") then
        out[#out + 1] = { symbol = field_symbol, source_symbol = field_symbol,
          exported = false, kind = nested.typename,
          signature = line_at(lines, field.y),
          text = doc_before(lines, comments, field.y), line = field.y }
        record_docs(lines, tokens, field_symbol, nested, out)
      else
        out[#out + 1] = { symbol = field_symbol, source_symbol = field_symbol,
          exported = false, kind = "field",
          signature = field_signature(lines, tokens, field),
          text = doc_before(lines, comments, field.y), line = field.y }
      end
    end
  end
end

--- Adds the entries for one record, interface, or enum body under
--- `symbol`: one per field, in declaration order, with a nested
--- record or enum recursing under its own name, then one per
--- `metamethod` field, in its own order.
record_docs = function(lines: {string}, tokens: {compiler.Token}, symbol: string,
                       def: ast.TypeNode, out: {analyzer.DocEntry})
  if def.typename == "enum" then
    local value_comments = def.value_comments
    for _, value in ipairs(enum_values(def)) do
      local text = ""
      if value_comments ~= nil then
        local comments = value_comments[value]
        if comments ~= nil and #comments > 0 then
          text = doc_before(lines, comments, comments[#comments].y + 1)
        end
      end
      local full = symbol .. "." .. value
      out[#out + 1] = { symbol = full, source_symbol = full, exported = false,
        kind = "value",
        signature = string.format("%q", value), text = text, line = def.y }
    end
    return
  end
  local order = def.field_order
  local fields = def.fields
  if order ~= nil and fields ~= nil then
    fields_docs(lines, tokens, symbol, order, fields, def.field_comments, false, out)
  end
  local meta_order = def.meta_field_order
  local meta_fields = def.meta_fields
  if meta_order ~= nil and meta_fields ~= nil then
    fields_docs(lines, tokens, symbol, meta_order, meta_fields,
      def.meta_field_comments, true, out)
  end
end

--- Whether `stmt` is a top-level `function Example.<name>()` --
--- [`examples_of`]'s own shape, kept out of [`docs_of`] so a worked
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
--- ([`examples_of`]) is left out too: it documents another module's
--- symbol, not this one's.
local function docs_of(lines: {string}, parsed: ast.Parsed): {analyzer.DocEntry}
  local out: {analyzer.DocEntry} = {}
  local opening, opening_line = module_doc(parsed)
  if #opening > 0 then
    out[#out + 1] = { symbol = "", source_symbol = "", exported = true,
      kind = "module", signature = "", text = opening, line = opening_line }
  end
  for _, stmt in ipairs(parsed.node) do
    if (stmt.kind == "local_function" or stmt.kind == "record_function"
        or stmt.kind == "global_function") and not is_example_function(stmt) then
      local symbol = symbol_of(stmt)
      out[#out + 1] = { symbol = symbol, source_symbol = symbol, exported = false,
        kind = stmt.is_method and "method" or "function",
        signature = function_signature(lines, parsed.tokens, stmt),
        text = doc_before(lines, stmt.comments, stmt.y), line = stmt.y }
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
        out[#out + 1] = { symbol = symbol, source_symbol = symbol, exported = false,
          kind = kind,
          signature = line_at(lines, stmt.y),
          text = doc_before(lines, stmt.comments, stmt.y), line = stmt.y }
        if kind ~= "type" and def ~= nil then
          record_docs(lines, parsed.tokens, symbol, def, out)
        end
      end
    elseif stmt.kind == "local_declaration" and stmt.vars ~= nil
           and stmt.vars[1] ~= nil then
      local text = doc_before(lines, stmt.comments, stmt.y)
      -- The run above the file's first `local` is the module's (see
      -- [`module_doc`]), never that value's.
      if stmt == parsed.node[1] and #opening > 0 then
        text = ""
      end
      if #text > 0 then
        local symbol = stmt.vars[1].tk or ""
        out[#out + 1] = { symbol = symbol, source_symbol = symbol,
          exported = false, kind = "value",
          signature = line_at(lines, stmt.y), text = text, line = stmt.y }
      end
    end
  end
  return out
end

--- The record the module's returned value is typed as. A module that
--- returns a variable declared `local x: Thing = ...` hands out `Thing`'s
--- fields, so `Thing` and what is declared under it are the module's
--- surface, though the returned name is `x`; otherwise the returned
--- name itself. Its rows stay under their own names: the fields are
--- still `Thing.f`, as a caller reading the source sees them.
local function surface_of(parsed: ast.Parsed, export: string,
                          entries: {analyzer.DocEntry}): string
  if export == "" then
    return ""
  end
  for _, stmt in ipairs(parsed.node) do
    local vars = stmt.vars or {}
    local declared = stmt.decltuple ~= nil and stmt.decltuple.tuple or nil
    local written = declared ~= nil and declared[1] or nil
    local names = written ~= nil and written.typename == "nominal" and written.names or nil
    if stmt.kind == "local_declaration" and #vars == 1 and vars[1].tk == export
       and names ~= nil and #names == 1 then
      for _, entry in ipairs(entries) do
        if entry.source_symbol == names[1] and entry.kind == "record" then
          return names[1]
        end
      end
    end
  end
  return export
end

--- Marks as exported what a module hands out without naming it in its
--- returned value: the record its returned variable is typed as (see
--- [`surface_of`]), and every `local` record, enum, interface or type
--- an exported row's signature names, again for each one that joins,
--- since a caller meets those names in the signatures it reads. A
--- `local` type no exported signature reaches stays private; a member
--- named `_x` is no caller's to read, so its signature reaches nothing.
local function mark_reachable_types(entries: {analyzer.DocEntry}, surface: string,
                                    export: string)
  local function under(entry: analyzer.DocEntry, root: string): boolean
    return entry.source_symbol == root
      or entry.source_symbol:sub(1, #root + 1) == root .. "."
  end
  if surface ~= export then
    for _, entry in ipairs(entries) do
      if under(entry, surface) then
        entry.exported = true
      end
    end
  end
  local searched: {analyzer.DocEntry: boolean} = {}
  local joined = true
  while joined do
    joined = false
    for _, reader in ipairs(entries) do
      -- A member named `_x` is hidden from callers, so what its
      -- signature names is not reached through it.
      local hidden = reader.source_symbol:find("[.:]_[^.:]*$") ~= nil
        or reader.source_symbol:sub(1, 1) == "_"
      if reader.exported and not hidden and not searched[reader] and reader.signature ~= "" then
        searched[reader] = true
        local words = " " .. reader.signature .. " "
        for _, entry in ipairs(entries) do
          local name = entry.source_symbol
          if not entry.exported and name:find(".", 1, true) == nil
             and (entry.kind == "record" or entry.kind == "enum"
                  or entry.kind == "interface" or entry.kind == "type")
             and entry.signature:sub(1, 6) == "local "
             and words:find("[^.%w_]" .. name .. "[^%w_]") ~= nil then
            for _, member in ipairs(entries) do
              if under(member, name) then
                member.exported = true
              end
            end
            joined = true
          end
        end
      end
    end
  end
end

--- Gives every declaration its stable address within the value returned by
--- the module. The record name is a local implementation detail: both
--- [`Fs.read`] and a renamed `Public.read` are the canonical member `read`.
--- Declarations outside that returned surface stay indexed under their source
--- spelling and are explicitly private.
local function canonicalize_docs(entries: {analyzer.DocEntry}, parsed: ast.Parsed,
                                 export: string, returned: ast.Node | nil)
  local dot = export .. "."
  local colon = export .. ":"
  local by_source: {string: {analyzer.DocEntry}} = {}
  for _, entry in ipairs(entries) do
    local source = entry.source_symbol
    by_source[source] = by_source[source] or {}
    by_source[source][#by_source[source] + 1] = entry
    if export ~= "" and source == export then
      entry.exported = true
    elseif export ~= "" and source:sub(1, #dot) == dot then
      -- A method on a nested record (`Thing.Box:grow`) is the member
      -- `Box.grow`, as a record field and a use of it are spelled: the
      -- `:` says how it is called, not where it lives, just as
      -- `Thing:write` is the member `write`. Only a method's `:` is
      -- that separator: an enum value's row (`Thing.Mode.a:b`) spells
      -- the value itself, which may hold one.
      local member = source:sub(#dot + 1)
      if entry.kind == "method" then
        member = (member:gsub(":", "."))
      end
      entry.symbol = member
      entry.exported = true
    elseif export ~= "" and source:sub(1, #colon) == colon then
      entry.symbol = source:sub(#colon + 1)
      entry.exported = true
    end
  end

  -- A deliberately small value model for the module's top-level execution.
  -- A binding holds the source identity of the declaration value currently in
  -- it, or "" when an expression is not one of the supported direct values.
  -- Assigning that binding into an export member copies the identity at that
  -- point; later reassignment of the local cannot retroactively change it.
  local values: {string: string} = {}
  local members: {string: string} = {}
  for _, stmt in ipairs(parsed.node) do
    if stmt.kind == "local_function" and stmt.name ~= nil and stmt.name.tk ~= nil then
      values[stmt.name.tk] = stmt.name.tk
    elseif stmt.kind == "local_declaration" and stmt.vars ~= nil then
      for index, lhs in ipairs(stmt.vars) do
        local rhs = stmt.exps ~= nil and stmt.exps[index] or nil
        if lhs.tk ~= nil then
          values[lhs.tk] = rhs ~= nil and rhs.kind == "variable"
            and rhs.tk ~= nil and (values[rhs.tk] or "") or ""
        end
      end
    elseif export ~= "" and stmt.kind == "record_function" and stmt.fn_owner ~= nil
           and stmt.fn_owner.tk == export and stmt.name ~= nil
           and stmt.name.tk ~= nil then
      local public_source = export .. "." .. stmt.name.tk
      members[public_source] = public_source
    elseif stmt.kind == "assignment" and stmt.vars ~= nil then
      local rhs_values: {string} = {}
      for index in ipairs(stmt.vars) do
        local rhs = stmt.exps ~= nil and stmt.exps[index] or nil
        rhs_values[index] = rhs ~= nil and rhs.kind == "variable"
          and rhs.tk ~= nil and (values[rhs.tk] or "") or ""
      end
      for index, lhs in ipairs(stmt.vars) do
        if lhs.kind == "op" and lhs.op ~= nil and lhs.op.op == "."
           and lhs.e1 ~= nil and lhs.e1.kind == "variable"
           and export ~= "" and lhs.e1.tk == export
           and lhs.e2 ~= nil and lhs.e2.tk ~= nil
        then
          members[export .. "." .. lhs.e2.tk] = rhs_values[index]
        elseif lhs.kind == "variable" and lhs.tk ~= nil then
          values[lhs.tk] = rhs_values[index]
        end
      end
    end
  end
  if export == "" and returned ~= nil and returned.kind == "literal_table" then
    for _, item in ipairs(returned) do
      if item.kind == "literal_table_item" and item.key_parsed ~= "implicit"
         and item.key ~= nil and item.key.conststr ~= nil and item.value ~= nil
         and item.value.kind == "variable" and item.value.tk ~= nil then
        members[item.key.conststr] = values[item.value.tk] or ""
      end
    end
  end

  local public_sources: {string} = {}
  for public_source in pairs(members) do public_sources[#public_sources + 1] = public_source end
  table.sort(public_sources)
  for _, public_source in ipairs(public_sources) do
    local implementation_name = members[public_source]
    local implementations = implementation_name ~= "" and by_source[implementation_name] or nil
    local implementation = implementations ~= nil and implementations[#implementations] or nil
    local candidates = by_source[public_source] or {}
    local public: analyzer.DocEntry = nil
    -- A declared record field is the stable surface row. When a callable
    -- implementation is known it lends this row its docs and location; every
    -- overwritten callable declaration remains inspectable but private.
    for _, candidate in ipairs(candidates) do
      candidate.exported = false
      candidate.symbol = candidate.source_symbol
      if public == nil and candidate.kind == "field" then public = candidate end
    end
    if public == nil and implementation_name ~= "" then
      for _, candidate in ipairs(candidates) do
        if candidate == implementation then public = candidate end
      end
    end
    local symbol = export ~= "" and public_source:sub(#export + 2) or public_source
    if public == nil and implementation ~= nil then
      public = { symbol = symbol, source_symbol = public_source, exported = true,
        kind = implementation.kind, signature = implementation.signature,
        text = implementation.text, line = implementation.line }
      entries[#entries + 1] = public
    elseif public ~= nil then
      public.symbol = symbol
      public.exported = true
      if implementation ~= nil then
        public.kind = implementation.kind
        public.signature = implementation.signature
        public.text = implementation.text
        public.line = implementation.line
      end
    end
  end
end

--- The source from one top-level statement's own start up to just
--- before the next one's, or to the end of the chunk for the last --
--- an example is always exactly one top-level statement, so this is
--- its whole, as-written text, lines and indentation kept, unlike
--- [`span_text`]'s one-line collapse. A trailing blank or comment-only
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

--- The field that points back up the tree, never followed.
local back_up: {string: boolean} = { if_parent = true }

--- Every name the code under `root` refers to, as `used`: the free
--- variables of its expressions (a name bound by a `local`, a
--- parameter or a loop variable in scope is no reference to a file's
--- own declaration, and neither is a word in a string or a comment)
--- and the first name of each type it writes (`Release` in
--- `x: Release`, `Fs` in [`Fs.Stat`]). Scoping follows the blocks
--- [`references_of`] does; a type's name is not scoped, since a local
--- rarely shadows a type.
local function uses_of(root: ast.Node, used: {string: boolean})
  local scopes: {{string: boolean}} = { {} }
  local function bound(name: string): boolean
    for at = #scopes, 1, -1 do
      if scopes[at][name] then return true end
    end
    return false
  end
  local function bind(name: string | nil)
    if name ~= nil then scopes[#scopes][name] = true end
  end
  local walk: function(ast.Node)
  local function walk_all(list: ast.Node | nil)
    if list ~= nil then walk(list) end
  end
  walk = function(n: ast.Node)
    local kind = n.kind
    if kind == "variable" then
      if n.tk ~= nil and not bound(n.tk) then used[n.tk] = true end
    elseif kind == "local_declaration" then
      walk_all(n.exps)
      for _, var in ipairs(n.vars or {}) do bind(var.tk) end
    elseif kind == "local_type" then
      bind(n.var ~= nil and n.var.tk or nil)
    elseif kind == "local_function" or kind == "record_function"
        or kind == "global_function" or kind == "function" then
      if kind == "local_function" and n.name ~= nil then bind(n.name.tk) end
      scopes[#scopes + 1] = {}
      for _, parameter in ipairs(n.args or {}) do bind(parameter.tk) end
      walk_all(n.body)
      scopes[#scopes] = nil
    elseif kind == "fornum" or kind == "forin" then
      walk_all(n.from)
      walk_all(n.to)
      walk_all(n.step)
      walk_all(n.exps)
      scopes[#scopes + 1] = {}
      bind(n.var ~= nil and n.var.tk or nil)
      for _, var in ipairs(n.vars or {}) do bind(var.tk) end
      walk_all(n.body)
      scopes[#scopes] = nil
    elseif kind == "repeat" then
      -- Lua keeps the body's locals in scope through `until`.
      scopes[#scopes + 1] = {}
      for _, stmt in ipairs(n.body or {}) do walk(stmt) end
      walk_all(n.exp)
      scopes[#scopes] = nil
    elseif kind == "statements" then
      scopes[#scopes + 1] = {}
      for _, stmt in ipairs(n) do walk(stmt) end
      scopes[#scopes] = nil
    else
      for _, child in ipairs(ast.children(n, back_up)) do walk(child) end
    end
  end
  walk(root)
  -- Types hang off nodes as tables of their own (a `TypeNode`); any
  -- table below `root` that is a nominal type names its first part.
  local seen: {any: boolean} = {}
  local function types(value: any)
    if not (value is {any: any}) or seen[value] then return end
    seen[value] = true
    local names = value.names
    if value.typename == "nominal" and names is {string} and names[1] ~= nil then
      used[names[1]] = true
    end
    for key, child in pairs(value) do
      if key ~= "if_parent" then types(child) end
    end
  end
  types(root)
end

--- A file-local declaration an example may use: a `local function`,
--- `local record`, `local type` or `local NAME <const> = ...` that is
--- not a `require`, whole, with the comment lines directly above it.
--- `names` are what it binds; `lines` is its length in lines.
local record Helper
  names: {string}
  code: string
  lines: integer
  node: ast.Node
end

--- The longest helper an example carries above its function, in lines,
--- and the most all its helpers together carry. A longer one is not
--- carried: the example then does not compile as shown, and
--- [`build.example_checks`] asks its author to inline it.
local MAX_HELPER_LINES <const> = 15
local MAX_HELPER_TOTAL <const> = 30

--- What an example file's top level holds outside its examples, as
--- text: each `local Name = require("...")` with the name it binds,
--- each call statement (`Test.needs{...}`) and each helper, in file
--- order. Their text is what an example needs above its function to be
--- copied whole.
local record Preamble
  requires: {{string}}
  calls: {string}
  call_nodes: {ast.Node}
  helpers: {Helper}
end

--- `code`, a statement's text cut at the next statement's start, less
--- what belongs to that next statement: the `local` its position skips
--- and the comment lines above it.
local function own_text(code: string): string
  local kept: {string} = {}
  for line in (code:gsub("%s*local%s*$", "") .. "\n"):gmatch("(.-)\n") do
    kept[#kept + 1] = line
  end
  while #kept > 0 and (kept[#kept]:match("^%s*$") ~= nil
      or kept[#kept]:match("^%s*%-%-") ~= nil) do
    kept[#kept] = nil
  end
  return table.concat(kept, "\n")
end

--- The node a statement's text begins at: a call node sits at its
--- arguments, so this is the leftmost name of what it calls.
local function leftmost(stmt: ast.Node): ast.Node
  local start = stmt
  while start.kind == "op" and start.e1 ~= nil do
    start = start.e1
  end
  return start
end

local function preamble_of(lines: {string}, nodes: {ast.Node}): Preamble
  local out: Preamble = { requires = {}, calls = {}, call_nodes = {}, helpers = {} }
  for index, stmt in ipairs(nodes) do
    local after = nodes[index + 1]
    local next_start = after ~= nil and leftmost(after) or nil
    local until_y = next_start ~= nil and next_start.y or (#lines + 1)
    local until_x = next_start ~= nil and next_start.x or 1
    if stmt.kind == "local_declaration" then
      local code = block_text(lines, stmt.y, stmt.x, until_y, until_x)
      -- The statement's position is its first name, past `local`, and
      -- a following `local` statement's, so the `local` that begins the
      -- next one ends this text.
      code = own_text(code)
      local name = code:match("^([%w_]+)%s*=%s*require%s*%(")
      if name ~= nil then
        code = "local " .. code
      else
        name = code:match("^local%s+([%w_]+)%s*=%s*require%s*%(")
      end
      if name ~= nil then
        out.requires[#out.requires + 1] = { name, code }
      end
    end
    if stmt.kind == "local_function" or stmt.kind == "local_type"
       or stmt.kind == "local_declaration" then
      local names: {string} = {}
      if stmt.kind == "local_function" and stmt.name ~= nil and stmt.name.tk ~= nil then
        names[1] = stmt.name.tk
      elseif stmt.kind == "local_type" and stmt.var ~= nil and stmt.var.tk ~= nil then
        names[1] = stmt.var.tk
      elseif stmt.kind == "local_declaration" then
        for _, var in ipairs(stmt.vars or {}) do
          if var.tk ~= nil then names[#names + 1] = var.tk end
        end
      end
      local first = stmt.y
      -- Only `---` doc lines go with it: a `--` note is the author's.
      while first > 1 and lines[first - 1]:match("^%-%-%-") ~= nil do
        first = first - 1
      end
      local code = own_text(block_text(lines, first, 1, until_y, until_x))
      local is_require = code:match("^local%s+[%w_]+%s*=%s*require%s*%(") ~= nil
        or code:match("^local%s+type%s+[%w_]+%s*=%s*require%s*%(") ~= nil
      local plain = #names > 0
      for _, name in ipairs(names) do
        if name == "Example" then plain = false end
      end
      if plain and not is_require then
        local _, breaks = code:gsub("\n", "\n")
        out.helpers[#out.helpers + 1] = { names = names, code = code, lines = breaks + 1, node = stmt }
      end
    elseif stmt.kind == "op" and stmt.op ~= nil and stmt.op.op == "@funcall" then
      local start = leftmost(stmt)
      local code = block_text(lines, start.y, start.x, until_y, until_x)
      out.calls[#out.calls + 1] = own_text(code)
      out.call_nodes[#out.call_nodes + 1] = stmt
    end
  end
  return out
end

--- The text an example's own `function` is shown below: the top-level
--- `require` lines its body (or a top-level call carried with it)
--- names, the short file-local helpers ([`Helper`]) its body names, and
--- those they name, then those calls. An example is a function copied out of its
--- file, and without these lines it does not run. The file's top-level
--- calls (a `Test.needs{...}` a test module makes once, at its top) are
--- carried by the file's first example, since they are not inside any
--- example of their own.
local function preamble_text(pre: Preamble, body_node: ast.Node, first: boolean): string
  local calls: {string} = {}
  if first then
    calls = pre.calls
  end
  local used: {string: boolean} = {}
  uses_of(body_node, used)
  if first then
    for _, node in ipairs(pre.call_nodes) do uses_of(node, used) end
  end
  -- Helpers the body names, and those they name in turn, until no
  -- more is asked for. One too long to carry is left out, and so is
  -- what only it names.
  local carried: {boolean} = {}
  local refused: {boolean} = {}
  local total = 0
  local changed = true
  while changed do
    changed = false
    for at, helper in ipairs(pre.helpers) do
      if not carried[at] and not refused[at] then
        for _, name in ipairs(helper.names) do
          if not carried[at] and not refused[at] and used[name] then
            if helper.lines <= MAX_HELPER_LINES and total + helper.lines <= MAX_HELPER_TOTAL then
              carried[at] = true
              total = total + helper.lines
              uses_of(helper.node, used)
              changed = true
            else
              refused[at] = true
            end
          end
        end
      end
    end
  end
  local out: {string} = {}
  for _, required in ipairs(pre.requires) do
    if used[required[1]] then
      out[#out + 1] = required[2]
    end
  end
  local helpers: {string} = {}
  for at, helper in ipairs(pre.helpers) do
    if carried[at] then helpers[#helpers + 1] = helper.code end
  end
  if #helpers > 0 then
    if #out > 0 then out[#out + 1] = "" end
    out[#out + 1] = table.concat(helpers, "\n\n")
  end
  if #out > 0 and #calls > 0 then
    out[#out + 1] = ""
  end
  for _, call in ipairs(calls) do
    out[#out + 1] = call
  end
  if #out == 0 then
    return ""
  end
  return table.concat(out, "\n") .. "\n\n"
end

--- Every worked example a chunk declares at its top level: a
--- `function Example.<name>()`. The shape of the declaration is the
--- only marker, as for the functions [`docs_of`] finds; `name` is a free
--- label. Its doc comment is read as [`docs_of`] reads one: what the
--- example is for in the comment, how in the code below it. Which
--- symbol it demonstrates is not decided here, nor when
--- [`build.writer`]'s `insert_examples` ships it against its module
--- alone: [`build.docs`] answers that at read time, by matching this text
--- and source against a symbol's name.
local function examples_of(lines: {string}, parsed: ast.Parsed): {analyzer.ExampleEntry}
  local out: {analyzer.ExampleEntry} = {}
  local nodes = parsed.node
  local pre = preamble_of(lines, nodes)
  for index, stmt in ipairs(nodes) do
    if is_example_function(stmt) then
      local name = stmt.name
      local tk = name ~= nil and name.tk or nil
      if tk ~= nil then
        local after = nodes[index + 1]
        local until_y = after ~= nil and after.y or (#lines + 1)
        local until_x = after ~= nil and after.x or 1
        local body = own_text(block_text(lines, stmt.y, stmt.x, until_y, until_x))
        out[#out + 1] = { name = tk,
          text = doc_before(lines, stmt.comments, stmt.y),
          source = preamble_text(pre, stmt, #out == 0) .. body,
          line = stmt.y }
      end
    end
  end
  return out
end

--- Direct `local name = require("module")` bindings, keyed by the local
--- declaration node. Scope and lifetime are handled by [`references_of`];
--- this pattern only recognizes the one import form whose identity is sure.
local function aliases_of(built: compiler, parsed: ast.Parsed): {ast.Node: string}, string
  local pattern, trouble = ast.compile_pattern(built, "local $ALIAS = require($M)")
  if pattern == nil then
    return {}, trouble
  end
  local out: {ast.Node: string} = {}
  for _, hit in ipairs(ast.find_all(parsed.node, pattern)) do
    local alias = hit.caps["_ALIAS"]
    local named = hit.caps["_M"]
    if alias ~= nil and alias.tk ~= nil and named ~= nil
       and named.kind == "string" and named.conststr ~= nil then
      out[hit.node] = named.conststr
    end
  end
  return out, ""
end

local type Scopes = {{string: string}}

local function binding(scopes: Scopes, name: string): string | nil
  for index = #scopes, 1, -1 do
    local value = scopes[index][name]
    if value ~= nil then
      return value ~= "" and value or nil
    end
  end
  return nil
end

--- Whether any scope binds `name`, to an import or to anything else.
local function bound(scopes: Scopes, name: string): boolean
  for index = #scopes, 1, -1 do
    if scopes[index][name] ~= nil then
      return true
    end
  end
  return false
end

local function bind(scopes: Scopes, name: string, value: string)
  scopes[#scopes][name] = value
end

--- Assignment changes the nearest lexical binding. An import binding never
--- becomes definite again through ordinary assignment: propagation through
--- arbitrary values would require checker identities, so uncertainty is
--- represented by omitting later edges.
local function invalidate(scopes: Scopes, name: string)
  for index = #scopes, 1, -1 do
    if scopes[index][name] ~= nil then
      scopes[index][name] = ""
      return
    end
  end
end

--- The module `call` names when it is `require("<module>")`, a call
--- of `require` on one string literal; nil for any other expression.
local function required_name(call: ast.Node): string | nil
  if call.kind ~= "op" or call.op == nil or call.op.op ~= "@funcall" then
    return nil
  end
  local callee, args = call.e1, call.e2
  if callee == nil or callee.kind ~= "variable" or callee.tk ~= "require"
     or args == nil or #args ~= 1 or args[1].kind ~= "string" then
    return nil
  end
  return args[1].conststr
end

--- Every `alias.member` whose `alias` still resolves to a lexical direct
--- require binding, and every `require("module").member` while `require`
--- is not shadowed. Parameters, locals and loop variables shadow
--- bindings; reassignment in any possibly-executed branch invalidates
--- the outer alias.
--- This is deliberately bounded: indirect aliases and unknown receiver types
--- produce no edge rather than one guessed from spelling.
local function references_of(built: compiler, parsed: ast.Parsed): {analyzer.Reference}, string
  local aliases, trouble = aliases_of(built, parsed)
  if trouble ~= "" then
    return {}, trouble
  end
  local seen: {string: boolean} = {}
  local out: {analyzer.Reference} = {}
  local scopes: Scopes = { {} }
  local process_block: function(ast.Node)
  local process_function: function(ast.Node)
  local walk_expression: function(ast.Node)

  walk_expression = function(n: ast.Node)
    if n.kind == "function" then
      process_function(n)
      return
    end
    if n.kind == "op" and n.op ~= nil and n.op.op == "." and n.e1 ~= nil
       and n.e2 ~= nil and n.e2.tk ~= nil then
      -- `alias.member`, or a member read straight off the module a
      -- literal `require` names: `require("build.test").run`.
      local module: string | nil = nil
      if n.e1.kind == "variable" and n.e1.tk ~= nil then
        module = binding(scopes, n.e1.tk)
      elseif not bound(scopes, "require") then
        module = required_name(n.e1)
      end
      if module ~= nil then
        local id = module .. "\n" .. n.e2.tk .. "\n" .. n.e1.y
        if not seen[id] then
          seen[id] = true
          out[#out + 1] = { module = module, member = n.e2.tk, line = n.e1.y }
        end
      end
    end
    for _, child in ipairs(ast.children(n, back_up)) do
      walk_expression(child)
    end
  end

  process_function = function(fn: ast.Node)
    scopes[#scopes + 1] = {}
    if fn.args ~= nil then
      for _, parameter in ipairs(fn.args) do
        if parameter.tk ~= nil then
          bind(scopes, parameter.tk, "")
        end
      end
    end
    if fn.body ~= nil then
      process_block(fn.body)
    end
    scopes[#scopes] = nil
  end

  process_block = function(block: ast.Node)
    for _, stmt in ipairs(block) do
      if stmt.kind == "local_declaration" then
        if stmt.exps ~= nil then
          walk_expression(stmt.exps)
        end
        if stmt.vars ~= nil then
          for _, var in ipairs(stmt.vars) do
            if var.tk ~= nil then
              bind(scopes, var.tk, aliases[stmt] or "")
            end
          end
        end
      elseif stmt.kind == "local_function" then
        if stmt.name ~= nil and stmt.name.tk ~= nil then
          bind(scopes, stmt.name.tk, "")
        end
        process_function(stmt)
      elseif stmt.kind == "record_function" or stmt.kind == "global_function" then
        process_function(stmt)
      elseif stmt.kind == "assignment" then
        if stmt.exps ~= nil then
          walk_expression(stmt.exps)
        end
        if stmt.vars ~= nil then
          for _, var in ipairs(stmt.vars) do
            if var.kind == "variable" and var.tk ~= nil then
              invalidate(scopes, var.tk)
            end
          end
        end
      elseif stmt.kind == "if" and stmt.if_blocks ~= nil then
        for _, branch in ipairs(stmt.if_blocks) do
          if branch.exp ~= nil then walk_expression(branch.exp) end
          scopes[#scopes + 1] = {}
          if branch.body ~= nil then process_block(branch.body) end
          scopes[#scopes] = nil
        end
      elseif stmt.kind == "fornum" or stmt.kind == "forin" then
        if stmt.from ~= nil then walk_expression(stmt.from) end
        if stmt.to ~= nil then walk_expression(stmt.to) end
        if stmt.step ~= nil then walk_expression(stmt.step) end
        if stmt.exps ~= nil then walk_expression(stmt.exps) end
        scopes[#scopes + 1] = {}
        if stmt.var ~= nil and stmt.var.tk ~= nil then bind(scopes, stmt.var.tk, "") end
        if stmt.vars ~= nil then
          for _, var in ipairs(stmt.vars) do
            if var.tk ~= nil then bind(scopes, var.tk, "") end
          end
        end
        if stmt.body ~= nil then process_block(stmt.body) end
        scopes[#scopes] = nil
      elseif stmt.kind == "repeat" then
        -- Lua keeps the repeat body's locals in scope through `until`.
        scopes[#scopes + 1] = {}
        if stmt.body ~= nil then process_block(stmt.body) end
        if stmt.exp ~= nil then walk_expression(stmt.exp) end
        scopes[#scopes] = nil
      elseif stmt.kind == "while" or stmt.kind == "do" then
        if stmt.exp ~= nil then walk_expression(stmt.exp) end
        scopes[#scopes + 1] = {}
        if stmt.body ~= nil then process_block(stmt.body) end
        scopes[#scopes] = nil
      elseif stmt.kind == "return" or stmt.kind == "op" then
        walk_expression(stmt)
      end
    end
  end
  process_block(parsed.node)
  table.sort(out, function(p: analyzer.Reference, q: analyzer.Reference): boolean
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

--- What each field of a `needs` declaration takes: a list of string
--- literals ("list") or `true` or `false` ("flag"), as [`cosmic.test`]
--- holds a call's argument to it as it runs.
local input_fields: {string:string} = Test.fields

--- The fields `input_fields` names, sorted, as a message lists them.
local input_field_order: {string} = {}
for name in pairs(input_fields) do input_field_order[#input_field_order + 1] = name end
table.sort(input_field_order)

--- What a `host` path that names a directory is refused with: the rule.
local HOST_FILES <const> = "host names files, or /proc: declare the files the tests read"

--- Why `path` is no path of `field` (`reads` or `host`), or "" when it
--- is one. A `reads` path is relative to the tree. A `host` path is
--- absolute, or starts with `$NAME` for a path beneath the one the
--- variable NAME holds ([`build.test_inputs`]' `variable_of`). Neither
--- climbs with "..", nor is spelled with "." or an empty name, which a
--- match by prefix would read as another path. A `host` path names a
--- file, or /proc (R3): one written as a directory, with a "/" after
--- it, or as a variable's whole path is refused here, and one that is
--- a directory on the host fails its tests as they start
--- ([`build.test_inputs`]' `resolve`).
local function input_path_trouble(field: string, path: string): string
  if path == "" then return "an empty path" end
  local quoted = "\"" .. path .. "\""
  local absolute = path:sub(1, 1) == "/"
  if field == "reads" and path:sub(1, 1) == "$" then
    return quoted .. " starts with a variable; a path a variable names goes in host"
  elseif field == "host" and path:sub(1, 1) == "$" then
    local name, rest = path:match("^%$([%a_][%w_]*)(.*)$")
    if name == nil or (rest ~= "" and rest:sub(1, 1) ~= "/") then
      return quoted .. " names no variable: write $NAME or $NAME/path, NAME of letters, " ..
        "digits and _, not starting with a digit"
    end
    -- The variable's whole path, a directory by intent.
    if rest == "" or rest == "/" then
      return quoted .. " names all " .. name .. " holds, a directory; " .. HOST_FILES
    end
    path, absolute = rest, true
  end
  if field == "host" and path:sub(-1) == "/" and path:sub(1, 6) ~= "/proc/" then
    return quoted .. " names a directory; " .. HOST_FILES
  end
  if path:find("/$", 1, true) ~= nil then
    if field == "reads" then
      return quoted .. " names a variable; a path of the tree is written out, and one a " ..
        "variable names goes in host"
    end
    return quoted .. " names a variable past its first name; only a host path's first " ..
      "name may be one"
  end
  if field == "reads" and absolute then
    return quoted .. " is absolute; a path of the tree is relative to its root " ..
      "(one outside it goes in host)"
  elseif field == "host" and not absolute then
    return quoted .. " is relative; host names absolute paths, or $NAME/path " ..
      "(one of the tree goes in reads)"
  end
  local inner = path:gsub("^/", ""):gsub("/$", "")
  for name in (inner .. "/"):gmatch("([^/]*)/") do
    if name == "" or name == "." or name == ".." then
      return quoted .. " names \"" .. name .. "\"; spell the path plainly"
    end
  end
  return ""
end

--- Whether `node` names [`cosmic.test`]'s `needs` through one of `names`,
--- the locals a chunk binds `require("cosmic.test")` to: [`Test.needs`].
local function names_needs(node: ast.Node, names: {string:boolean}): boolean
  local index = node ~= nil and node.kind == "op" and node.op or nil
  local base: ast.Node = node ~= nil and node.e1 or nil
  local member: ast.Node = node ~= nil and node.e2 or nil
  return index ~= nil and index.op == "." and base ~= nil and base.kind == "variable" and
    names[base.tk] == true and member ~= nil and member.tk == "needs"
end

--- Whether `node` is `require("cosmic.test")`.
local function requires_test(node: ast.Node): boolean
  local call = node ~= nil and node.kind == "op" and node.op or nil
  local callee: ast.Node = node ~= nil and node.e1 or nil
  local args: ast.Node = node ~= nil and node.e2 or nil
  local first = args ~= nil and args[1] or nil
  return call ~= nil and call.op == "@funcall" and callee ~= nil and
    callee.kind == "variable" and callee.tk == "require" and first ~= nil and
    first.kind == "string" and first.conststr == "cosmic.test"
end

--- The chunk's `Test.needs { ... }` (see [`cosmic.test`]), read as data,
--- never run: nil and "" when there is none, and nil and why, naming
--- the line, for one the build cannot read so. The call is a statement
--- at the chunk's top level, once, on a name a top-level `local` binds
--- `require("cosmic.test")` to, with one table literal: `needs` reached
--- any other way -- inside a function, under another name, handed a
--- value computed -- is refused, as is the older `local _inputs = { ... }`
--- form. Each field is held to its shape here.
local function inputs_of(parsed: ast.Parsed): analyzer.Declared | nil, string
  local function at(node: ast.Node): string
    return (node.f or "") .. ":" .. tostring(node.y) .. ": test.needs: "
  end
  local names: {string:boolean} = {}
  local found: ast.Node = nil
  local callees: {ast.Node:boolean} = {}
  local jump: ast.Node = nil
  for _, stmt in ipairs(parsed.node) do
    if stmt.kind == "local_declaration" and stmt.vars ~= nil then
      for i, var in ipairs(stmt.vars) do
        local exps: ast.Node = stmt.exps
        -- TODO: drop this refusal of the form `needs` replaced once no
        -- branch still declares with it -- after the next release, say.
        if var.tk == "_inputs" then
          return nil, (stmt.f or "") .. ":" .. tostring(stmt.y) .. ": _inputs: a module " ..
            "declares what its tests read with cosmic.test's needs now: " ..
            "local Test = require(\"cosmic.test\") and Test.needs { ... }"
        end
        if exps ~= nil and requires_test(exps[i]) then names[var.tk] = true end
      end
    elseif stmt.kind == "op" and stmt.op ~= nil and stmt.op.op == "@funcall" and
        names_needs(stmt.e1, names) then
      if found ~= nil then
        return nil, at(stmt) .. "a module declares its inputs once; line " ..
          tostring(found.y) .. " did already"
      end
      found = stmt
      callees[stmt.e1] = true
    elseif (stmt.kind == "goto" or stmt.kind == "label") and jump == nil then
      jump = stmt
    end
  end
  -- A jump could pass the call by, and the module would not make the
  -- declaration the build read.
  if found ~= nil and jump ~= nil then
    return nil, (jump.f or "") .. ":" .. tostring(jump.y) .. ": test.needs: a module " ..
      "that declares its inputs jumps nowhere at its top level, so the call is always made"
  end
  -- `needs` reached any other way than that one statement.
  local elsewhere: ast.Node = nil
  ast.walk(parsed.node, function(node: ast.Node)
    if elsewhere == nil and names_needs(node, names) and not callees[node] then
      elsewhere = node
    end
  end)
  if elsewhere ~= nil then
    return nil, at(elsewhere) .. "call it as a statement at the module's top level, " ..
      "on the name the module binds require(\"cosmic.test\") to, and nowhere else"
  end
  if found == nil then return nil, "" end
  local args: ast.Node = found.e2
  local value = args ~= nil and args[1] or nil
  if args == nil or #args ~= 1 or value.kind ~= "literal_table" then
    return nil, at(found) .. "hand it one table written out as a literal: " ..
      "Test.needs { reads = { ... } }"
  end
  local out: analyzer.Declared = {
    line = found.y, reads = {}, host = {}, env = {}, network = {},
    tool = false, nests = false, store = false, system = false, caches = {},
  }
  local seen: {string:boolean} = {}
  for _, item in ipairs(value) do
    local key = item.key
    local field = item.key_parsed == "short" and key ~= nil and key.conststr or nil
    local where = at(item)
    local takes = field ~= nil and input_fields[field] or nil
    if item.key_parsed ~= "short" and key ~= nil and key.kind == "string" then
      return nil, where .. "write the field as a name, " .. tostring(key.conststr) ..
        " = ..., not in brackets"
    end
    if takes == nil then
      return nil, where .. (field ~= nil and ("no field " .. field) or "an entry with no name") ..
        "; it has " .. table.concat(input_field_order, ", ")
    end
    if seen[field] then return nil, where .. field .. " is declared twice" end
    seen[field] = true
    local given = item.value
    if field == "network" and given ~= nil and given.kind == "boolean" and given.tk == "true" then
      -- Any host: what [`cosmic.test`] refuses, as its rule says.
      return nil, where .. Test.any_host_refusal
    end
    if given ~= nil and given.kind == "boolean" and takes ~= "list" then
      local on = given.tk == "true"
      if field == "tool" then
        out.tool = on
      elseif field == "nests" then
        out.nests = on
      elseif field == "system" then
        out.system = on
      else
        out.store = on
      end
    elseif given ~= nil and given.kind == "literal_table" and takes ~= "flag" then
      local list: {string} = {}
      for _, entry in ipairs(given) do
        local text = entry.value
        if entry.key_parsed ~= "implicit" or text == nil or text.kind ~= "string" or
            text.conststr == nil then
          return nil, at(entry) .. field ..
            " lists string literals only"
        end
        -- The literal as written, which is what `conststr` holds: an
        -- escape the running module decodes would read otherwise here.
        local written = text.tk or ""
        if written:find("\\", 1, true) ~= nil or written:sub(1, 1) == "[" then
          return nil, at(entry) .. field .. ": " .. written ..
            ": write declared paths plainly, without escapes or long brackets"
        end
        local path_trouble = (field == "reads" or field == "host") and
          input_path_trouble(field, text.conststr) or ""
        if field == "env" and text.conststr == "" then path_trouble = "an empty name" end
        if field == "network" then
          -- The rule's own words, which name the field and the host.
          local refused = Test.network_trouble(text.conststr)
          if refused ~= "" then return nil, at(entry) .. refused end
        end
        if field == "caches" and cache_names.names[text.conststr] == nil then
          local known: {string} = {}
          for name in pairs(cache_names.names) do known[#known + 1] = name end
          table.sort(known)
          path_trouble = "no cache " .. text.conststr .. "; the caches are " ..
            table.concat(known, ", ")
        end
        if path_trouble ~= "" then
          return nil, at(entry) .. field ..
            ": " .. path_trouble
        end
        list[#list + 1] = text.conststr
      end
      if field == "reads" then
        out.reads = list
      elseif field == "host" then
        out.host = list
      elseif field == "env" then
        out.env = list
      elseif field == "caches" then
        out.caches = list
      else
        out.network = list
      end
    else
      local wanted = takes == "list" and "a list of string literals" or "true or false"
      return nil, where .. field .. " takes " .. wanted .. ", written out"
    end
  end
  return out, ""
end

--- The facts of `analyze`, read off a chunk that was parsed already, so a
--- caller that needs the parse for another question too pays for it
--- once. `built` is needed only to compile the patterns the catalog
--- and the references match against; a pattern-compile failure is
--- reported as an ordinary failure rather than dropping them silently.
--- `source` is the text `parsed` came from, for the signatures the docs
--- quote.
function analyzer.analysis_of(built: compiler, parsed: ast.Parsed,
                                source: string): analyzer.Analysis | nil, string
  local names: {string} = {}
  local has_return = false
  local export = ""
  local returned: ast.Node = nil
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
      returned = exps ~= nil and exps[1] or nil
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
  local declared, inputs_trouble = inputs_of(parsed)
  if inputs_trouble ~= "" then
    return nil, inputs_trouble
  end
  local lines = lines_of(source)
  local doc_entries = docs_of(lines, parsed)
  canonicalize_docs(doc_entries, parsed, export, returned)
  local surface = surface_of(parsed, export, doc_entries)
  mark_reachable_types(doc_entries, surface, export)
  -- The record the value is typed as, when the returned name is not
  -- that record, is the module's row's signature, as its declaration
  -- reads: a lookup finds the module's members under it
  -- ([`alias_members.value_record`]), since their rows keep the
  -- record's name.
  -- TODO: record it for a module with no doc comment of its own too,
  -- which has no row to hold it, so no lookup finds its members by the
  -- module's name: that wants a row of kind `module` with no text, once
  -- `cosmic docs`' index and build.docs_checks' rendered-docs checks take
  -- one.
  if surface ~= export then
    for _, entry in ipairs(doc_entries) do
      if entry.kind == "module" then
        entry.signature = "local " .. export .. ": " .. surface
      end
    end
  end
  return {
    tests = names, inputs = declared,
    has_top_level_return = has_return, export = export,
    catalog = catalog, docs = doc_entries,
    examples = examples_of(lines, parsed), references = references,
  }, ""
end

--- What one parse of `source` tells the importer ([`Analysis`]): the
--- name of every top-level `local function test_*`, in order; whether
--- the chunk has a top-level `return`, and the name it returns; the
--- catalog, docs, examples and references. Tests and return are read
--- from the chunk's own statement array, never by a recursive walk, so
--- an indented function or a source sample held in a string literal
--- is not mistaken for a statement of the chunk. Lua requires a
--- `return` to end its block, so a chunk that type-checks has one only
--- as its final statement.
--- @param built compiler The loaded compiler capsule ([`build.teal.load()`])
--- @param source string
--- @param name string Filename for parse diagnostics
--- @return Analysis | nil The analysis, or nil when `source` fails to lex or parse
--- @return string Error message when nil
function analyzer.analyze(built: compiler, source: string,
                            name: string): analyzer.Analysis | nil, string
  local parsed, trouble = ast.parse(built, source, name)
  if parsed == nil then
    return nil, trouble
  end
  return analyzer.analysis_of(built, parsed, source)
end

return analyzer
