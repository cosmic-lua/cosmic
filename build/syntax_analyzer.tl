--- The source analyzer on the new syntax tree: what one parse of a module's source tells the importer about it -- its
--- own test names, whether it returns its own value at the top level and under what name, the failure messages it
--- catalogs, the symbols it documents, its worked examples, the members of other modules it refers to, and the
--- `policy` a test module declares. It answers the rows of an analysis ([`Analyzer.Analysis`]), read off a tree of
--- [`lang.parser`] ([`lang.ast`]) and the names [`lang.scopes`] resolved.
---
--- A declaration's doc comment is on the node ([`Ast.Binding`], [`Ast.Function`], [`Ast.FieldDecl`], [`Ast.Method`],
--- [`Ast.EnumValue`]) as the parser attached it, and the source of a signature or an example is read off the lines by
--- the places of the tokens. What the new grammar changes of the rows, each deliberately:
---
--- - A class is documented as a record, and a method it declares is the `method`
---   row `Class:name`, as `function Class:name()` was: its signature is the head as written, with `self` as its
---   first parameter.
--- - A field or a method named `__x` is a metamethod, as the `metamethod` keyword made it; the signature has no keyword.
--- - A source cannot jump (`goto`), so a policy is never refused for a jump past its call.
local Ast = require("lang.ast")
local Lexer = require("lang.lexer")
local Lexical = require("build.syntax_scopes")
local Node = require("build.syntax_node")
local PolicyRules = require("build.policy_rules")
local Scopes = require("lang.scopes")
local String = require("cosmic.string")
local TodoScan = require("build.todo_scan")

local record Analyzer
  --- One catalog entry: a literal `return nil, ...`/`return false, ...` (or `return refuse(...)`, a module's own
  --- `nil, "module: ..."`) message under a top-level function, with the function it is in. The guidance a match
  --- prints is that function's own documentation, found in `docs` by symbol.
  record CatalogEntry
    symbol: string
    --- The literal text of the returned message, its dynamic parts left out. An entry exists only when at least six
    --- of its characters are letters.
    message: string
    line: integer
  end

  --- One documented symbol: a top-level function, a record, class, enum or type alias and each field, method or value
  --- it declares, a documented top-level value, or the module itself.
  record DocEntry
    --- Canonical exported path (`"read"`, `"Value.text"`), or the declaration spelling for a private entry; `""` for
    --- the module.
    symbol: string
    --- The declaration spelling (`"Fs.read"`) retained for display and source navigation. This is not identity.
    source_symbol: string
    --- Whether `symbol` is reachable through the returned module value.
    exported: boolean
    --- `"module"`, `"function"`, `"method"`, `"record"`, `"interface"`, `"enum"`, `"type"`, `"field"`, `"metamethod"`,
    --- `"value"`.
    kind: string
    --- The declaration as the source wrote it, one line.
    signature: string
    --- The doc comment, leaders stripped, one line per source line.
    text: string
    line: integer
  end

  --- One use of another module's member through a top-level alias: `Fs.read(...)` where
  --- `local Fs = require("cosmic.fs")`.
  record Reference
    module: string
    member: string
    line: integer
  end

  --- A name the chunk's own block binds to a module, once and to nothing else: `Stream` of
  --- `local Stream = require("cosmic.stream")` or of `local type Stream = require("cosmic.stream")`.
  record Bound
    name: string
    module: string
  end

  --- One worked example: a top-level `function Example.<name>()`. `name` is a free label, not a symbol.
  record ExampleEntry
    name: string
    --- The doc comment directly above it, leaders stripped.
    text: string
    --- The whole `function Example.<name>() ... end`, as written, under the file's top-level `require` lines it uses
    --- and, for the file's first example, its top-level calls.
    source: string
    line: integer
  end

  --- A test module's `policy` declaration, read as data, as the [`Test.Needs`] it stands for.
  type Declared = PolicyRules.Declared

  --- What a single parse of a module's source tells the importer.
  record Analysis
    tests: {string}
    --- The chunk's `Test.policy { ... }` declaration, or nil for none.
    inputs: PolicyRules.Declared?
    has_top_level_return: boolean
    --- The name the chunk's top-level `return` hands back, when it is a plain name (`return Fs`): what a reference
    --- through an alias of this module resolves against. `""` otherwise.
    export: string
    catalog: {CatalogEntry}
    docs: {DocEntry}
    examples: {ExampleEntry}
    references: {Reference}
    bound: {Bound}
  end

  --- The facts of `chunk`, the tree of `source` named `name`, whose names `scoped` resolved ([`Node.scope`]): nil and
  --- why where its `policy` declaration is one the build cannot read.
  analysis_of: function(chunk: Ast.Chunk, scoped: Scopes.Scoped, source: string, name: string): Analysis?, string

  --- The facts of the text `source`, a file named `name`; nil and why where it does not parse or its policy is
  --- refused.
  analyze: function(source: string, name: string): Analysis?, string

  --- A chunk's doc entries, as [`Analyzer.analysis_of`] gives them but for the module entry's signature, and no more
  --- of its analysis.
  docs: function(chunk: Ast.Chunk, source: string): {DocEntry}
end

local type Entry = Analyzer.DocEntry

--- The element `at` of `list`, which the caller knows to be there: a token index of the tree names a token, and a list
--- is asked only where its length was.
local function nth<T>(list: {T}, at: integer): T
  local found = list[at]
  assert(found ~= nil, "the list holds an element at " .. tostring(at))
  return found
end

--- Token `at` of `tokens`, which the caller knows to be there ([`nth`]).
local function token_at(tokens: Lexer.Tokens, at: integer): Lexer.Token
  assert(tokens.kind[at] ~= nil, "the tokens hold an element at " .. tostring(at))
  return Lexer.token(tokens, at)
end

--- The first token of `node`.
local function first_token(chunk: Ast.Chunk, node: Ast.Node): Lexer.Token
  return token_at(chunk.tokens, Node.base(node).first)
end

--- The first name of the path of a `function Owner.name()` statement, or "" for any other statement or path.
local function owner_of(stat: Ast.Stat): string
  if (stat.kind == "Function") and #stat.path == 2 then
    return nth(stat.path, 1).text
  end
  return ""
end

--- The last name of the path of a `function Owner.name()` statement, or "" for any other statement or path.
local function member_of(stat: Ast.Stat): string
  if (stat.kind == "Function") and #stat.path == 2 then
    return nth(stat.path, 2).text
  end
  return ""
end

--- The place the statement after `index` of `stats` starts at (line, column), or the end of a source of `count` lines.
local function next_place(chunk: Ast.Chunk, stats: {Ast.Stat}, index: integer, count: integer): integer, integer
  local after = stats[index + 1]
  if after == nil then
    return count + 1, 1
  end
  local token = first_token(chunk, after)
  return token.y, token.x
end

--- A `return nil, $MSG`-shaped statement's message expression, reduced to whatever of it is a literal: a plain string
--- leaf reads as its own text, a `..` concatenation reads as both sides joined the same way, and anything else (a
--- call, a variable) contributes nothing. A message built entirely from such a case reduces to `""`, which nothing is
--- cataloged for.
local function static_text(chunk: Ast.Chunk, node: Ast.Node?): string
  if node == nil then
    return ""
  elseif (node.kind == "String") then
    -- The message as the source means it, an escape decoded.
    return node.value
  elseif (node.kind == "Binary") and node.op == ".." then
    return static_text(chunk, node.left) .. static_text(chunk, node.right)
  end
  return ""
end

--- One comment's text with its leader gone: `---`, `--`, and the one space that conventionally follows either.
local function comment_body(c: Lexer.Comment): string
  return c.text:match("^%-%-%-?%s?(.*)$") or c.text
end

--- The comments of `run` that open a `TODO:` or carry one on, found as [`build.todo_scan`] finds TODOs: a TODO is a
--- note to the maintainers, never documentation.
local function todo_comments(run: {Lexer.Comment}): {integer:boolean}
  local texts: mut {string} = {}
  for _, c in ipairs(run) do
    texts[#texts + 1] = c.text
  end
  local skipped: mut {integer:boolean} = {}
  for _, todo in ipairs(TodoScan.scan(table.concat(texts, "\n"))) do
    for line = todo.line, todo.last do
      skipped[line] = true
    end
  end
  return skipped
end

--- The body of each comment in `run` that is documentation: the `---` lines when the run has any, so a `--` note
--- beside them stays out of the doc text, and every line of a run of `--` alone, which documents a script or a
--- module. A `TODO:` comment, with the lines that carry it on, is never documentation, and the blank line it leaves
--- beside another is dropped with it.
local function doc_bodies(run: {Lexer.Comment}): {string}
  local any = false
  for _, c in ipairs(run) do
    if c.text:sub(1, 3) == "---" then
      any = true
    end
  end
  local skipped = todo_comments(run)
  local parts: mut {string} = {}
  local dropped = false
  for index, c in ipairs(run) do
    if skipped[index] == true then
      dropped = true
    elseif c.text:sub(1, 3) == "---" or not any then
      local body = comment_body(c)
      local last = parts[#parts]
      if not (dropped and body == "" and (last == nil or last == "")) then
        parts[#parts + 1] = body
      end
      dropped = false
    end
  end
  return parts
end

--- The text of the doc comment the parser attached to a declaration, one line per comment line, leaders stripped.
local function doc_text(doc: {Lexer.Comment}?): string
  if doc == nil then
    return ""
  end
  return table.concat(doc_bodies(doc), "\n")
end

--- The line of the first token of `node`.
local function line_of(chunk: Ast.Chunk, node: Ast.Node): integer
  return first_token(chunk, node).y
end

--- Whether a statement is a function declaration, whose own doc comment sits directly above it. A run of comments
--- ending right above a record or a type is the module's as well as that declaration's, when it opens the file;
--- above a function it is the function's alone.
local function takes_a_doc_comment(stat: Ast.Stat): boolean
  return (stat.kind == "LocalFunction") or (stat.kind == "Function")
end

--- The module's own documentation: the run of comment lines that opens the file, read off the first token, which
--- carries every comment before it, and the line it starts on. A run that ends right above a function declaration is
--- that function's, not the module's; above a record or a type it is both's.
local function module_doc(chunk: Ast.Chunk): string, integer
  local comments = chunk.tokens.comments[1]
  if comments == nil or #comments == 0 then
    return "", 1
  end
  local last = 1
  while last < #comments and nth(comments, last + 1).y == nth(comments, last).y + 1 do
    last = last + 1
  end
  local first_stat = chunk.body.stats[1]
  if first_stat ~= nil and takes_a_doc_comment(first_stat) and
      nth(comments, last).y == line_of(chunk, first_stat) - 1 then
    return "", 1
  end
  local run: mut {Lexer.Comment} = {}
  for index = 1, last do
    run[#run + 1] = nth(comments, index)
  end
  return table.concat(doc_bodies(run), "\n"), nth(comments, 1).y
end

--- `source` split into its lines, once per analysis: a line ends at `\n`, `\r`, `\r\n` or `\n\r`, as the lexer reads it, so
--- that a token's line numbers a line of the list.
local function lines_of(source: string): {string}
  local lines: mut {string} = {}
  local pos = 1
  while true do
    local at = source:find("[\r\n]", pos)
    if at == nil then
      lines[#lines + 1] = source:sub(pos)
      return lines
    end
    lines[#lines + 1] = source:sub(pos, at - 1)
    local after = source:sub(at + 1, at + 1)
    if (after == "\r" or after == "\n") and after ~= source:sub(at, at) then
      at = at + 1
    end
    pos = at + 1
  end
end

--- One line of `source`, trimmed, or `""` past its end.
local function line_at(lines: {string}, y: integer): string
  local line = lines[y]
  if line == nil then
    return ""
  end
  return String.trim(line)
end

--- The name a path of names spells, `Thing.Box`.
local function dotted(path: {Ast.Name}, count: integer): string
  local parts: mut {string} = {}
  for i = 1, count do
    parts[i] = nth(path, i).text
  end
  return table.concat(parts, ".")
end

--- A declared function's own name: a `local function`'s name alone, or a `function`'s path joined by `.` the way it
--- was declared, e.g. `"Sqlite.run"`.
local function symbol_of(stat: Ast.Stat): string
  if (stat.kind == "LocalFunction") then
    return stat.name.name
  elseif (stat.kind == "Function") then
    return dotted(stat.path, #stat.path)
  end
  return ""
end

--- A function's head, from the token `first` (`local` or `function`) to just before its body, which begins at `body`:
--- `function Fs.read(path: string): string?, string`. It ends at the head's own last token, so a comment that opens the
--- body is not read as part of the head; a comment inside the head is left out too, as it would swallow the words
--- after it once the lines are joined.
local function head_text(chunk: Ast.Chunk, lines: {string}, first: integer, body: Ast.Block): string
  local tokens = chunk.tokens
  local start = Node.base(body).first
  local opener, last = token_at(tokens, first), token_at(tokens, start - 1)
  local head: mut {integer: string} = {}
  for line_no = opener.y, last.yend do
    head[line_no] = lines[line_no] or ""
  end
  for at = first + 1, start - 1 do
    for _, comment in ipairs(tokens.comments[at] or {}) do
      local line = head[comment.y]
      if line ~= nil then
        head[comment.y] = line:sub(1, comment.x - 1) .. string.rep(" ", #comment.text) ..
          line:sub(comment.x + #comment.text)
      end
    end
  end
  local parts: mut {string} = {}
  for line_no = opener.y, last.yend do
    local line = head[line_no] or ""
    local from = 1
    if line_no == opener.y then
      from = opener.x
    end
    local to = #line
    if line_no == last.yend then
      to = last.xend
    end
    parts[#parts + 1] = line:sub(from, to)
  end
  -- A parameter list wrapped after its `(` or before its `)` reads as if written tight.
  local joined = String.trim((table.concat(parts, " "):gsub("%s+", " ")))
  return (joined:gsub("%( ", "("):gsub(" %)", ")"))
end

--- The head of a function declaration `stat`.
local function function_signature(chunk: Ast.Chunk, lines: {string}, stat: Ast.Stat): string
  if (stat.kind == "LocalFunction") then
    return head_text(chunk, lines, Node.base(stat).first, stat.fn.body)
  elseif (stat.kind == "Function") then
    return head_text(chunk, lines, Node.base(stat).first, stat.fn.body)
  end
  return ""
end

--- Whether `node` is a function: a declaration or a literal, whose returns are its own.
local function function_nodes(node: Ast.Node): boolean
  return (node.kind == "LocalFunction") or (node.kind == "Function") or (node.kind == "FunctionLit") or (node.kind == "Method")
end

--- The `return` statements in `body` that are `body`'s own: in its blocks, however deep, but not in a function
--- declared inside it, whose returns are that function's.
local function returns_of(body: Ast.Block): {Ast.Return}
  local out: mut {Ast.Return} = {}
  Node.walk_until(body, function(node: Ast.Node): boolean
    if (node.kind == "Return") then
      out[#out + 1] = node
    end
    return not function_nodes(node)
  end)
  return out
end

--- The message of a `return nil, $MSG` (`which` "nil"), `return false, $MSG` ("false") or `return refuse($MSG)`
--- ("refuse") statement, or nil where `stat` is none.
local function failure_message(stat: Ast.Return, which: string): Ast.Exp?
  local values = stat.values
  if which == "refuse" then
    if #values == 1 then
      local call = assert(values[1], "a list of one has its element")
      if (call.kind == "Call") and #call.args == 1 then
        local callee = call.callee
        if (callee.kind == "Name") and callee.text == "refuse" then
          return call.args[1]
        end
      end
    end
    return nil
  end
  if #values ~= 2 then
    return nil
  end
  local head = assert(values[1], "a list of two has its first")
  if (which == "nil" and (head.kind == "Nil")) or (which == "false" and (head.kind == "Boolean") and not head.value) then
    return values[2]
  end
  return nil
end

--- Every honest-return failure inside the function body `body` that carries literal text: `return nil, ...` (a value)
--- and `return false, ...` (an effect) alike, then `return refuse(...)`. Searches the whole body, nested blocks
--- included, but never crosses into a function declared inside it.
local function catalog_in_body(chunk: Ast.Chunk, body: Ast.Block, symbol: string): {Analyzer.CatalogEntry}
  local out: mut {Analyzer.CatalogEntry} = {}
  local returns = returns_of(body)
  for _, which in ipairs({ "nil", "false", "refuse" }) do
    for _, stat in ipairs(returns) do
      local message = failure_message(stat, which)
      if message ~= nil then
        local text = static_text(chunk, message)
        -- A handful of significant characters or better: enough to anchor an FTS match, so a mostly-interpolated
        -- message is left out rather than shipped as a near-universal false match.
        if #(text:gsub("%A", "")) >= 6 then
          out[#out + 1] = { symbol = symbol, message = text, line = line_of(chunk, stat) }
        end
      end
    end
  end
  return out
end

--- Every catalog entry a chunk's own top-level functions carry, each paired with the literal text of every
--- honest-return failure its own body returns. Top-level only: a function nested inside another statement is reached
--- through that statement's own entry, never here.
local function catalog_of(chunk: Ast.Chunk): {Analyzer.CatalogEntry}
  local out: mut {Analyzer.CatalogEntry} = {}
  local function add(symbol: string, body: Ast.Block)
    for _, entry in ipairs(catalog_in_body(chunk, body, symbol)) do
      out[#out + 1] = entry
    end
  end
  for _, stat in ipairs(chunk.body.stats) do
    if (stat.kind == "LocalFunction") or (stat.kind == "Function") then
      add(symbol_of(stat), stat.fn.body)
    elseif (stat.kind == "Class") then
      for _, member in ipairs(stat.members) do
        if (member.kind == "Method") then
          add(stat.name.name .. ":" .. member.name.name, member.body)
        end
      end
    end
  end
  return out
end

--- A record field's declaration on one line, however many the source spent on it: from the line its type starts on to
--- the end of its type. A comment inside the signature is left out, as it would swallow the words after it once the
--- lines are joined.
local function field_signature(chunk: Ast.Chunk, lines: {string}, member: Ast.Member): string
  local tokens = chunk.tokens
  local base = Node.base(member)
  local start = base.first
  if (member.kind == "FieldDecl") then
    start = Node.base(member.type).first
  end
  local first, last = token_at(tokens, start), token_at(tokens, base.last)
  if last.yend == first.y then
    return line_at(lines, first.y)
  end
  -- Where a comment starts on each line the type spans.
  local comment_at: mut {integer: integer} = {}
  for at = start + 1, base.last do
    for _, comment in ipairs(tokens.comments[at] or {}) do
      if comment_at[comment.y] == nil then
        comment_at[comment.y] = comment.x
      end
    end
  end
  local parts: mut {string} = {}
  for line_no = first.y, last.yend do
    local line = lines[line_no] or ""
    local to = #line
    if line_no == last.yend then
      to = last.xend
    end
    local cut = comment_at[line_no]
    if cut ~= nil and line_no ~= last.yend and cut - 1 < to then
      to = cut - 1
    end
    parts[#parts + 1] = line:sub(1, to)
  end
  return String.trim((table.concat(parts, " "):gsub("%s+", " ")))
end

--- The kind a type declaration is documented as.
local function type_kind(node: Ast.Node): string
  if (node.kind == "Record") or (node.kind == "Class") then
    return "record"
  elseif (node.kind == "Interface") then
    return "interface"
  elseif (node.kind == "Enum") then
    return "enum"
  end
  return "type"
end

-- Declared ahead: [`members_docs`] and `type_docs` call each other.
local type_docs: function(chunk: Ast.Chunk, lines: {string}, symbol: string, decl: Ast.Node, out: {Entry})

--- Adds the entries for the members of one record, interface or class under `symbol`, in the order given: the fields
--- and nested types in declaration order, then the metamethods (fields named `__x`), then the methods.
local function members_docs(chunk: Ast.Chunk, lines: {string}, symbol: string, members: {Ast.Member}, out: mut {Entry})
  for pass = 1, 3 do
    for _, member in ipairs(members) do
      local nested = Node.declared(member)
      local line = line_of(chunk, member)
      if (member.kind == "FieldDecl") then
        local meta = member.name.name:sub(1, 2) == "__"
        if pass == (if meta then 2 else 1 end) then
          local name = symbol .. "." .. member.name.name
          table.insert(out, { symbol = name, source_symbol = name, exported = false,
            kind = if meta then "metamethod" else "field" end, signature = field_signature(chunk, lines, member),
            text = doc_text(member.doc), line = first_token(chunk, member.type).y })
        end
      elseif pass == 1 and nested ~= nil and ((member.kind == "Record") or (member.kind == "Interface") or (member.kind == "Class") or
          (member.kind == "Enum")) then
        local name = symbol .. "." .. nested.name.name
        table.insert(out, { symbol = name, source_symbol = name, exported = false, kind = type_kind(member),
          signature = line_at(lines, line), text = doc_text(nested.name.doc), line = line })
        type_docs(chunk, lines, name, member, out)
      elseif pass == 1 and nested ~= nil then
        local name = symbol .. "." .. nested.name.name
        table.insert(out, { symbol = name, source_symbol = name, exported = false, kind = "field",
          signature = field_signature(chunk, lines, member), text = doc_text(nested.name.doc), line = line })
      elseif (member.kind == "Method") then
        -- TODO: drop the metamethod half of this branch (`__x` is a method of a class), once the tree writes the
        -- `__close` of a metatable as the metamethod field the new checker takes: the tree writes it as a
        -- method today, which the checker refuses (`class_metamethod`, doc/plans/new-checker-types.md).
        --
        -- A method named `__x` is a metamethod, as the field of that name is.
        local meta = member.name.name:sub(1, 2) == "__"
        if pass == (if meta then 2 else 3 end) then
          local name = symbol .. (if meta then "." else ":" end) .. member.name.name
          table.insert(out, { symbol = name, source_symbol = name, exported = false,
            kind = if meta then "metamethod" else "method" end,
            signature = head_text(chunk, lines, Node.base(member).first, member.body), text = doc_text(member.doc),
            line = line })
        end
      end
    end
  end
end

--- Adds the entries for one record, interface, class or enum body under `symbol`: one per member, with a nested type
--- recursing under its own name.
type_docs = function(chunk: Ast.Chunk, lines: {string}, symbol: string, decl: Ast.Node, out: mut {Entry})
  if (decl.kind == "Enum") then
    local line = line_of(chunk, decl)
    for _, value in ipairs(decl.values) do
      local full = symbol .. "." .. value.value
      table.insert(out, { symbol = full, source_symbol = full, exported = false, kind = "value",
        signature = string.format("%q", value.value), text = doc_text(value.doc), line = line })
    end
  elseif (decl.kind == "Record") then
    members_docs(chunk, lines, symbol, decl.members, out)
  elseif (decl.kind == "Interface") then
    members_docs(chunk, lines, symbol, decl.members, out)
  elseif (decl.kind == "Class") then
    members_docs(chunk, lines, symbol, decl.members, out)
  end
end

--- Whether `stat` is a top-level `function Example.<name>()`: [`examples_of`]'s own shape, kept out of [`docs_of`] so a
--- worked example is never also shipped as a trivial doc entry of its own.
local function is_example_function(stat: Ast.Stat): boolean
  return owner_of(stat) == "Example"
end

--- Every documented symbol a chunk declares at its top level, in source order: the module itself when the file opens
--- with a comment of its own, each function, each record, class, interface, enum or alias and the members and values
--- under it, and each `local` whose declaration carries a doc comment. Every function is here, whether or not it is
--- documented; a bare `local x = ...` is not. A worked example ([`examples_of`]) is left out too: it documents
--- another module's symbol, not this one's.
local function docs_of(chunk: Ast.Chunk, lines: {string}): {Entry}
  local out: mut {Entry} = {}
  local opening, opening_line = module_doc(chunk)
  if #opening > 0 then
    out[#out + 1] = { symbol = "", source_symbol = "", exported = true, kind = "module", signature = "",
      text = opening, line = opening_line }
  end
  for index, stat in ipairs(chunk.body.stats) do
    local line = line_of(chunk, stat)
    local declared = Node.declared(stat)
    if ((stat.kind == "LocalFunction") or (stat.kind == "Function")) and not is_example_function(stat) then
      local symbol = symbol_of(stat)
      local doc: {Lexer.Comment}? = nil
      if (stat.kind == "LocalFunction") then
        doc = stat.name.doc
      else
        doc = stat.doc
      end
      table.insert(out, { symbol = symbol, source_symbol = symbol, exported = false, kind = "function",
        signature = function_signature(chunk, lines, stat), text = doc_text(doc), line = line })
    elseif declared ~= nil and not ((stat.kind == "Import")) then
      local name = declared.name
      local kind = type_kind(stat)
      table.insert(out, { symbol = name.name, source_symbol = name.name, exported = false, kind = kind,
        signature = line_at(lines, line), text = doc_text(name.doc), line = line })
      if kind ~= "type" then
        type_docs(chunk, lines, name.name, stat, out)
      end
    elseif (stat.kind == "Local") and #stat.bindings > 0 then
      local first = nth(stat.bindings, 1)
      local text = doc_text(first.doc)
      -- The run above the file's first `local` is the module's (see [`module_doc`]), never that value's.
      if index == 1 and #opening > 0 then
        text = ""
      end
      if #text > 0 then
        table.insert(out, { symbol = first.name, source_symbol = first.name, exported = false, kind = "value",
          signature = line_at(lines, line), text = text, line = line })
      end
    end
  end
  return out
end

--- What the canonical addressing and the reachability make of the entries, kept apart from them: an entry is never
--- changed after it is made, and [`settle`] makes the entries the analysis answers.
local record Marks
  exported: mut {Entry: boolean}
  symbol: mut {Entry: string}
  --- The entry an entry takes its kind, signature, text and line from: a callable implementation lends them to the
  --- field row it implements.
  lent: mut {Entry: Entry}
end

local function new_marks(): Marks
  return { exported = {}, symbol = {}, lent = {} }
end

--- Whether `entry` is reachable through the module's value.
local function is_exported(marks: Marks, entry: Entry): boolean
  local set = marks.exported[entry]
  if set ~= nil then
    return set
  end
  return entry.exported
end

--- The entry whose kind, signature, text and line `entry` has.
local function shown(marks: Marks, entry: Entry): Entry
  return marks.lent[entry] or entry
end

--- The record the module's returned value is typed as. A module that returns a variable declared `local x: Thing =
--- ...` hands out `Thing`'s fields, so `Thing` and what is declared under it are the module's surface, though the
--- returned name is `x`; otherwise the returned name itself. Its rows stay under their own names.
local function surface_of(chunk: Ast.Chunk, marks: Marks, export: string, entries: {Entry}): string
  if export == "" then
    return ""
  end
  for _, stat in ipairs(chunk.body.stats) do
    if (stat.kind == "Local") and #stat.bindings == 1 and nth(stat.bindings, 1).name == export then
      local written = stat.types[1]
      if written ~= nil and (written.kind == "TypeName") and #written.path == 1 then
        local type_name = nth(written.path, 1)
        for _, entry in ipairs(entries) do
          if entry.source_symbol == type_name and shown(marks, entry).kind == "record" then
            return type_name
          end
        end
      end
    end
  end
  return export
end

--- Marks as exported what a module hands out without naming it in its returned value: the record its returned
--- variable is typed as (see [`surface_of`]), and every `local` record, enum, interface or type an exported row's
--- signature names, again for each one that joins, since a caller meets those names in the signatures it reads. A
--- `local` type no exported signature reaches stays private; a member named `_x` is no caller's to read, so its
--- signature reaches nothing.
local function mark_reachable_types(entries: {Entry}, marks: Marks, surface: string, export: string)
  local function under(entry: Entry, root: string): boolean
    return entry.source_symbol == root or String.starts_with(entry.source_symbol, root .. ".")
  end
  if surface ~= export then
    for _, entry in ipairs(entries) do
      if under(entry, surface) then
        marks.exported[entry] = true
      end
    end
  end
  local searched: mut {Entry: boolean} = {}
  local joined = true
  while joined do
    joined = false
    for _, reader in ipairs(entries) do
      local read = shown(marks, reader)
      -- A member named `_x` is hidden from callers, so what its signature names is not reached through it.
      local hidden = reader.source_symbol:find("[.:]_[^.:]*$") ~= nil or reader.source_symbol:sub(1, 1) == "_"
      if is_exported(marks, reader) and not hidden and searched[reader] == nil and read.signature ~= "" then
        searched[reader] = true
        local words = " " .. read.signature .. " "
        for _, entry in ipairs(entries) do
          local name = entry.source_symbol
          local seen = shown(marks, entry)
          if not is_exported(marks, entry) and name:find(".", 1, true) == nil and
              (seen.kind == "record" or seen.kind == "enum" or seen.kind == "interface" or seen.kind == "type") and
              seen.signature:sub(1, 6) == "local " and words:find("[^.%w_]" .. name .. "[^%w_]") ~= nil then
            for _, member in ipairs(entries) do
              if under(member, name) then
                marks.exported[member] = true
              end
            end
            joined = true
          end
        end
      end
    end
  end
end

--- The name of an expression when it is a plain name.
local function name_of(exp: Ast.Exp?): string?
  if exp ~= nil and (exp.kind == "Name") then
    return exp.text
  end
  return nil
end

--- Gives every declaration its stable address within the value returned by the module. The record name is a local
--- implementation detail: both [`Fs.read`] and a renamed `Public.read` are the canonical member `read`. Declarations
--- outside that returned surface stay indexed under their source spelling and are explicitly private.
local function canonicalize_docs(entries: {Entry}, marks: Marks, chunk: Ast.Chunk, export: string,
                                 returned: Ast.Exp?): {Entry}
  local dot = export .. "."
  local colon = export .. ":"
  local by_source: mut {string: {Entry}} = {}
  for _, entry in ipairs(entries) do
    local source = entry.source_symbol
    local bucket = by_source[source]
    if bucket == nil then
      bucket = {}
      by_source[source] = bucket
    end
    bucket[#bucket + 1] = entry
    if export ~= "" and source == export then
      marks.exported[entry] = true
    elseif export ~= "" and String.starts_with(source, dot) then
      -- A method on a nested record (`Thing.Box:grow`) is the member `Box.grow`, as a record field and a use of it are
      -- spelled: the `:` says how it is called, not where it lives, just as `Thing:write` is the member `write`. Only
      -- a method's `:` is that separator: an enum value's row (`Thing.Mode.a:b`) spells the value itself, which may
      -- hold one.
      local member = source:sub(#dot + 1)
      if entry.kind == "method" then
        member = (member:gsub(":", "."))
      end
      marks.symbol[entry] = member
      marks.exported[entry] = true
    elseif export ~= "" and String.starts_with(source, colon) then
      marks.symbol[entry] = source:sub(#colon + 1)
      marks.exported[entry] = true
    end
  end

  -- A deliberately small value model for the module's top-level execution. A binding holds the source identity of the
  -- declaration value currently in it, or "" when an expression is not one of the supported direct values. Assigning
  -- that binding into an export member copies the identity at that point; later reassignment of the local cannot
  -- retroactively change it.
  local values: mut {string: string} = {}
  local members: mut {string: string} = {}
  local function value_of(exp: Ast.Exp?): string
    local name = name_of(exp)
    if name ~= nil then
      return values[name] or ""
    end
    return ""
  end
  for _, stat in ipairs(chunk.body.stats) do
    if (stat.kind == "LocalFunction") then
      values[stat.name.name] = stat.name.name
    elseif (stat.kind == "Local") then
      for index, binding in ipairs(stat.bindings) do
        values[binding.name] = value_of(stat.values[index])
      end
    elseif export ~= "" and owner_of(stat) == export then
      local public_source = export .. "." .. member_of(stat)
      members[public_source] = public_source
    elseif (stat.kind == "Assign") then
      local rhs_values: mut {string} = {}
      for index in ipairs(stat.targets) do
        rhs_values[index] = value_of(stat.values[index])
      end
      for index, lhs in ipairs(stat.targets) do
        if (lhs.kind == "Field") and name_of(lhs.object) == export and export ~= "" then
          members[export .. "." .. lhs.name] = nth(rhs_values, index)
        elseif (lhs.kind == "Name") then
          values[lhs.text] = nth(rhs_values, index)
        end
      end
    end
  end
  if export == "" and returned ~= nil and (returned.kind == "Table") then
    for _, field in ipairs(returned.items) do
      local key: string? = nil
      if (field.kind == "Named") then
        key = field.name
      elseif (field.kind == "Keyed") then
        local written = field.key
        if (written.kind == "String") then
          key = written.value
        end
      end
      if key ~= nil and not ((field.kind == "Positional")) then
        local value_name = name_of(field.value)
        if value_name ~= nil then
          members[key] = values[value_name] or ""
        end
      end
    end
  end

  local out: mut {Entry} = {}
  for _, entry in ipairs(entries) do
    out[#out + 1] = entry
  end
  local public_sources: mut {string} = {}
  for public_source in pairs(members) do
    public_sources[#public_sources + 1] = public_source
  end
  table.sort(public_sources)
  for _, public_source in ipairs(public_sources) do
    local implementation_name = members[public_source] or ""
    local implementation: Entry? = nil
    if implementation_name ~= "" then
      local implementations = by_source[implementation_name]
      if implementations ~= nil and #implementations > 0 then
        implementation = nth(implementations, #implementations)
      end
    end
    local candidates = by_source[public_source] or {}
    local public: Entry? = nil
    -- A declared record field is the stable surface row. When a callable implementation is known it lends this row
    -- its docs and location; every overwritten callable declaration remains inspectable but private.
    for _, candidate in ipairs(candidates) do
      marks.exported[candidate] = false
      marks.symbol[candidate] = candidate.source_symbol
      if public == nil and candidate.kind == "field" then
        public = candidate
      end
    end
    if public == nil and implementation_name ~= "" then
      for _, candidate in ipairs(candidates) do
        if candidate == implementation then
          public = candidate
        end
      end
    end
    local symbol = public_source
    if export ~= "" then
      symbol = public_source:sub(#export + 2)
    end
    if public == nil and implementation ~= nil then
      local lent = shown(marks, implementation)
      out[#out + 1] = { symbol = symbol, source_symbol = public_source, exported = true, kind = lent.kind,
        signature = lent.signature, text = lent.text, line = lent.line }
    elseif public ~= nil then
      marks.symbol[public] = symbol
      marks.exported[public] = true
      if implementation ~= nil then
        marks.lent[public] = shown(marks, implementation)
      end
    end
  end
  return out
end

--- The entries the analysis answers: `entries` with what `marks` settled, and with `module_signature` for the row of the
--- module itself where there is one.
local function settle(entries: {Entry}, marks: Marks, module_signature: string?): {Entry}
  local out: mut {Entry} = {}
  for _, entry in ipairs(entries) do
    local from = shown(marks, entry)
    local signature = from.signature
    if entry.kind == "module" and module_signature ~= nil then
      signature = module_signature
    end
    out[#out + 1] = { symbol = marks.symbol[entry] or entry.symbol, source_symbol = entry.source_symbol,
      exported = is_exported(marks, entry), kind = from.kind, signature = signature, text = from.text,
      line = from.line }
  end
  return out
end

--- The source from one position up to just before another, its lines and indentation kept. A trailing blank or
--- comment-only line belongs to whatever sits after it, not to this statement, so it is trimmed rather than shown as
--- part of the example.
local function block_text(lines: {string}, y: integer, x: integer, until_y: integer, until_x: integer): string
  local parts: mut {string} = {}
  for line_no = y, until_y do
    local line = lines[line_no] or ""
    local from = 1
    if line_no == y then
      from = x
    end
    local to = #line
    if line_no == until_y then
      to = until_x - 1
    end
    parts[#parts + 1] = line:sub(from, to)
  end
  while #parts > 0 and (nth(parts, #parts):match("^%s*$") ~= nil or nth(parts, #parts):match("^%s*%-%-") ~= nil) do
    table.remove(parts)
  end
  return table.concat(parts, "\n")
end

--- Every name the code under `root` refers to, as `used`: the free variables of its expressions (a name that a
--- `local`, a parameter or a loop variable under `root` binds is no reference to a file's own declaration, and neither
--- is a word in a string or a comment) and the first name of each type it writes (`Release` in `x: Release`, `Fs` in
--- [`Fs.Stat`]). A type's name is not scoped, since a local rarely shadows a type, and the path a function declares
--- is no use of its owner.
local function uses_of(scoped: Scopes.Scoped, root: Ast.Node, used: mut {string: boolean})
  local base = Node.base(root)
  local skipped: mut {integer: boolean} = {}
  Node.walk(root, function(node: Ast.Node)
    if (node.kind == "Function") then
      for _, name in ipairs(node.path) do
        skipped[Node.base(name).id] = true
      end
    elseif (node.kind == "Name") and skipped[Node.base(node).id] == nil then
      local var: Scopes.Var? = nil
      local binding = node.binding
      if binding ~= nil then
        var = scoped.vars[binding]
      end
      if var == nil or var.declared < base.first or var.declared > base.last then
        used[node.text] = true
      end
    elseif (node.kind == "TypeName") then
      used[nth(node.path, 1)] = true
    end
  end)
end

--- A file-local declaration an example may use: a `local function`, `local record` or `local type` or `local NAME
--- <const> = ...` that is not a `require`, whole, with the comment lines directly above it. `names` are what it
--- binds; `lines` is its length in lines.
local record Helper
  names: {string}
  code: string
  lines: integer
  node: Ast.Stat
end

--- The longest helper an example carries above its function, in lines, and the most all its helpers together carry. A
--- longer one is not carried: the example then does not compile as shown, and [`build.example_checks`] asks its
--- author to inline it.
local MAX_HELPER_LINES <const> = 15
local MAX_HELPER_TOTAL <const> = 30

--- What an example file's top level holds outside its examples, as text: each `local Name = require("...")` with the
--- name it binds, each call statement (`Test.policy{...}`) and each helper, in file order.
local record Required
  name: string
  code: string
end

local record Preamble
  requires: mut {Required}
  calls: mut {string}
  call_nodes: mut {Ast.Stat}
  helpers: mut {Helper}
end

--- `code`, a statement's text cut at the next statement's start, less the comment lines above that next statement.
local function own_text(code: string): string
  local kept: mut {string} = {}
  for line in String.lines(code) do
    kept[#kept + 1] = line
  end
  while #kept > 0 and (nth(kept, #kept):match("^%s*$") ~= nil or nth(kept, #kept):match("^%s*%-%-") ~= nil) do
    table.remove(kept)
  end
  return table.concat(kept, "\n")
end

local function preamble_of(chunk: Ast.Chunk, lines: {string}): Preamble
  local out: Preamble = { requires = {}, calls = {}, call_nodes = {}, helpers = {} }
  local stats = chunk.body.stats
  for index, stat in ipairs(stats) do
    local until_y, until_x = next_place(chunk, stats, index, #lines)
    local opener = first_token(chunk, stat)
    if (stat.kind == "Local") then
      local code = own_text(block_text(lines, opener.y, opener.x, until_y, until_x))
      local name = code:match("^local%s+([%w_]+)%s*=%s*require%s*%(")
      if name ~= nil then
        out.requires[#out.requires + 1] = { name = name, code = code }
      end
    end
    local declared = Node.declared(stat)
    if (stat.kind == "LocalFunction") or (stat.kind == "Local") or (declared ~= nil and declared.scope == "local") then
      local names: mut {string} = {}
      if (stat.kind == "LocalFunction") then
        names[1] = stat.name.name
      elseif (stat.kind == "Local") then
        for _, binding in ipairs(stat.bindings) do
          names[#names + 1] = binding.name
        end
      elseif declared ~= nil then
        names[1] = declared.name.name
      end
      local first = opener.y
      -- Only `---` doc lines go with it: a `--` note is the author's.
      while first > 1 and nth(lines, first - 1):match("^%-%-%-") ~= nil do
        first = first - 1
      end
      local code = own_text(block_text(lines, first, 1, until_y, until_x))
      local is_require = code:match("^local%s+[%w_]+%s*=%s*require%s*%(") ~= nil or
        code:match("^local%s+type%s+[%w_]+%s*=%s*require%s*%(") ~= nil
      local plain = #names > 0
      for _, name in ipairs(names) do
        if name == "Example" then
          plain = false
        end
      end
      if plain and not is_require then
        local _, breaks = code:gsub("\n", "\n")
        out.helpers[#out.helpers + 1] = { names = names, code = code, lines = breaks + 1, node = stat }
      end
    elseif (stat.kind == "CallStat") then
      table.insert(out.calls, own_text(block_text(lines, opener.y, opener.x, until_y, until_x)))
      out.call_nodes[#out.call_nodes + 1] = stat
    end
  end
  return out
end

--- The text an example's own `function` is shown below: the top-level `require` lines its body (or a top-level call
--- carried with it) names, the short file-local helpers ([`Helper`]) its body names, and those they name, then those
--- calls. An example is a function copied out of its file, and without these lines it does not run. The file's
--- top-level calls (a `Test.policy{...}` a test module makes once, at its top) are carried by the file's first
--- example, since they are not inside any example of their own.
local function preamble_text(scoped: Scopes.Scoped, pre: Preamble, body_node: Ast.Node, first: boolean): string
  local calls: {string} = {}
  if first then
    calls = pre.calls
  end
  local used: mut {string: boolean} = {}
  uses_of(scoped, body_node, used)
  if first then
    for _, node in ipairs(pre.call_nodes) do
      uses_of(scoped, node, used)
    end
  end
  -- Helpers the body names, and those they name in turn, until no more is asked for. One too long to carry is left
  -- out, and so is what only it names.
  local carried: mut {integer: boolean} = {}
  local refused: mut {integer: boolean} = {}
  local total = 0
  local changed = true
  while changed do
    changed = false
    for at, helper in ipairs(pre.helpers) do
      if carried[at] ~= true and refused[at] ~= true then
        for _, name in ipairs(helper.names) do
          if carried[at] ~= true and refused[at] ~= true and used[name] == true then
            if helper.lines <= MAX_HELPER_LINES and total + helper.lines <= MAX_HELPER_TOTAL then
              carried[at] = true
              total = total + helper.lines
              uses_of(scoped, helper.node, used)
              changed = true
            else
              refused[at] = true
            end
          end
        end
      end
    end
  end
  local out: mut {string} = {}
  for _, required in ipairs(pre.requires) do
    if used[required.name] == true then
      out[#out + 1] = required.code
    end
  end
  local helpers: mut {string} = {}
  for at, helper in ipairs(pre.helpers) do
    if carried[at] == true then
      helpers[#helpers + 1] = helper.code
    end
  end
  if #helpers > 0 then
    if #out > 0 then
      out[#out + 1] = ""
    end
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

--- Every worked example a chunk declares at its top level: a `function Example.<name>()`. The shape of the declaration
--- is the only marker, as for the functions [`docs_of`] finds; `name` is a free label. Its doc comment is read as
--- [`docs_of`] reads one: what the example is for in the comment, how in the code below it. Which symbol it
--- demonstrates is decided when [`build.docs`] reads it, by matching this text and source against a symbol's name.
local function examples_of(chunk: Ast.Chunk, scoped: Scopes.Scoped, lines: {string}): {Analyzer.ExampleEntry}
  local out: mut {Analyzer.ExampleEntry} = {}
  local stats = chunk.body.stats
  local pre = preamble_of(chunk, lines)
  for index, stat in ipairs(stats) do
    if (stat.kind == "Function") and is_example_function(stat) then
      local until_y, until_x = next_place(chunk, stats, index, #lines)
      local opener = first_token(chunk, stat)
      local body = own_text(block_text(lines, opener.y, opener.x, until_y, until_x))
      table.insert(out, { name = member_of(stat), text = doc_text(stat.doc),
        source = preamble_text(scoped, pre, stat, #out == 0) .. body, line = opener.y })
    end
  end
  return out
end

--- Every `alias.member` whose `alias` still resolves to a lexical direct require binding, and every
--- `require("module").member` while `require` is not shadowed. This is deliberately bounded: indirect aliases and
--- unknown receiver types produce no edge rather than one guessed from spelling.
local function references_of(chunk: Ast.Chunk, scoped: Scopes.Scoped): {Analyzer.Reference}, {Lexical.Binding}
  local seen: mut {string: boolean} = {}
  local out: mut {Analyzer.Reference} = {}
  local bindings = Lexical.walk(chunk, scoped, function(module: string, name: string, line: integer)
    local id = module .. "\n" .. name .. "\n" .. tostring(line)
    if seen[id] == nil then
      seen[id] = true
      out[#out + 1] = { module = module, member = name, line = line }
    end
  end)
  table.sort(out, function(p: Analyzer.Reference, q: Analyzer.Reference): boolean
    if p.line ~= q.line then
      return p.line < q.line
    end
    if p.module ~= q.module then
      return p.module < q.module
    end
    return p.member < q.member
  end)
  return out, bindings
end

--- The names the chunk's own block binds to a module, in source order: each bound once there, by `local name =
--- require("m")` or `local type name = require("m")`. A name the block binds twice, or to anything else besides, is
--- left out: which binding a type declared under it reads depends on where, and a reader of the rows knows only the
--- type's module. So is one declared with a type of its own (`local B: T = require("m")`), whose `B.X` is `T`'s.
local function bound_of(bindings: {Lexical.Binding}): {Analyzer.Bound}
  local count: mut {string: integer} = {}
  for _, each in ipairs(bindings) do
    if each.top then
      count[each.name] = (count[each.name] or 0) + 1
    end
  end
  local out: mut {Analyzer.Bound} = {}
  for _, each in ipairs(bindings) do
    if each.top and each.module ~= "" and not each.annotated and count[each.name] == 1 then
      out[#out + 1] = { name = each.name, module = each.module }
    end
  end
  return out
end

--- Whether `node` is `require("cosmic.test")`.
local function requires_test(node: Ast.Exp?): boolean
  if node ~= nil and (node.kind == "Call") then
    local callee, first = node.callee, node.args[1]
    return (callee.kind == "Name") and callee.text == "require" and first ~= nil and (first.kind == "String") and
      first.value == "cosmic.test"
  end
  return false
end

--- Whether `node` names [`Test.policy`] through one of `names`, the locals a chunk binds `require("cosmic.test")` to.
local function names_policy(node: Ast.Node?, names: {string: boolean}): boolean
  if node ~= nil and (node.kind == "Field") and node.name == "policy" then
    local object = node.object
    return (object.kind == "Name") and names[object.text] == true
  end
  return false
end

--- `node` as a string written plainly, or nil and why, naming `path`.
local function plain_string(chunk: Ast.Chunk, node: Ast.Exp, path: string): string?, string
  if not ((node.kind == "String")) then
    return nil, path .. " takes a string written out as a literal"
  end
  -- The literal as written, which is what the token holds: an escape the running module decodes would read otherwise
  -- here.
  local written = Lexer.text(chunk.tokens, Node.base(node).first)
  if written:find("\\", 1, true) ~= nil or written:sub(1, 1) == "[" then
    return nil, path .. ": " .. written .. ": write declared paths plainly, without escapes or long brackets"
  end
  return node.value, ""
end

--- The name an entry of a table literal is written with, in `name = ...` or `["name"] = ...`, or nil for an entry with
--- none.
local function entry_name(item: Ast.Item): string?
  if (item.kind == "Named") then
    return item.name
  elseif (item.kind == "Keyed") then
    local key = item.key
    if (key.kind == "String") then
      return key.value
    end
  end
  return nil
end

--- The string literals of a list written out as a literal, or nil and why.
local function string_list(chunk: Ast.Chunk, node: Ast.Exp, path: string): {string}?, string
  if not ((node.kind == "Table")) then
    return nil, path .. " takes a list of string literals, written out"
  end
  local out: mut {string} = {}
  for _, item in ipairs(node.items) do
    if not ((item.kind == "Positional")) then
      return nil, path .. " lists string literals only"
    end
    local text, why = plain_string(chunk, item.value, path)
    if text == nil then
      return nil, why
    end
    out[#out + 1] = text
  end
  return out, ""
end

--- The names and string literals of a table written out as a literal, or nil and why.
local function string_map(chunk: Ast.Chunk, node: Ast.Exp, path: string): {string: string}?, string
  if not ((node.kind == "Table")) then
    return nil, path .. " takes a table, written out"
  end
  local out: mut {string: string} = {}
  for _, item in ipairs(node.items) do
    local name = entry_name(item)
    if name == nil then
      return nil, path .. " names each entry"
    end
    local text, why = plain_string(chunk, item.value, path .. "." .. name)
    if text == nil then
      return nil, why
    end
    out[name] = text
  end
  return out, ""
end

--- A `policy` table literal as [`PolicyRules.PolicyData`], or nil and why.
local function policy_data(chunk: Ast.Chunk, node: Ast.Table): PolicyRules.PolicyData?, string
  local profiles: {string}?
  local isolate: {string}?
  local promises: {string}?
  local connect: {string}?
  local loopback: {string}?
  local env: {string}?
  local requires: {string}?
  local set_env: {string: string}?
  local set_env_digests: {string: string}?
  local grants: {{string: string}}?
  local limits: {string: integer}?
  local tmp: boolean?
  local user: integer?
  local group: integer?
  local database: string?
  local seen: mut {string: boolean} = {}
  for _, item in ipairs(node.items) do
    local field = entry_name(item)
    local takes: string? = nil
    if field ~= nil then
      takes = PolicyRules.kind_of(field)
    end
    if field == nil or takes == nil then
      return nil, (if field ~= nil then ("has no field " .. field) else "has an entry with no name" end) ..
        "; it has " .. PolicyRules.field_list()
    end
    if seen[field] == true then
      return nil, field .. " is declared twice"
    end
    seen[field] = true
    local given = item.value
    local why = ""
    if takes == "flag" then
      if (given.kind == "Boolean") then
        tmp = given.value
      else
        why = field .. " takes true or false"
      end
    elseif takes == "list" then
      if field == "profiles" then
        profiles, why = string_list(chunk, given, field)
      elseif field == "isolate" then
        isolate, why = string_list(chunk, given, field)
      elseif field == "promises" then
        promises, why = string_list(chunk, given, field)
      elseif field == "connect" then
        connect, why = string_list(chunk, given, field)
      elseif field == "loopback" then
        loopback, why = string_list(chunk, given, field)
      elseif field == "requires" then
        requires, why = string_list(chunk, given, field)
      else
        env, why = string_list(chunk, given, field)
      end
    elseif takes == "string" then
      database, why = plain_string(chunk, given, field)
    elseif takes == "map" then
      if field == "set_env" then
        set_env, why = string_map(chunk, given, field)
      else
        set_env_digests, why = string_map(chunk, given, field)
      end
    elseif takes == "id" then
      local number: integer? = nil
      if (given.kind == "Integer") then
        number = given.value
      end
      if number == nil then
        why = field .. " takes a whole number"
      elseif field == "user" then
        user = number
      else
        group = number
      end
    elseif takes == "limits" then
      local found_limits: mut {string: integer} = {}
      limits = found_limits
      if not ((given.kind == "Table")) then
        why = "limits takes a table, written out"
      else
        for _, entry in ipairs(given.items) do
          local name = entry_name(entry)
          local value = entry.value
          local number: integer? = nil
          if (value.kind == "Integer") then
            number = value.value
          end
          if name == nil or number == nil or
              not (name == "open_files" or name == "file_bytes" or name == "cpu_seconds" or name == "processes") then
            why = "limits takes open_files, file_bytes, cpu_seconds and processes, each an integer"
          else
            found_limits[name] = number
          end
        end
      end
    else
      local found_grants: mut {{string: string}} = {}
      grants = found_grants
      if not ((given.kind == "Table")) then
        why = "grants takes a list of grants"
      else
        for i, entry in ipairs(given.items) do
          local at = "grants[" .. tostring(i) .. "]"
          local value = entry.value
          if not ((entry.kind == "Positional")) or not ((value.kind == "Table")) then
            why = at .. " takes a table"
            break
          end
          local grant, grant_why = string_map(chunk, value, at)
          if grant == nil then
            why = grant_why
            break
          end
          for name in pairs(grant) do
            if not (name == "path" or name == "letters" or name == "from") then
              why = at .. " has no field " .. name .. "; it has from, letters, path"
            end
          end
          found_grants[#found_grants + 1] = grant
        end
      end
    end
    if why ~= "" then
      return nil, why
    end
  end
  return { profiles = profiles, isolate = isolate, promises = promises, connect = connect, loopback = loopback,
    env = env, requires = requires, set_env = set_env, set_env_digests = set_env_digests, grants = grants,
    limits = limits, tmp = tmp, user = user, group = group, database = database }, ""
end

--- The chunk's `Test.policy { ... }` (see [`cosmic.test`]), read as data, never run: nil and "" when there is none,
--- and nil and why, naming the line, for one the build cannot read so. The call is a statement at the chunk's top
--- level, once, on a name a top-level `local` binds `require("cosmic.test")` to, with one table literal: `policy`
--- reached any other way -- inside a function, under another name, handed a value computed -- is refused. The policy
--- is held to the rules its own fields are ([`Test.needs_of`]'s), and read as the declaration it stands for.
local function inputs_of(chunk: Ast.Chunk, name: string): PolicyRules.Declared?, string
  local tokens = chunk.tokens
  --- The line a call's arguments start on: where a call is placed.
  local function args_line(call: Ast.Call): integer
    return token_at(tokens, Node.base(call.callee).last + 1).y
  end
  local function at(line: integer): string
    return name .. ":" .. tostring(line) .. ": test.policy: "
  end
  local names: mut {string: boolean} = {}
  local found: Ast.Call? = nil
  local found_line = 0
  local callees: mut {integer: boolean} = {}
  for _, stat in ipairs(chunk.body.stats) do
    if (stat.kind == "Local") then
      for i, binding in ipairs(stat.bindings) do
        if requires_test(stat.values[i]) then
          names[binding.name] = true
        end
      end
    elseif (stat.kind == "CallStat") then
      local call = stat.call
      if (call.kind == "Call") and names_policy(call.callee, names) then
        if found ~= nil then
          return nil, at(args_line(call)) .. "a module declares its policy once; line " .. tostring(found_line) ..
            " did already"
        end
        found = call
        found_line = args_line(call)
        callees[Node.base(call.callee).id] = true
      end
    end
  end
  -- `policy` reached any other way than that one statement.
  local elsewhere: mut {Ast.Field} = {}
  Node.walk(chunk.body, function(node: Ast.Node)
    if #elsewhere == 0 and (node.kind == "Field") and names_policy(node, names) and callees[Node.base(node).id] == nil then
      elsewhere[1] = node
    end
  end)
  if elsewhere[1] ~= nil then
    return nil, at(token_at(tokens, Node.base(nth(elsewhere, 1)).last).y) .. "call it as a statement at the module's top level, " ..
      "on the name the module binds require(\"cosmic.test\") to, and nowhere else"
  end
  if found == nil then
    return nil, ""
  end
  local hand_a_table = at(found_line) .. "hand it one table written out as a literal: Test.policy { grants = { ... } }"
  if #found.args ~= 1 then
    return nil, hand_a_table
  end
  local value = assert(found.args[1], "one argument was counted")
  if not ((value.kind == "Table")) then
    return nil, hand_a_table
  end
  local data, why = policy_data(chunk, value)
  if data == nil then
    return nil, at(found_line) .. why
  end
  local declared, trouble = PolicyRules.declared(data, found_line)
  if declared == nil then
    return nil, at(found_line) .. trouble
  end
  local ready: PolicyRules.Declared = declared
  local function refused_in(field: string, list: {string}): string
    for _, entry in ipairs(list) do
      local refused = PolicyRules.entry_trouble(field, entry)
      if refused ~= "" then
        return refused
      end
    end
    return ""
  end
  local refused = refused_in("reads", ready.reads)
  if refused == "" then
    refused = refused_in("host", ready.host)
  end
  if refused == "" then
    refused = refused_in("env", ready.env)
  end
  if refused == "" then
    refused = refused_in("network", ready.network)
  end
  if refused ~= "" then
    return nil, at(found_line) .. refused
  end
  return ready, ""
end

--- What a chunk's own statement list says: its `test_*` functions, in order, whether it ends in a `return`, the name
--- returned, and the value returned.
local record Facts
  tests: mut {string}
  mut has_return: boolean
  mut export: string
  mut returned: Ast.Exp?
end

local function facts_of(chunk: Ast.Chunk): Facts
  local out: Facts = { tests = {}, has_return = false, export = "", returned = nil }
  for _, stat in ipairs(chunk.body.stats) do
    if (stat.kind == "LocalFunction") then
      if stat.name.name:match("^test_") ~= nil then
        out.tests[#out.tests + 1] = stat.name.name
      end
    elseif (stat.kind == "Return") then
      out.has_return = true
      out.returned = stat.values[1]
      local returned = out.returned
      if returned ~= nil and (returned.kind == "Name") then
        out.export = returned.text
      end
    end
  end
  return out
end

function Analyzer.docs(chunk: Ast.Chunk, source: string): {Entry}
  local facts = facts_of(chunk)
  local marks = new_marks()
  local entries = canonicalize_docs(docs_of(chunk, lines_of(source)), marks, chunk, facts.export, facts.returned)
  mark_reachable_types(entries, marks, surface_of(chunk, marks, facts.export, entries), facts.export)
  return settle(entries, marks, nil)
end

function Analyzer.analysis_of(chunk: Ast.Chunk, scoped: Scopes.Scoped, source: string,
                              name: string): Analyzer.Analysis?, string
  local facts = facts_of(chunk)
  local references, bindings = references_of(chunk, scoped)
  local declared, inputs_trouble = inputs_of(chunk, name)
  if inputs_trouble ~= "" then
    return nil, inputs_trouble
  end
  local lines = lines_of(source)
  local marks = new_marks()
  local entries = canonicalize_docs(docs_of(chunk, lines), marks, chunk, facts.export, facts.returned)
  local export = facts.export
  local surface = surface_of(chunk, marks, export, entries)
  mark_reachable_types(entries, marks, surface, export)
  -- The record the value is typed as, when the returned name is not that record, is the module's row's signature, as
  -- its declaration reads: a lookup finds the module's members under it ([`alias_members.value_record`]), since their
  -- rows keep the record's name.
  --
  -- TODO: record it for a module with no doc comment of its own too, which has no row to hold it, so no lookup finds
  -- its members by the module's name: that wants a row of kind `module` with no text, once `cosmic docs`' index and
  -- build.docs_checks' rendered-docs checks take one.
  local module_signature: string? = nil
  if surface ~= export then
    module_signature = "local " .. export .. ": " .. surface
  end
  return {
    tests = facts.tests, inputs = declared, has_top_level_return = facts.has_return, export = export,
    catalog = catalog_of(chunk), docs = settle(entries, marks, module_signature),
    examples = examples_of(chunk, scoped, lines), references = references, bound = bound_of(bindings),
  }, ""
end

function Analyzer.analyze(source: string, name: string): Analyzer.Analysis?, string
  local chunk, trouble = Node.parse(source, name)
  if chunk == nil then
    return nil, trouble
  end
  return Analyzer.analysis_of(chunk, Node.scope(chunk, name), source, name)
end

return Analyzer
