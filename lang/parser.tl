--- The parser of the new checker's grammar: the tokens of [`lang.lexer`] to the syntax tree of
--- [`lang.ast`], in one of two dialects, `tl` for a program and `decl` for a
--- declaration file (`.d.tl`).
---
--- It reads the tokens once, left to right, with no backtracking. It looks
--- past the current token only where the grammar's "lookahead" lists, and
--- never more than three tokens.
---
--- It never raises. A syntax error is an [`Error`] with a code, the place of
--- the token at fault, a message that says what is wrong and a fix written
--- against the program's own text; the parser then recovers and goes on, so
--- one run reports several errors. A failed production leaves an [`Error`] or
--- `TypeError` node holding the tokens it skipped, so the tree still tiles
--- the tokens. An `$ERR$` token is a form the lexer has already reported, and
--- the parser reports nothing more at it.
---
--- A form the grammar cuts is refused with its own code and the form to write
--- instead (`T | nil`, `goto`, a function with a colon, a `global` in a
--- program). The one cut form that still parses is `e as T`, the transition
--- cast: the tree holds a `Cast` and the checker refuses it.
---
--- Where the grammar is loose the parser settles it as below. It
--- stops at 200 levels of nesting, the size of Lua's own limit (Lua counts its
--- C levels and this parser its blocks, expressions and types), and reports nothing more of
--- that construct. A `|` and a `(` that begin a line in a `match` arm begin the
--- next arm and continue no expression or type.
---
--- A tree is as deep as a chain of `a + a + ...` is long, so the recursive
--- walkers of [`lang.parser_cover`] and [`lang.ast_dump`] can overflow the
--- stack on one of a hundred thousand operands. The parser, [`Ast.number`]
--- and the search the parser makes of an `until` do not.
---
--- The parser keeps its state in a table of its own, so it is not re-entrant:
--- it runs one parse at a time, as the one thread of a cosmic program does.

local Ast = require("lang.ast")
local Lexer = require("lang.lexer")

local record Parser
  --- What an error is, so that a reader does not parse its `msg`. The lexer's
  --- codes ([`Lexer.Code`]) come first, then the parser's.
  enum Code
    "label_or_goto" "semicolon" "long_comment" "unterminated_long_comment"
    "digit_separator" "hex_float" "malformed_number" "unterminated_string"
    "unterminated_long_string" "bad_escape" "stray_byte"
    -- a reserved word where a name stands
    "reserved_word"
    -- `T | nil`, which is `T?`
    "nil_union"
    -- a method in a `record` or an `interface`, or `function R:m()`
    "method_in_record"
    -- `continue` or `break` outside a loop of its own function
    "continue_outside_loop" "break_outside_loop"
    -- a `continue` in a `repeat` that skips a local the `until` reads
    "continue_skips_local"
    -- a closer missing: the message names the opener and its line
    "unclosed"
    -- any other token missing or in the wrong place
    "expected_token" "expected_name" "expected_expression" "expected_type"
    -- a token no statement begins with
    "unexpected_token"
    -- an expression statement that is no call, and an assignment to what is no place
    "not_a_statement" "bad_target"
    -- a statement after `return`, and a `return` that has none to end
    "statement_after_return"
    -- `T??`, `a is B is C`, and `is` with a union or an optional type
    "chained_optional" "chained_is" "is_union"
    -- `function f()` as a global, `record R` with no `local`, `function a.b.c()`
    "bare_function" "bare_declaration" "function_path"
    -- `global` in a program; `userdata` outside a record of a declaration file
    "global_in_program" "userdata_in_program"
    -- a field declared twice outside the overloads of a declaration file
    "duplicate_field"
    -- a function body, or a statement of no declaration, in a declaration file
    "body_in_declaration" "statement_in_declaration"
    -- the cut forms: `mut` of what is no collection, `f"s"`, `T...`, `? T`,
    -- a tuple type, a string as a type, a bare `function` type,
    -- `metamethod`, several supertypes, a type parameter on a function
    -- literal, an attribute that is not `const` or `close`
    "mut_needs_collection" "string_call" "variadic_type" "optional_type" "tuple_type"
    "string_literal_type" "bare_function_type" "metamethod" "several_supers"
    "generic_function_literal" "bad_attribute"
    -- an `if` expression with no `else`; a `match` of what is no call
    "if_needs_else" "match_needs_call"
    -- a method whose first parameter is not `self`, and a method named as if outside its class
    "method_needs_self" "method_path"
    -- a second `<close>` local in one declaration
    "close_repeated"
    -- a comma with nothing after it in a list of parameters or patterns
    "trailing_comma"
    -- two `match` arms on a line
    "arm_on_same_line"
    -- a `match` arm after one that every value matches, and a name bound twice in an arm
    "unreachable_arm" "duplicate_binding"
    -- `obj:goto()`, a method call by a word Lua 5.5 reserves
    "reserved_method"
    -- a suffix on what is not a name or a parenthesis
    "suffix_needs_parens"
    -- a type declaration in an `interface`, `local type X = record`, a narrowing among other return items
    "nested_in_interface" "old_type_declaration" "narrowing_return"
    -- blocks, expressions or types nested past `MAX_NESTING`
    "too_deep"
    -- `require(name)` or `pcall(require, name)` with a name that is no string literal
    "computed_require"
    -- `require` read as a value: aliased, parenthesised or passed anywhere but as the first argument of `pcall`
    "require_value"
  end

  --- A syntax error, or the lexer's error carried over. `y`, `x`, `offset`
  --- and `length` place the token at fault (length 0 at the end of the file).
  record Error
    filename: string
    code: Code
    --- What is wrong, in one line.
    msg: string
    --- How to put it right, written against the program's own text.
    fix: string
    y: integer
    x: integer
    offset: integer
    length: integer
    --- The second place the error involves, where there is one: the opener
    --- an `unclosed` names, the `continue` a local is declared after, the
    --- `return` a statement follows.
    other?: Place
  end

  --- A place of a token, as an error gives it.
  record Place
    y: integer
    x: integer
    offset: integer
    length: integer
  end

  --- What `parse` answers.
  record Parsed
    chunk: Ast.Chunk
    --- The lexer's errors and the parser's, in source order.
    errors: {Error}
  end

  --- Parses `lexed`, which is the lexing of a source named `name`, as a
  --- program (`tl`) or a declaration file (`decl`). The chunk's nodes are
  --- numbered.
  parse: function(lexed: Lexer.Lexed, name: string, dialect: Ast.Dialect): Parsed

  --- Every [`Code`], in the order the enum lists them.
  codes: {Code}
end

local LEXER_CODES <const>: {string: Parser.Code} = {
  label_or_goto = "label_or_goto",
  semicolon = "semicolon",
  long_comment = "long_comment",
  unterminated_long_comment = "unterminated_long_comment",
  digit_separator = "digit_separator",
  hex_float = "hex_float",
  malformed_number = "malformed_number",
  unterminated_string = "unterminated_string",
  unterminated_long_string = "unterminated_long_string",
  bad_escape = "bad_escape",
  stray_byte = "stray_byte",
}

local record Loop
  repeat_loop: boolean
  --- The block depth of a `repeat`'s body.
  depth: integer
  --- The token of the first `continue` that targets it, 0 where none does.
  continue_at: integer
  --- The names its body's own level declares after that `continue`, and the
  --- token of the first statement that does, 0 where none does.
  after: {string}
  after_at: integer
end

--- What one parse keeps. A function assigns a field of it, not a local of the
--- module, so that every function reads the one `S`.
local record State
  mut tokens: Lexer.Tokens
  --- The arrays of `tokens`, which the parser reads far oftener than the record.
  mut kinds: {Lexer.Kind}
  mut texts: {string}
  mut ys: {integer}
  mut yends: {integer: integer}
  --- The index of the `$EOF$` token, which a look past the end finds.
  mut last: integer
  --- The index of the current token, and its text and kind, which the parser
  --- reads far oftener than the token.
  mut pos: integer
  mut text: string
  mut kind: Lexer.Kind
  mut errors: mut {Parser.Error}
  --- The name of the source in each error.
  mut name: string
  --- Whether the dialect is `decl`.
  mut decl: boolean
  --- The index of a `>>` token whose first `>` has closed a list.
  mut half: integer
  --- The code of the error at each token, which is not reported twice.
  mut reported: mut {integer: Parser.Code}
  --- The tokens a `local` or `function` begins a line at, when needed, and the steps spent searching them.
  mut beside: {integer}
  mut beside_work: integer
  --- Whether the nesting limit has been passed: what follows is reported no further.
  mut muted: boolean
  --- How many blocks, expressions and types the production being parsed is inside.
  mut nesting: integer
  --- How many `match` arms of the function being parsed it is inside, the
  --- token the innermost began at, and the brackets open between that token
  --- and `scan_at`, which only moves forward.
  mut arms: integer
  --- How many table constructors of the function being parsed it is inside.
  mut tables: integer
  mut arm_from: integer
  --- The token of a second arm on a line, which ends the expression before it.
  mut arm_same: integer
  mut scan_at: integer
  mut scan_depth: integer
  --- How many blocks the current one is inside, from 1 in the chunk.
  mut depth: integer
  --- The loops the production being parsed is inside, outermost first, and
  --- how many of them belong to the functions around the current one.
  mut loops: mut {Loop}
  mut loop_base: integer
  --- The literal requires so far, and the node each is of, whose ids are set once the tree is numbered.
  mut requires: mut {Ast.Require}
  mut require_nodes: mut {Ast.Node}
  --- Each token that reads the name `require`, by its index, and whether a `require(...)` or `pcall(require, ...)` took it.
  mut require_names: mut {integer: boolean}
end

local NO_TOKENS <const>: Lexer.Tokens = Lexer.lex("", "").tokens

local S: State = {
  tokens = NO_TOKENS, kinds = NO_TOKENS.kind, texts = NO_TOKENS.text, ys = NO_TOKENS.y,
  yends = NO_TOKENS.yend, last = 1, pos = 1, text = "", kind = "$EOF$", errors = {}, name = "",
  decl = false, half = 0, reported = {}, beside = nil, beside_work = 0, muted = false, nesting = 0, arms = 0, tables = 0, arm_from = 1, arm_same = 0, scan_at = 1, scan_depth = 0, depth = 0, loops = {}, loop_base = 0, requires = {},
  require_nodes = {}, require_names = {},
}

local ADDED <const>: mut {string: boolean} = {}
for _, word in ipairs(Lexer.added) do
  ADDED[word] = true
end

local DECL_WORD <const>: mut {string: boolean} = {}
for _, word in ipairs(Lexer.declaration_words) do
  DECL_WORD[word] = true
end

--- The reserved words that may stand where a field name does: the ones the
--- grammar adds, and `goto` and `global`. The tree writes no other.
local FIELD_WORD <const>: mut {string: boolean} = { ["goto"] = true, ["global"] = true }
for word in pairs(ADDED) do
  FIELD_WORD[word] = true
end

--- The reserved words that no name is, which a use as one is refused with a
--- rename.
local RESERVED_NAME <const>: {string: boolean} = FIELD_WORD

--- The tokens that end a block. `$EOF$` has the text "".
local TERMINATOR <const>: {string: boolean} = { ["end"] = true, ["else"] = true, ["elseif"] = true, ["until"] = true, [""] = true }

--- The keywords that end a block, which a skip past the construct that was too deep does not stop at.
local CLOSES <const>: {string: boolean} = { ["end"] = true, ["else"] = true, ["elseif"] = true, ["until"] = true }

--- The tokens a skip stops at: those a statement begins with, and the ones that end a block.
local SYNC <const>: {string: boolean} = {
  ["end"] = true, ["else"] = true, ["elseif"] = true, ["until"] = true, [""] = true,
  ["local"] = true, ["global"] = true, ["function"] = true, ["if"] = true, ["while"] = true, ["for"] = true,
  ["repeat"] = true, ["do"] = true, ["return"] = true, ["break"] = true, ["continue"] = true, ["match"] = true,
}

--- The deepest nesting of blocks, expressions and types the parser follows,
--- the size of Lua's limit on syntax levels (which counts its C levels, so the
--- two differ by a few): deeper input is an error, not a stack overflow.
local MAX_NESTING <const> = 200

local RENAME <const>: {string: string} = {
  match = "matched", continue = "continued", mut = "mutable", is = "is_a", asserts = "asserted",
  userdata = "data", as = "alias",
}

local function advance()
  local s = S
  local p = s.pos + 1
  local text = s.texts[p]
  if text == nil then
    return
  end
  s.pos = p
  s.text = text
  s.kind = s.kinds[p]
end

--- The text of the token `n` places after the current one; "" past the end,
--- as the `$EOF$` token's.
local function peek_text(n: integer): string
  return S.texts[S.pos + n] or ""
end

--- The kind of the token `n` places after the current one; `$EOF$` past the end.
local function peek_kind(n: integer): Lexer.Kind
  return S.kinds[S.pos + n] or "$EOF$"
end

--- Whether token `i` begins on a later line than the one before it ends.
local function begins_line(i: integer): boolean
  local ys = S.ys
  return ys[i] > (S.yends[i - 1] or ys[i - 1])
end

--- Whether token `i` begins on the line the one before it ends.
local function same_line(i: integer): boolean
  local ys = S.ys
  return ys[i] == (S.yends[i - 1] or ys[i - 1])
end

--- How token `i` reads in a message.
local function shown(i: integer): string
  local kind = S.kinds[i]
  local text = S.texts[i]
  if kind == "$EOF$" then
    return "the end of the file"
  elseif kind == "string" then
    return "a string"
  elseif kind == "$ERR$" then
    return "an invalid token"
  elseif #text > 24 then
    return "`" .. text:sub(1, 24) .. "...`"
  end
  return "`" .. text .. "`"
end

--- Reports an error at the token `index`, with the token `other` as the second
--- place it involves. Nothing is added for a token the lexer has already
--- reported, or twice for one token; a construct not closed may follow another
--- error there, and a statement after a `return` gives way to it.
local function report(code: Parser.Code, index: integer, msg: string, fix: string, other?: integer)
  local at = S.last
  if index >= 1 and index <= S.last then
    at = index
  end
  local seen = S.reported[index]
  if S.kinds[at] == "$ERR$" or S.muted or (seen ~= nil and not (code == "unclosed" and (seen == "unclosed" or seen == "statement_after_return"))) then
    return
  end
  S.reported[index] = code
  local place: Parser.Place = nil
  if other ~= nil then
    place = { y = S.ys[other], x = Lexer.x(S.tokens, other), offset = S.tokens.offset[other], length = #S.texts[other] }
  end
  table.insert(S.errors, {
    filename = S.name, code = code, msg = msg, fix = fix, y = S.ys[at], x = Lexer.x(S.tokens, at), offset = S.tokens.offset[at],
    length = #S.texts[at], other = place,
  })
end

--- Whether the current token is a `|` that begins the next `match` arm: it
--- is followed by `(`, no bracket opened in the arm is still open, and it
--- begins a line. An arm on the line of another is an error, and is read as an arm
--- all the same where an expression goes on; in a type it is a union of value lists,
--- which looks the same. Any other `|` is a bitwise or or a union.
local function arm_bar(in_expression: boolean): boolean
  if S.text ~= "|" or S.arms == 0 or peek_text(1) ~= "(" then
    return false
  end
  local pos = S.pos
  if S.arm_same == pos then
    return true
  end
  local depth = S.scan_depth
  for i = S.scan_at, pos - 1 do
    local t = S.texts[i]
    if t == "(" or t == "[" or t == "{" then
      depth = depth + 1
    elseif t == ")" or t == "]" or t == "}" then
      depth = depth - 1
    end
  end
  S.scan_at = pos
  S.scan_depth = depth
  if depth > 0 then
    return false
  elseif begins_line(pos) then
    return true
  end
  local first, after = peek_text(2), peek_text(3)
  if in_expression and (first == "true" or first == "false") and (after == "," or after == ")") then
    report("arm_on_same_line", pos, "a `match` arm begins on the line of the arm before it",
      "start each arm on its own line")
    S.arm_same = pos
    return true
  end
  return false
end

--- The last token of the production just parsed, which is the current one
--- when a `>>` has closed its list with its first `>` only.
local function end_of(): integer
  if S.half == S.pos then
    return S.pos
  end
  return S.pos - 1
end

--- Consumes a stray `>>` left by one closer too few.
local function settle()
  if S.half == S.pos then
    report("unexpected_token", S.pos, "`>>` closes one list of type arguments too many", "write `>` once for each `<` that is open")
    S.half = 0
    advance()
  end
end

--- Consumes the token `want` or reports it missing, saying where it belongs
--- in `after` and what to write in `fix`. Answers whether it was there.
local function expect(want: string, after: string, fix: string): boolean
  if S.text == want then
    advance()
    return true
  end
  report("expected_token", S.pos, "expected `" .. want .. "` " .. after .. ", found " .. shown(S.pos), fix)
  return false
end

--- The tokens, in order, where a `local` or a `function` begins a line. Made
--- once for a parse, when a body is found open at the end of the file.
local function line_starts_of_statements(): {integer}
  local found = S.beside
  if found == nil then
    found = {}
    local texts = S.texts
    for i = 2, S.last - 1 do
      local text = texts[i]
      if (text == "function" or text == "local") and begins_line(i) then
        found[#found + 1] = i
      end
    end
    S.beside = found
  end
  return found
end

--- Where, after the construct that opened at the token `open`, a `local` or a
--- `function` begins a line no deeper than the construct, which shows it ended
--- there; 0 if none does. A body left open to the end of the file is read this
--- way, unless its code is written no deeper than the construct (flush left), or the
--- search has cost more than a few passes over the tokens, when it is read as at the end.
local function begins_beside(open: integer): integer
  local ys, yends, tokens = S.ys, S.yends, S.tokens
  local count = S.last
  if S.muted or S.beside_work > 8 * count + 1000 then
    return 0
  end
  local at = open
  while at > 1 and (yends[at - 1] or ys[at - 1]) == ys[open] do
    at = at - 1
  end
  local body = open + 1
  local open_end = yends[open] or ys[open]
  while body < count and ys[body] <= open_end do
    body = body + 1
  end
  S.beside_work = S.beside_work + (open - at) + (body - open)
  local x = Lexer.x(tokens, at)
  if body >= count or Lexer.x(tokens, body) <= x then
    return 0
  end
  local starts = line_starts_of_statements()
  local low, high = 1, #starts + 1
  while low < high do
    local mid = (low + high) // 2
    if starts[mid] > open then
      high = mid
    else
      low = mid + 1
    end
  end
  for k = low, #starts do
    S.beside_work = S.beside_work + 1
    local i = starts[k]
    if Lexer.x(tokens, i) <= x then
      return i
    end
  end
  return 0
end

--- Consumes `want`, the closer of the construct `desc` that opened at the
--- token `open`, or reports it missing and names the opener and its line.
local function close(want: string, open: integer, desc: string): boolean
  if S.text == want then
    advance()
    return true
  end
  local open_line = S.ys[open]
  local at = S.kind == "$EOF$" and begins_beside(open) or 0
  if at > 0 then
    local at_line = S.ys[at]
    report("unclosed", at,
      "expected `" .. want .. "` to close the " .. desc .. " on line " .. open_line .. " before the " .. shown(at) ..
        " on line " .. at_line .. ", which begins no deeper than it",
      "write `" .. want .. "` where the " .. desc .. " on line " .. open_line .. " ends, before line " .. at_line, open)
    return false
  end
  report("unclosed", S.pos,
    "expected `" .. want .. "` to close the " .. desc .. " on line " .. open_line .. ", found " .. shown(S.pos),
    "write `" .. want .. "` where the " .. desc .. " on line " .. open_line .. " ends, or delete its `" .. S.texts[open] ..
      "`", open)
  return false
end

--- Consumes the `want` that ends `body`, a block a construct opened at the
--- token `open` holds, or reports it missing. The block then ends before
--- the token that stopped it, which its parent leaves for what follows.
local function close_block(body: Ast.Block, want: string, open: integer, desc: string)
  if not close(want, open, desc) then
    body.last = body.close - 1
  end
end

--- After a `,` that has been consumed: refuses it where the `closer` of the
--- list follows, since a list of `what` takes no trailing comma.
local function after_comma(closer: string, what: string)
  if S.text == closer then
    report("trailing_comma", S.pos - 1, "a comma ends the list of " .. what .. " with nothing after it",
      "delete the `,` before the `" .. closer .. "`")
  end
end

--- Consumes the `>` that closes a list of type arguments or parameters that
--- opened at `open`; the first `>` of a `>>` closes one list and the second
--- the next. Answers the index of the token the list ended at.
local function close_angle(open: integer): integer
  if S.text == ">" then
    advance()
    return S.pos - 1
  elseif S.text == ">>" then
    if S.half == S.pos then
      S.half = 0
      advance()
      return S.pos - 1
    end
    S.half = S.pos
    return S.pos
  end
  close(">", open, "list of type arguments")
  return S.pos - 1
end

--- The source text of the tokens `first` to `last`, spaced as the source spaces
--- them. A `limit` above 0 stops it at the token that passes that many bytes, and
--- ends it with an ellipsis.
local function source_text(first: integer, last: integer, limit: integer): string
  local parts: mut {string} = {}
  local size = 0
  local offsets = S.tokens.offset
  for i = first, last do
    local text = S.texts[i]
    parts[#parts + 1] = text
    size = size + #text
    if limit > 0 and size > limit and i < last then
      parts[#parts + 1] = "\226\128\166"
      break
    end
    if i < last and offsets[i + 1] > offsets[i] + #text then
      parts[#parts + 1] = " "
      size = size + 1
    end
  end
  return table.concat(parts)
end

--- [`source_text`] cut to a length a message can quote.
local function quoted_text(first: integer, last: integer): string
  return source_text(first, last, 60)
end

--- The comments that are the doc comment of the declaration that begins at
--- the token `index`: the run on the lines just before it, each comment on a
--- line of its own, not the end of a line of code. Nil where there is none.
local function doc_of(index: integer): {Lexer.Comment}
  local comments = S.tokens.comments[index]
  if comments == nil then
    return nil
  end
  local line = S.ys[index] - 1
  local floor = S.yends[index - 1] or S.ys[index - 1] or 0
  local from = #comments + 1
  for i = #comments, 1, -1 do
    local c = comments[i]
    if c.y ~= line or c.y <= floor then
      break
    end
    from = i
    line = line - 1
  end
  if from > #comments then
    return nil
  end
  local doc: mut {Lexer.Comment} = {}
  for i, c in ipairs(comments) do
    if i >= from then
      doc[#doc + 1] = c
    end
  end
  return doc
end

local function base_of(node: Ast.Node): Ast.Base
  return node
end

local parse_expression: function(): Ast.Exp
local parse_prefix: function(): Ast.Exp
local parse_type: function(): Ast.Type
local parse_base: function(): Ast.Type
local parse_base_inner: function(first: integer, t: string, k: Lexer.Kind): Ast.Type
local parse_block: function(mode: integer): Ast.Block
local parse_statement: function(): Ast.Stat
local parse_rets: function(): Ast.Rets
local parse_typeparams: function(): {Ast.TypeParam}

--- A binding for the name at the current token. A reserved word that no
--- block ends with is taken as the name, after the error that says to rename it.
local function binding(what: string): Ast.Binding
  local first = S.pos
  if S.kind == "identifier" then
    local name = S.text
    advance()
    return { kind = "Binding", id = 0, first = first, last = first, name = name }
  end
  local word = S.text
  if S.kind == "keyword" and RESERVED_NAME[word] == true then
    local suggestion = RENAME[word] or (word .. "_")
    report("reserved_word", first, "`" .. word .. "` is a reserved word and cannot name " .. what,
      "rename " .. what .. ", for example `" .. suggestion .. "`; `" .. word .. "` stays legal as a field name: `t." .. word .. "`, `s:" .. word .. "(x)`")
    advance()
    return { kind = "Binding", id = 0, first = first, last = first, name = word }
  end
  if S.kind == "keyword" then
    report("expected_name", first, "expected a name for " .. what .. ", found `" .. word .. "`, which is a reserved word",
      "write a name that is not a keyword")
  else
    report("expected_name", first, "expected a name for " .. what .. ", found " .. shown(S.pos),
      "write a name: letters, digits and `_`, not beginning with a digit")
  end
  return { kind = "Binding", id = 0, first = first, last = first - 1, name = "" }
end

--- A name after `.` or `:`, where a word the grammar reserves stands too.
local function is_field_word(): boolean
  return S.kind == "identifier" or (S.kind == "keyword" and FIELD_WORD[S.text] == true)
end

local function field_name(): string
  if is_field_word() then
    local name = S.text
    advance()
    return name
  end
  report("expected_name", S.pos, "expected a field name after `" .. S.texts[S.pos - 1] .. "`, found " .. shown(S.pos),
    "write the field's name, or `[\"name\"]` to index with a string")
  return ""
end

local function error_node(first: integer): Ast.Error
  return { kind = "Error", id = 0, first = first, last = S.pos - 1 }
end

--- Refuses a production nested past `MAX_NESTING` and skips one token.
local function too_deep(first: integer): Ast.Error
  report("too_deep", first, "more than " .. tostring(MAX_NESTING) .. " levels of nesting",
    "split the code: name an inner expression with a `local`, or move an inner block into a function")
  S.muted = true
  if S.kind ~= "$EOF$" then
    advance()
  end
  return error_node(first)
end

--- Skips to the next token that ends a block.
local function skip_to_terminator(first: integer): Ast.Error
  while TERMINATOR[S.text] ~= true do
    advance()
  end
  return error_node(first)
end

--- Skips the tokens of a statement that cannot be parsed, from `first` to
--- the next token a statement or a block ends with, or an identifier or `(`
--- that begins a line. It skips at least one token when `force` is set.
local function skip_junk(first: integer, force: boolean): Ast.Error
  if force and S.kind ~= "$EOF$" then
    advance()
  end
  while S.kind ~= "$EOF$" and SYNC[S.text] ~= true do
    if (S.kind == "identifier" or S.text == "(" or (S.kind == "keyword" and RESERVED_NAME[S.text] == true)) and
        begins_line(S.pos) then
      break
    end
    advance()
  end
  return error_node(first)
end

-- types

--- Whether a `,` at the current token ends a type list because a parameter
--- begins after it: `Name :`, `Name ? :` or `...`.
local function starts_parameter(): boolean
  if peek_text(1) == "..." then
    return true
  elseif peek_kind(1) ~= "identifier" then
    return false
  end
  local b = peek_text(2)
  return b == ":" or (b == "?" and peek_text(3) == ":")
end

--- The union of the tokens `first` to `last` written `T | nil` or `nil | T`,
--- reported with the form to write instead: the members that are not `nil`, as
--- they are written, with `?` after them.
local function refuse_nil_union(members: {Ast.Type}, first: integer, last: integer)
  local at = 0
  for _, m in ipairs(members) do
    local b = base_of(m)
    if m.kind == "TypeNil" and at == 0 then
      at = b.first
    end
  end
  if at == 0 then
    return
  end
  local kept: mut {string} = {}
  local depth, from = 0, first
  for i = first, last + 1 do
    local t = S.texts[i]
    if i == last + 1 or (depth == 0 and t == "|") then
      local text = source_text(from, i - 1, 0)
      if text ~= "nil" then
        kept[#kept + 1] = text
      end
      from = i + 1
    elseif t == "(" or t == "{" or t == "<" then
      depth = depth + 1
    elseif t == ")" or t == "}" or t == ">" then
      depth = depth - 1
    elseif t == ">>" then
      depth = depth - 2
    end
  end
  local rest = "nil"
  if #kept == 1 then
    local one = kept[1]
    if one:sub(-1) == "?" then
      rest = one
    elseif one:sub(1, 8) == "function" then
      rest = "(" .. one .. ")?"
    else
      rest = one .. "?"
    end
  elseif #kept > 1 then
    rest = "(" .. table.concat(kept, " | ") .. ")?"
  end
  report("nil_union", at, "`" .. quoted_text(first, last) .. "` is not in the grammar: a type that may be nil is written with `?`",
    "write `" .. rest .. "`")
end

local function finish_optional(first: integer, base: Ast.Type): Ast.Type
  if S.text ~= "?" then
    return base
  end
  advance()
  local node: Ast.TypeOptional = { kind = "TypeOptional", id = 0, first = first, last = S.pos - 1, inner = base }
  if S.text == "?" then
    report("chained_optional", S.pos, "`??` is not in the grammar", "write a single `?`: `T?` already admits nil")
    advance()
    node.last = S.pos - 1
  end
  return node
end

local function finish_union(first: integer, head: Ast.Type): Ast.Type
  if S.text ~= "|" or arm_bar(false) then
    return head
  end
  local members: mut {Ast.Type} = { head }
  while S.text == "|" and not arm_bar(false) do
    advance()
    local f = S.pos
    members[#members + 1] = finish_optional(f, parse_base())
  end
  local last = end_of()
  refuse_nil_union(members, first, last)
  return { kind = "TypeUnion", id = 0, first = first, last = last, members = members }
end

--- A type that begins at `first` with the type `base`, already parsed: its `?` and the union it begins.
local function continue_type(first: integer, base: Ast.Type): Ast.Type
  return finish_union(first, finish_optional(first, base))
end

--- `Name`, `Name.Name`, ... as the strings of its path.
local function parse_path(): {string}
  local path: mut {string} = {}
  if S.kind ~= "identifier" then
    report("expected_name", S.pos, "expected a type name, found " .. shown(S.pos), "write the name of a type: `string`, `Reader`, `Stream.Reader`")
    return path
  end
  path[1] = S.text
  advance()
  while S.text == "." and peek_kind(1) == "identifier" do
    advance()
    path[#path + 1] = S.text
    advance()
  end
  return path
end

--- A type argument list or a list of types: the types separated by `,`, a
--- `,` ending the list where a parameter begins after it.
local function parse_type_list(): {Ast.Type}
  local list: mut {Ast.Type} = { parse_type() }
  while S.text == "," and not starts_parameter() do
    advance()
    list[#list + 1] = parse_type()
  end
  return list
end

--- A type with its `>>` settled, for a place that nothing closes after.
local function parse_annotation(): Ast.Type
  local t = parse_type()
  settle()
  return t
end

local function parse_rtype(): Ast.RType
  local first = S.pos
  if S.kind == "identifier" and peek_text(1) == "is" then
    local param = S.text
    advance()
    advance()
    local t = parse_type()
    return { kind = "Narrows", id = 0, first = first, last = end_of(), param = param, type = t, asserts = false }
  elseif S.text == "asserts" and peek_kind(1) == "identifier" and peek_text(2) == "is" then
    advance()
    local param = S.text
    advance()
    advance()
    local t = parse_type()
    return { kind = "Narrows", id = 0, first = first, last = end_of(), param = param, type = t, asserts = true }
  end
  return parse_type()
end

--- The type of a function type: `function<T>(a: A, b?: B, ...: C): R`.
local function parse_function_type(): Ast.Type
  local first = S.pos
  advance()
  local typeparams: {Ast.TypeParam} = {}
  if S.text == "<" then
    typeparams = parse_typeparams()
  end
  local params: mut {Ast.PType} = {}
  if S.text ~= "(" then
    report("bare_function_type", S.pos, "a bare `function` is not a type: found " .. shown(S.pos) .. " where its parameters begin",
      "write the signature: `function(x: T): U`, and `function()` for a function with no parameters")
    return { kind = "TypeFunction", id = 0, first = first, last = S.pos - 1, typeparams = typeparams, params = params }
  end
  local open = S.pos
  advance()
  while S.text ~= ")" and S.kind ~= "$EOF$" do
    local pfirst = S.pos
    local name: string = nil
    local optional, variadic = false, false
    if S.text == "..." then
      advance()
      variadic = true
      expect(":", "after `...` in a parameter list", "write the type of the rest parameter: `...: any`")
    elseif S.text == "?" then
      report("optional_type", pfirst, "`? T` is not in the grammar: a parameter is made omittable by its name",
        "write `name?: T`, naming the parameter")
      advance()
      optional = true
    elseif S.kind == "identifier" and peek_text(1) == ":" then
      name = S.text
      advance()
      advance()
    elseif S.kind == "identifier" and peek_text(1) == "?" and peek_text(2) == ":" then
      name = S.text
      optional = true
      advance()
      advance()
      advance()
    end
    local t = parse_type()
    if S.text == "..." then
      report("variadic_type", S.pos, "`T...` is not in the grammar as the type of a parameter",
        "write the rest parameter `...: " .. quoted_text(base_of(t).first, base_of(t).last) .. "`")
      advance()
      variadic = true
    end
    table.insert(params, { kind = "PType", id = 0, first = pfirst, last = end_of(), name = name, optional = optional, variadic = variadic, type = t })
    if S.text == "," then
      advance()
      after_comma(")", "parameters")
    else
      break
    end
  end
  close(")", open, "parameter list")
  local rets: Ast.Rets = nil
  if S.text == ":" then
    advance()
    rets = parse_rets()
  end
  return { kind = "TypeFunction", id = 0, first = first, last = end_of(), typeparams = typeparams, params = params, rets = rets }
end

--- `{T}` or `{K: V}`, at the `{`.
local function parse_collection(): Ast.Type
  local open = S.pos
  advance()
  local first_type = parse_type()
  local node: Ast.Type
  if S.text == ":" then
    advance()
    local value = parse_type()
    node = { kind = "TypeMap", id = 0, first = open, last = S.pos, key = first_type, value = value }
  else
    if S.text == "," then
      report("tuple_type", S.pos, "a tuple type `{A, B}` is not in the grammar",
        "write a record with a field for each position, or `{A | B}` for an array of either")
      while S.text == "," do
        advance()
        parse_type()
      end
    end
    node = { kind = "TypeArray", id = 0, first = open, last = S.pos, element = first_type }
  end
  close("}", open, "collection type")
  base_of(node).last = S.pos - 1
  return node
end

parse_base = function(): Ast.Type
  local first = S.pos
  local t = S.text
  local k = S.kind
  if S.nesting >= MAX_NESTING then
    too_deep(first)
    return { kind = "TypeError", id = 0, first = first, last = S.pos - 1 }
  end
  S.nesting = S.nesting + 1
  local node = parse_base_inner(first, t, k)
  S.nesting = S.nesting - 1
  return node
end

parse_base_inner = function(first: integer, t: string, k: Lexer.Kind): Ast.Type
  if t == "{" then
    return parse_collection()
  elseif k == "identifier" then
    local path = parse_path()
    local args: {Ast.Type} = {}
    local last = S.pos - 1
    if S.text == "<" then
      local open = S.pos
      advance()
      args = parse_type_list()
      last = close_angle(open)
    end
    return { kind = "TypeName", id = 0, first = first, last = last, path = path, args = args }
  elseif t == "function" then
    return parse_function_type()
  elseif t == "mut" then
    advance()
    if S.text ~= "{" then
      report("mut_needs_collection", S.pos, "`mut` applies to an array or a map type, found " .. shown(S.pos) .. " after it",
        "write `mut {T}` or `mut {K: V}`; a field that is reassigned is `mut name: T`")
      local other = parse_base()
      return { kind = "TypeMut", id = 0, first = first, last = S.pos - 1, inner = other }
    end
    local inner = parse_collection()
    return { kind = "TypeMut", id = 0, first = first, last = S.pos - 1, inner = inner }
  elseif t == "nil" then
    advance()
    return { kind = "TypeNil", id = 0, first = first, last = first }
  elseif t == "true" or t == "false" then
    advance()
    return { kind = "TypeBool", id = 0, first = first, last = first, value = t == "true" }
  elseif t == "(" then
    advance()
    local inner = parse_type()
    close(")", first, "parenthesized type")
    return inner
  elseif k == "string" then
    report("string_literal_type", first, "a string is not a type: string-literal types are not in the grammar",
      "declare an `enum` of the strings and use its name as the type")
    advance()
  elseif k == "$ERR$" then
    advance()
  else
    report("expected_type", first, "expected a type, found " .. shown(S.pos),
      "write a type: a name like `string` or `Reader`, `{T}`, `{K: V}`, `function(x: T): U`, `nil`, `true` or `false`")
  end
  return { kind = "TypeError", id = 0, first = first, last = S.pos - 1 }
end

parse_type = function(): Ast.Type
  local first = S.pos
  return continue_type(first, parse_base())
end

--- The items of a return list that is not in parentheses, or of the part of one
--- inside them (`parens`, where a `,` always continues the list).
local function parse_rlist(parens: boolean): {Ast.RType}, boolean
  local items: mut {Ast.RType} = { parse_rtype() }
  while S.text == "," and (parens or not starts_parameter()) do
    advance()
    if parens and S.text == ")" then
      after_comma(")", "return values")
      break
    end
    items[#items + 1] = parse_rtype()
  end
  local variadic = false
  if S.text == "..." then
    variadic = true
    advance()
  end
  return items, variadic
end

parse_rets = function(): Ast.Rets
  local first = S.pos
  local lists: mut {{Ast.RType}} = {}
  local variadic = false
  if S.text == "(" then
    local open = S.pos
    advance()
    local items: {Ast.RType} = {}
    if S.text ~= ")" then
      items, variadic = parse_rlist(true)
    end
    close(")", open, "return list")
    local head = items[1]
    if S.text == "|" and peek_text(1) == "(" and not arm_bar(false) then
      lists[1] = items
      while S.text == "|" and not arm_bar(false) do
        advance()
        local o = S.pos
        local more: {Ast.RType} = {}
        if expect("(", "to begin the next list of a union of value lists", "write each list of the union in parentheses: `(true, R) | (false, E)`") then
          more = parse_rlist(true)
          close(")", o, "return list")
        end
        lists[#lists + 1] = more
      end
    elseif #items == 1 and not variadic and (S.text == "?" or (S.text == "|" and not arm_bar(false))) and not ((head.kind == "Narrows")) then
      lists[1] = { continue_type(open, head) }
    else
      lists[1] = items
    end
  else
    local items: {Ast.RType}
    items, variadic = parse_rlist(false)
    lists[1] = items
  end
  for _, list in ipairs(lists) do
    for _, item in ipairs(list) do
      if (item.kind == "Narrows") and (#lists > 1 or #list > 1 or variadic) then
        report("narrowing_return", item.first, "a narrowing return is the whole return list: `" .. quoted_text(item.first, item.last) .. "` stands with others",
          "write the narrowing alone, `v is T` or `asserts v is T`, and return the other values by another function")
      end
    end
  end
  return { kind = "Rets", id = 0, first = first, last = end_of(), lists = lists, variadic = variadic }
end

parse_typeparams = function(): {Ast.TypeParam}
  local open = S.pos
  advance()
  local list: mut {Ast.TypeParam} = {}
  while true do
    local first = S.pos
    local name = binding("a type parameter")
    local constraint: Ast.TypeName = nil
    if S.text == "is" then
      advance()
      local cfirst = S.pos
      local path = parse_path()
      constraint = { kind = "TypeName", id = 0, first = cfirst, last = S.pos - 1, path = path, args = {} }
    end
    list[#list + 1] = { kind = "TypeParam", id = 0, first = first, last = S.pos - 1, name = name, constraint = constraint }
    if S.text == "," then
      advance()
    else
      break
    end
  end
  close_angle(open)
  return list
end

-- expressions

local record Operator
  left: integer
  right: integer
  op: Ast.BinaryOp
end

--- The binary operators with their priorities, as Lua's: `..` and `^` bind
--- to the right, the others to the left.
local BINARY <const>: {string: Operator} = {
  ["or"] = { left = 1, right = 1, op = "or" }, ["and"] = { left = 2, right = 2, op = "and" },
  ["<"] = { left = 3, right = 3, op = "<" }, [">"] = { left = 3, right = 3, op = ">" },
  ["<="] = { left = 3, right = 3, op = "<=" }, [">="] = { left = 3, right = 3, op = ">=" },
  ["~="] = { left = 3, right = 3, op = "~=" }, ["=="] = { left = 3, right = 3, op = "==" },
  ["|"] = { left = 4, right = 4, op = "|" }, ["~"] = { left = 5, right = 5, op = "~" },
  ["&"] = { left = 6, right = 6, op = "&" }, ["<<"] = { left = 7, right = 7, op = "<<" },
  [">>"] = { left = 7, right = 7, op = ">>" }, [".."] = { left = 9, right = 8, op = ".." },
  ["+"] = { left = 10, right = 10, op = "+" }, ["-"] = { left = 10, right = 10, op = "-" },
  ["*"] = { left = 11, right = 11, op = "*" }, ["/"] = { left = 11, right = 11, op = "/" },
  ["//"] = { left = 11, right = 11, op = "//" }, ["%"] = { left = 11, right = 11, op = "%" },
  ["^"] = { left = 14, right = 13, op = "^" },
}

local UNARY <const>: {string: Ast.UnaryOp} = { ["not"] = "not", ["#"] = "#", ["-"] = "-", ["~"] = "~" }
local UNARY_PRIORITY <const> = 12

local parse_fn: function(open: integer, desc: string): Ast.Fn

--- The tokens, besides names and literals, an expression begins with.
local ITEM_START <const>: {string: boolean} = {
  ["("] = true, ["{"] = true, ["["] = true, ["-"] = true, ["#"] = true, ["~"] = true, ["not"] = true,
  ["nil"] = true, ["true"] = true, ["false"] = true, ["function"] = true, ["..."] = true, ["if"] = true,
}

local function parse_explist(): {Ast.Exp}
  local list: mut {Ast.Exp} = { parse_expression() }
  while S.text == "," do
    advance()
    list[#list + 1] = parse_expression()
  end
  return list
end

local function parse_args(): {Ast.Exp}
  local open = S.pos
  advance()
  local args: {Ast.Exp} = {}
  if S.text ~= ")" then
    args = parse_explist()
  end
  close(")", open, "call")
  return args
end

--- Whether the current token can begin an item of a table.
local function starts_item(): boolean
  local k = S.kind
  return k == "identifier" or k == "string" or k == "integer" or k == "number" or ITEM_START[S.text] == true or
    (is_field_word() and peek_text(1) == "=")
end

local function parse_table(): Ast.Exp
  local open = S.pos
  advance()
  S.tables = S.tables + 1
  local items: mut {Ast.Item} = {}
  while S.text ~= "}" and S.kind ~= "$EOF$" do
    local first = S.pos
    if S.text == "[" then
      advance()
      local key = parse_expression()
      close("]", first, "key")
      expect("=", "after a table key", "write `[key] = value`")
      local value = parse_expression()
      items[#items + 1] = { kind = "Keyed", id = 0, first = first, last = S.pos - 1, key = key, value = value }
    elseif is_field_word() and peek_text(1) == "=" then
      local name = S.text
      advance()
      advance()
      local value = parse_expression()
      items[#items + 1] = { kind = "Named", id = 0, first = first, last = S.pos - 1, name = name, value = value }
    else
      if S.text == "..." and peek_kind(1) == "identifier" then
        local spread = peek_text(1)
        report("unexpected_token", S.pos, "a table constructor has no spread yet: `..." .. spread .. "` is not a field",
          "write each field of `" .. spread .. "` in the constructor: `{ a = " .. spread .. ".a, b = " .. spread .. ".b, c = 2 }`")
        advance()
      end
      local value = parse_expression()
      items[#items + 1] = { kind = "Positional", id = 0, first = first, last = S.pos - 1, value = value }
    end
    if S.text == "," then
      advance()
    elseif S.text ~= "}" and begins_line(S.pos) and starts_item() then
      report("expected_token", S.pos, "expected `,` or `}` after the item on line " .. (S.yends[S.pos - 1] or S.ys[S.pos - 1]) .. ", found " .. shown(S.pos),
        "add a `,` at the end of the item before it; the items of a table are separated by `,`")
    else
      break
    end
  end
  S.tables = S.tables - 1
  close("}", open, "table")
  return { kind = "Table", id = 0, first = open, last = S.pos - 1, items = items }
end

local function parse_if_expression(): Ast.Exp
  local first = S.pos
  advance()
  local arms: mut {Ast.ExpArm} = {}
  while true do
    local afirst = S.pos
    local cond = parse_expression()
    expect("then", "after the condition of an `if` expression", "write `if cond then a else b end`")
    local value = parse_expression()
    arms[#arms + 1] = { kind = "ExpArm", id = 0, first = afirst, last = S.pos - 1, cond = cond, value = value }
    if S.text == "elseif" then
      advance()
    else
      break
    end
  end
  local else_value: Ast.Exp
  if S.text == "else" then
    advance()
    else_value = parse_expression()
  else
    report("if_needs_else", S.pos, "an `if` expression has no `else`: found " .. shown(S.pos),
      "write `else <value>` before `end`; to run statements on a condition, write an `if` statement")
    else_value = { kind = "Error", id = 0, first = S.pos, last = S.pos - 1 }
  end
  close("end", first, "`if` expression")
  return { kind = "IfExp", id = 0, first = first, last = S.pos - 1, arms = arms, else_value = else_value }
end

local function parse_primary(): Ast.Exp
  local first = S.pos
  local k = S.kind
  if k == "identifier" then
    local text = S.text
    advance()
    if text == "require" then
      S.require_names[first] = false
    end
    return { kind = "Name", id = 0, first = first, last = first, text = text }
  elseif k == "string" then
    local at = S.pos
    advance()
    return { kind = "String", id = 0, first = first, last = first, value = assert(S.tokens.value[at]), long = Lexer.long(S.tokens, at) }
  elseif k == "integer" then
    local number = S.tokens.number[S.pos]
    advance()
    return { kind = "Integer", id = 0, first = first, last = first, value = assert(math.tointeger(number)) }
  elseif k == "number" then
    local number = S.tokens.number[S.pos]
    advance()
    return { kind = "Float", id = 0, first = first, last = first, value = assert(number) }
  end
  local t = S.text
  if t == "(" then
    advance()
    local inner = parse_expression()
    close(")", first, "parenthesis")
    return { kind = "Paren", id = 0, first = first, last = S.pos - 1, inner = inner }
  elseif t == "{" then
    return parse_table()
  elseif t == "nil" then
    advance()
    return { kind = "Nil", id = 0, first = first, last = first }
  elseif t == "true" or t == "false" then
    advance()
    return { kind = "Boolean", id = 0, first = first, last = first, value = t == "true" }
  elseif t == "..." then
    advance()
    return { kind = "Vararg", id = 0, first = first, last = first }
  elseif t == "function" then
    advance()
    if S.text == "<" then
      report("generic_function_literal", S.pos, "a function literal takes no type parameters",
        "declare a generic function with `local function f<T>(...)`, or write the literal without `<T>`")
      parse_typeparams()
    end
    local fn = parse_fn(first, "`function`")
    return { kind = "FunctionLit", id = 0, first = first, last = S.pos - 1, fn = fn }
  elseif t == "if" then
    return parse_if_expression()
  elseif k == "$ERR$" then
    advance()
  elseif k == "keyword" and RESERVED_NAME[t] == true then
    report("reserved_word", first, "`" .. t .. "` is a reserved word and cannot name a variable or a function",
      "rename what is called `" .. t .. "`, for example `" .. (RENAME[t] or t .. "_") ..
        "`; `" .. t .. "` stays legal as a field name: `t." .. t .. "`, `s:" .. t .. "(x)`")
    advance()
    return { kind = "Name", id = 0, first = first, last = first, text = t }
  else
    report("expected_expression", first, "expected an expression, found " .. shown(S.pos),
      "write a value: a name, a number, a string, `nil`, `true`, `false`, a table `{ ... }`, a call, or `function(...) ... end`")
  end
  return error_node(first)
end

--- Whether `e` is the name `text`, written as a single token.
local function is_name(e: Ast.Exp, text: string): boolean
  return e.kind == "Name" and S.texts[e.first] == text
end

--- Whether the `i`th of `list` is the name `text`.
local function arg_is_name(list: {Ast.Exp}, i: integer, text: string): boolean
  local e = list[i]
  return e ~= nil and is_name(e, text)
end

--- The contents of the `i`th of `list` where it is a string literal, nil where it is anything else.
local function literal_at(list: {Ast.Exp}, i: integer): string?
  local e = list[i]
  if e == nil then
    return nil
  end
  local from, to = e.first, e.last
  if e.kind == "Paren" then
    while S.texts[from] == "(" and S.texts[to] == ")" and from < to do
      from, to = from + 1, to - 1
    end
  end
  if from ~= to or S.kinds[from] ~= "string" then
    return nil
  end
  local contents = S.tokens.value[from]
  return contents
end

--- Reports the `i`th of `args`, the name that a `require` is given, written `how` (`require` or `pcall`) and that is
--- no string literal: the build reads a module's dependencies from literal names alone.
local function report_computed_require(args: {Ast.Exp}, i: integer, how: string)
  local e = args[i]
  if e == nil then
    return
  end
  local base = base_of(e)
  local text = quoted_text(base.first, base.last)
  local call = if how == "pcall" then "pcall(require, " .. text .. ")" else "require(" .. text .. ")" end
  local literal = if how == "pcall" then "pcall(require, \"cosmic.fs\")" else "require(\"cosmic.fs\")" end
  report("computed_require", base.first,
    "`" .. call .. "` names its module by an expression, and the build follows a require by a literal name alone, so " ..
      "it cannot tell which module this one needs: a change to that module would not run this one's tests again, " ..
      "a program sealed or built from this one would not carry it, and `cosmic test` refuses the call when it runs",
    "write the module's name as a string: `" .. literal .. "`; to choose between modules, require each by its " ..
      "literal name and pick from a table: `local by_name = { csv = require(\"cosmic.csv\"), json = " ..
      "require(\"cosmic.json\") }`, then `by_name[" .. text .. "]`")
end

--- Records a call of `require` with one literal string, or of `pcall(require, "m")`, for the chunk's list. A
--- `pcall(require, "m")` probes a module that may be absent and is a dependency all the same: it is carried and keyed
--- as a `require("m")` is. A name that is no literal is an error ([`report_computed_require`]).
-- TODO: refuse a `require` that a local shadows, which this reads as the global, once the scope builder reports a use of
-- the global `require` (lang/scopes.tl): until then a shadowing function is held to the same rules as the global.
local function note_require(call: Ast.Call)
  local callee, args = call.callee, call.args
  local at = 0
  local how = "require"
  if is_name(callee, "require") then
    at = 1
    S.require_names[base_of(callee).first] = true
  elseif is_name(callee, "pcall") and arg_is_name(args, 1, "require") then
    at = 2
    how = "pcall"
    local first = args[1]
    if first ~= nil then
      S.require_names[base_of(first).first] = true
    end
  end
  if at == 0 or #args < at then
    return
  end
  local module = literal_at(args, at)
  if module ~= nil then
    S.requires[#S.requires + 1] = { module = module, node = 0 }
    S.require_nodes[#S.require_nodes + 1] = call
  else
    report_computed_require(args, at, how)
  end
end

local SUFFIX <const>: {string: boolean} = { ["."] = true, ["["] = true, [":"] = true, ["("] = true, ["{"] = true }

--- A name, a parenthesized expression, or one of those with its suffixes:
--- `.name`, `[key]`, `:name(args)` and calls. A `(` that begins a line
--- begins a statement, not a call. Any other expression takes no suffix, as in
--- Lua; one that is followed by one is refused, and the suffix parsed on.
parse_prefix = function(): Ast.Exp
  local first = S.pos
  local e = parse_primary()
  local prefix = e.kind == "Name" or e.kind == "Paren" or e.kind == "Error"
  while true do
    local t = S.text
    if S.tables > 0 and (t == "{" or S.kind == "string") and begins_line(S.pos) then
      -- The next item of a table, whose `,` is missing, and no argument.
      break
    end
    if not prefix and (SUFFIX[t] == true or S.kind == "string") and (t ~= "(" or same_line(S.pos)) then
      local shown_text = quoted_text(first, S.pos - 1)
      report("suffix_needs_parens", S.pos, "`" .. shown_text .. "` takes no `" .. t .. "` suffix: only a name or a parenthesized expression does",
        "write `(" .. shown_text .. ")` and then the suffix")
      prefix = true
    end
    if t == "." then
      advance()
      local name = field_name()
      e = { kind = "Field", id = 0, first = first, last = S.pos - 1, object = e, name = name }
    elseif t == "[" then
      local open = S.pos
      advance()
      local key = parse_expression()
      close("]", open, "index")
      e = { kind = "Index", id = 0, first = first, last = S.pos - 1, object = e, key = key }
    elseif t == ":" then
      advance()
      local name_at = S.pos
      local name = field_name()
      if name == "goto" or name == "global" then
        report("reserved_method", name_at, "`" .. name .. "` is a reserved word in Lua 5.5 and cannot be called as a method",
          "call it as a field of the object: `obj[\"" .. name .. "\"](obj, ...)`, or rename the method")
      end
      local args: {Ast.Exp}
      if S.text == "(" and same_line(S.pos) then
        args = parse_args()
      elseif S.text == "{" then
        args = { parse_table() }
      elseif S.kind == "string" then
        report("string_call", S.pos, "a call with a string in place of its arguments is not in the grammar",
          "put the string in parentheses: `obj:" .. name .. "(" .. S.text .. ")`")
        local at = S.pos
        advance()
        args = { { kind = "String", id = 0, first = at, last = at, value = assert(S.tokens.value[at]), long = Lexer.long(S.tokens, at) } }
      else
        report("expected_token", S.pos, "expected the arguments of the call `:" .. name .. "`, found " .. shown(S.pos),
          "write the call's arguments in parentheses: `obj:" .. name .. "(x)`")
        args = {}
      end
      e = { kind = "MethodCall", id = 0, first = first, last = S.pos - 1, object = e, name = name, args = args }
    elseif t == "(" then
      if begins_line(S.pos) then
        break
      end
      local args = parse_args()
      local call: Ast.Call = { kind = "Call", id = 0, first = first, last = S.pos - 1, callee = e, args = args }
      note_require(call)
      e = call
    elseif t == "{" then
      local table_arg = parse_table()
      e = { kind = "Call", id = 0, first = first, last = S.pos - 1, callee = e, args = { table_arg } }
    elseif S.kind == "string" then
      report("string_call", S.pos, "a call with a string in place of its arguments is not in the grammar",
        "put the string in parentheses: `f(" .. S.text .. ")`")
      if is_name(e, "require") then
        S.require_names[base_of(e).first] = true
      end
      local at = S.pos
      advance()
      local string_arg: Ast.String = {
        kind = "String", id = 0, first = at, last = at, value = assert(S.tokens.value[at]), long = Lexer.long(S.tokens, at),
      }
      e = { kind = "Call", id = 0, first = first, last = S.pos - 1, callee = e, args = { string_arg } }
    else
      break
    end
  end
  return e
end

--- `e`, a prefix expression that began at `first`, with a trailing `is T`, or
--- any number of `as T`: the tree writes `e as any as T` as often as `e as T`.
local function finish_postfix(first: integer, e: Ast.Exp): Ast.Exp
  if S.text == "is" then
    advance()
    local tfirst = S.pos
    local ty = parse_base()
    if S.text == "|" or S.text == "?" then
      report("is_union", S.pos, "`is` takes one type, found " .. shown(S.pos) .. " after it",
        "test each type apart: `x is A or x is B`; for a value that may be nil write `x ~= nil and x is A`")
      ty = continue_type(tfirst, ty)
    end
    settle()
    local test: Ast.IsTest = { kind = "IsTest", id = 0, first = first, last = S.pos - 1, value = e, type = ty }
    if S.text == "is" then
      report("chained_is", S.pos, "`is` does not chain: `a is B is C` tests a boolean",
        "test each apart: `a is B and a is C`")
      advance()
      parse_base()
      settle()
      test.last = S.pos - 1
    end
    return test
  end
  while S.text == "as" do
    advance()
    local ty = parse_annotation()
    e = { kind = "Cast", id = 0, first = first, last = S.pos - 1, value = e, type = ty }
  end
  return e
end

local function subexpression(limit: integer): Ast.Exp
  local first = S.pos
  local depth = S.nesting
  if depth >= MAX_NESTING then
    return too_deep(first)
  end
  S.nesting = depth + 1
  local left: Ast.Exp
  local unary = UNARY[S.text]
  if unary ~= nil then
    advance()
    local operand = subexpression(UNARY_PRIORITY)
    left = { kind = "Unary", id = 0, first = first, last = S.pos - 1, op = unary, operand = operand }
  else
    left = parse_prefix()
    if S.text == "is" or S.text == "as" then
      left = finish_postfix(first, left)
    end
  end
  while true do
    local entry = BINARY[S.text]
    if entry == nil or entry.left <= limit or (S.arms > 0 and arm_bar(true)) then
      S.nesting = depth
      return left
    end
    advance()
    local right = subexpression(entry.right)
    left = { kind = "Binary", id = 0, first = first, last = S.pos - 1, op = entry.op, left = left, right = right }
  end
end

parse_expression = function(): Ast.Exp
  return subexpression(0)
end

-- functions

--- The parameters up to the `)`: `name`, `name?`, `name: T`, `name?: T` and
--- `...: T`.
local function parse_params(): {Ast.Param}
  local list: mut {Ast.Param} = {}
  while S.text ~= ")" and S.kind ~= "$EOF$" do
    local first = S.pos
    if S.text == "..." then
      advance()
      expect(":", "after `...`", "write the type of the rest parameter: `...: any`")
      local t = parse_annotation()
      list[#list + 1] = { kind = "Param", id = 0, first = first, last = end_of(), optional = false, variadic = true, type = t }
    else
      local name = binding("a parameter")
      local optional = false
      if S.text == "?" then
        optional = true
        advance()
      end
      local t: Ast.Type = nil
      if S.text == ":" then
        advance()
        t = parse_annotation()
      end
      list[#list + 1] = { kind = "Param", id = 0, first = first, last = end_of(), name = name, optional = optional, variadic = false, type = t }
    end
    if S.text == "," then
      advance()
      after_comma(")", "parameters")
    else
      break
    end
  end
  return list
end

--- A block that is the body of a function: `continue` and `break` in it
--- are the function's own, and a declaration file has none.
local function parse_body(open: integer, desc: string): Ast.Block
  if S.decl then
    report("body_in_declaration", open, "a declaration file has no function bodies",
      "declare the function's type: `name: function(x: T): U`")
  end
  local saved = S.loop_base
  S.loop_base = #S.loops
  local body = parse_block(0)
  S.loop_base = saved
  close_block(body, "end", open, desc)
  return body
end

--- The rest of a function from its `(`: parameters, return list and body.
--- `open` is the token of the keyword that opened it.
parse_fn = function(open: integer, desc: string): Ast.Fn
  local first = S.pos
  local arms, tables = S.arms, S.tables
  S.arms, S.tables = 0, 0
  local params: {Ast.Param} = {}
  local rets: Ast.Rets = nil
  if expect("(", "to begin the parameters", "write the parameters in parentheses: `function(x: T)`") then
    params = parse_params()
    close(")", first, "parameter list")
    if S.text == ":" then
      advance()
      rets = parse_rets()
      settle()
    end
  end
  local body = parse_body(open, desc)
  S.arms, S.tables = arms, tables
  return { kind = "Fn", id = 0, first = first, last = S.pos - 1, params = params, rets = rets, body = body }
end

-- declarations

--- Whether a field of this name is declared again, with each declaration's
--- type a function type only in a declaration file (the overloads).
local function is_duplicate(seen: mut {string: boolean}, name: string, t: Ast.Type): boolean
  local is_function = t.kind == "TypeFunction"
  local before = seen[name]
  seen[name] = is_function and (before == nil or before)
  if before == nil then
    return false
  end
  return not (S.decl and is_function and before)
end

local function parse_field(first: integer, seen: {string: boolean}): Ast.Member
  local mutable = false
  local nxt = peek_text(1)
  if S.text == "mut" and nxt ~= ":" and nxt ~= "?" then
    mutable = true
    advance()
  end
  local nfirst = S.pos
  local name: Ast.Binding
  if S.text == "[" then
    advance()
    local key_at = S.pos
    if S.kind == "string" then
      advance()
    else
      report("expected_name", S.pos, "expected a string between `[` and `]`, found " .. shown(S.pos),
        "write the field's name as a string: `[\"end\"]: T`")
    end
    close("]", nfirst, "field name")
    name = { kind = "Binding", id = 0, first = nfirst, last = S.pos - 1, name = S.tokens.value[key_at] or "" }
  elseif is_field_word() then
    name = { kind = "Binding", id = 0, first = nfirst, last = nfirst, name = S.text }
    advance()
  else
    local fix = "write `name: Type` for a field, `function name(self) ... end` for a method of a class, or `end` to close the body"
    if S.kind == "keyword" and (peek_text(1) == ":" or peek_text(1) == "?") then
      fix = "a field named by a keyword is declared and indexed as `[\"" .. S.text .. "\"]`: write `[\"" .. S.text ..
        "\"]: T` in the declaration and `t[\"" .. S.text .. "\"]` to read it"
    end
    report("expected_name", S.pos, "expected a field name, found " .. shown(S.pos), fix)
    name = { kind = "Binding", id = 0, first = nfirst, last = nfirst - 1, name = "" }
  end
  local omittable = false
  if S.text == "?" then
    omittable = true
    advance()
  end
  local t: Ast.Type
  if expect(":", "after the field name `" .. name.name .. "`", "write the field's type: `" .. name.name .. ": T`") or
      same_line(S.pos) then
    t = parse_annotation()
  else
    t = { kind = "TypeError", id = 0, first = S.pos, last = S.pos - 1 }
  end
  if name.name ~= "" and is_duplicate(seen, name.name, t) then
    report("duplicate_field", nfirst, "the field `" .. name.name .. "` is declared twice",
      if S.decl then "delete one, or give both a function type to declare overloads" else
        "delete one; overloads, which repeat a function-typed field, are declared in a declaration file" end)
  end
  return { kind = "FieldDecl", id = 0, first = first, last = end_of(), name = name, mut = mutable, omittable = omittable, type = t, doc = doc_of(first) }
end

local function parse_method(first: integer, seen: mut {string: boolean}): Ast.Member
  local arms, tables = S.arms, S.tables
  S.arms, S.tables = 0, 0
  advance()
  local pathed = false
  if S.kind == "identifier" and (peek_text(1) == ":" or peek_text(1) == ".") then
    pathed = true
    local owner, separator, method = S.text, peek_text(1), peek_text(2)
    report("method_path", S.pos, "a method is named by its own name inside its class: `" .. owner .. separator .. method .. "` names its class",
      "write `function " .. method .. "(self, ...)`: drop `" .. owner .. separator .. "` and write `self` as the first parameter")
    advance()
    advance()
  end
  local name = binding("a method")
  if name.name ~= "" then
    local declares_type = seen[name.name] == true and seen["\0method " .. name.name] ~= true
    if seen[name.name] ~= nil then
      report("duplicate_field", name.first, "the name `" .. name.name .. "` is declared twice in the class",
        if declares_type then
          "delete the field and write its parameter and return types on the method; the receiver is `self`, so a field " ..
            "`function(R, integer)` is `function " .. name.name .. "(self, x: integer)`" else
          "rename or delete one; a method and a field, or two methods, cannot share a name" end)
    end
    seen["\0method " .. name.name] = true
    seen[name.name] = false
  end
  local open = S.pos
  local params: {Ast.Param} = {}
  local rets: Ast.Rets = nil
  if expect("(", "to begin the parameters of the method", "write `function name(self, ...)`") then
    params = parse_params()
    close(")", open, "parameter list")
    local p = params[1]
    local p_name = p and p.name
    if not pathed and (p == nil or p_name == nil or p_name.name ~= "self" or p.type ~= nil) then
      report("method_needs_self", open, "the first parameter of a method is `self`, written without a type",
        "write `function " .. name.name .. "(self" .. (if #params > 0 then ", ..." else "" end) .. ")`")
    end
    if S.text == ":" then
      advance()
      rets = parse_rets()
      settle()
    end
  end
  local body = parse_body(first, "method `" .. name.name .. "`")
  S.arms, S.tables = arms, tables
  return { kind = "Method", id = 0, first = first, last = S.pos - 1, name = name, params = params, rets = rets, body = body, doc = doc_of(first) }
end

local OLD_BODY <const>: {string: boolean} = { record = true, interface = true, enum = true, class = true }

--- The tokens that continue a type, which keep a name such as `record` a type.
local CONTINUES_TYPE <const>: {string: boolean} = { ["."] = true, ["<"] = true, ["|"] = true, ["?"] = true }

local type Decl = Ast.Record | Ast.Interface | Ast.Class | Ast.Enum | Ast.TypeAlias | Ast.Import

local parse_typedecl: function(first: integer, scope: Ast.Scope?): Decl

--- Whether the current token names a field, which a `:` or a `?:` after it shows.
local function names_a_field(): boolean
  local nxt = peek_text(1)
  return is_field_word() and (nxt == ":" or (nxt == "?" and peek_text(2) == ":"))
end

local STATEMENT_START <const>: {string: boolean} = {
  ["local"] = true, ["global"] = true, ["if"] = true, ["while"] = true, ["for"] = true, ["repeat"] = true,
  ["do"] = true, ["return"] = true, ["break"] = true, ["continue"] = true, ["match"] = true, ["until"] = true,
  ["else"] = true, ["elseif"] = true,
}

--- Whether the current token begins a statement where the body of the
--- declaration that began at `open` ended without its `end`: a keyword no
--- member begins with, at the head of a line, or a `function` with a dotted
--- name that is no deeper than the declaration.
local function begins_statement(open: integer): boolean
  local t = S.text
  if S.kind ~= "keyword" or not begins_line(S.pos) or names_a_field() then
    return false
  elseif t == "function" then
    if peek_kind(1) ~= "identifier" or (peek_text(2) ~= "." and peek_text(2) ~= ":") then
      return false
    end
    local at = open
    while at > 1 and (S.yends[at - 1] or S.ys[at - 1]) == S.ys[open] do
      at = at - 1
    end
    return Lexer.x(S.tokens, S.pos) <= Lexer.x(S.tokens, at)
  end
  return STATEMENT_START[t] == true
end

--- One member of a `record`, `interface` or `class` body (`owner`).
local function parse_member(owner: string, seen: {string: boolean}): Ast.Member
  local first = S.pos
  local t = S.text
  local nxt_kind, nxt_text = peek_kind(1), peek_text(1)
  if names_a_field() then
    return parse_field(first, seen)
  elseif t == "userdata" then
    advance()
    if not S.decl or owner ~= "record" then
      report("userdata_in_program", first, "`userdata` marks a record of a declaration file",
        "delete it; a program's types are tables, and a userdata type is declared in a `.d.tl` file")
    end
    return { kind = "Userdata", id = 0, first = first, last = first }
  elseif t == "function" then
    if owner ~= "class" then
      report("method_in_record", first, (if owner == "interface" then "an " else "a " end) .. owner .. " holds fields only and cannot have a method with a body",
        if owner == "record" then "write `class` in place of `record`: a class holds its methods, `function name(self, ...) ... end`" else
          "declare the method as a field: `name: function(self: I, ...): T`" end)
    end
    return parse_method(first, seen)
  elseif S.kind == "identifier" and DECL_WORD[t] == true and nxt_kind == "identifier" then
    if owner == "interface" then
      report("nested_in_interface", first, "an interface holds fields only and cannot declare a `" .. t .. "` inside it",
        "declare the `" .. t .. "` before the interface, and name it in the type of a field")
    end
    return parse_typedecl(first, nil)
  elseif S.kind == "identifier" and t == "metamethod" and nxt_kind == "identifier" then
    report("metamethod", first, "`metamethod` is not in the grammar",
      "write the field without it: `" .. nxt_text .. ": function(self: T)`, or a method `function " .. nxt_text .. "(self)` of a class")
    advance()
  end
  return parse_field(first, seen)
end

--- The members up to the `end` that closes the declaration opened at `open`,
--- or up to a statement that begins a line: a body that is not closed ends
--- there, as `desc` is reported not closed.
local function parse_members(owner: string, open: integer, desc: string): {Ast.Member}
  local members: mut {Ast.Member} = {}
  local seen: {string: boolean} = {}
  while S.text ~= "end" and S.kind ~= "$EOF$" and not begins_statement(open) do
    local before = S.pos
    local member = parse_member(owner, seen)
    if S.pos == before then
      member = skip_junk(before, true)
    end
    members[#members + 1] = member
  end
  close("end", open, desc)
  return members
end

--- The `is` of a declaration: one or, for an interface, several supertypes.
local function parse_supers(owner: string): {Ast.TypeName}, Ast.Type
  local supers: mut {Ast.TypeName} = {}
  local array: Ast.Type = nil
  if S.text ~= "is" then
    return supers, array
  end
  advance()
  if S.text == "{" and owner == "record" then
    array = parse_collection()
    return supers, array
  end
  while true do
    local first = S.pos
    local path = parse_path()
    local args: {Ast.Type} = {}
    local last = S.pos - 1
    if S.text == "<" then
      local open = S.pos
      advance()
      args = parse_type_list()
      last = close_angle(open)
    end
    supers[#supers + 1] = { kind = "TypeName", id = 0, first = first, last = last, path = path, args = args }
    if S.text == "," and owner == "interface" then
      advance()
    else
      break
    end
  end
  if S.text == "," then
    report("several_supers", S.pos, (if owner == "interface" then "an " else "a " end) .. owner .. " implements one interface",
      "write one interface after `is`; a new interface that extends both can be implemented instead")
    while S.text == "," do
      advance()
      parse_path()
    end
  end
  return supers, array
end

--- The rest of a declaration of `word` (`record`, `interface`, `class` or
--- `enum`) called `name`, which began at the token `first` and whose word is
--- the token `at`.
local function parse_declaration_body(word: string, first: integer, at: integer, scope: Ast.Scope?,
                                      name: Ast.Binding): Decl
  local desc = "`" .. word .. " " .. name.name .. "`"
  if word == "enum" then
    local values: mut {Ast.EnumValue} = {}
    while S.text ~= "end" and S.kind ~= "$EOF$" and not begins_statement(at) do
      local vfirst = S.pos
      if S.kind == "string" then
        values[#values + 1] = { kind = "EnumValue", id = 0, first = vfirst, last = vfirst, value = S.tokens.value[S.pos], doc = doc_of(vfirst) }
        advance()
      else
        report("expected_token", S.pos, "expected a string of the enum `" .. name.name .. "`, found " .. shown(S.pos),
          "write each value as a string: `\"name\"`, and `end` after the last")
        while S.kind ~= "string" and S.text ~= "end" and S.kind ~= "$EOF$" and not begins_statement(at) do
          advance()
        end
      end
    end
    close("end", at, desc)
    return { kind = "Enum", id = 0, first = first, last = S.pos - 1, scope = scope, name = name, values = values }
  end
  local typeparams: {Ast.TypeParam} = {}
  if S.text == "<" then
    typeparams = parse_typeparams()
  end
  local supers, array = parse_supers(word)
  local members = parse_members(word, at, desc)
  if word == "record" then
    return { kind = "Record", id = 0, first = first, last = S.pos - 1, scope = scope, name = name, typeparams = typeparams, supers = supers, array = array, members = members }
  elseif word == "interface" then
    return { kind = "Interface", id = 0, first = first, last = S.pos - 1, scope = scope, name = name, typeparams = typeparams, supers = supers, members = members }
  end
  return { kind = "Class", id = 0, first = first, last = S.pos - 1, scope = scope, name = name, typeparams = typeparams, supers = supers, members = members }
end

parse_typedecl = function(first: integer, scope: Ast.Scope?): Decl
  local word = S.text
  local at = S.pos
  advance()
  local name = binding("a type")
  name.doc = doc_of(first)
  if word == "record" or word == "interface" or word == "class" or word == "enum" then
    return parse_declaration_body(word, first, at, scope, name)
  end
  local typeparams: {Ast.TypeParam} = {}
  if S.text == "<" then
    typeparams = parse_typeparams()
  end
  expect("=", "after the name of the type `" .. name.name .. "`", "write `type " .. name.name .. " = T`")
  if S.kind == "identifier" and OLD_BODY[S.text] == true and CONTINUES_TYPE[peek_text(1)] ~= true then
    local body_word = S.text
    report("old_type_declaration", S.pos, "`type " .. name.name .. " = " .. body_word .. "` is not in the grammar: " ..
        (if body_word == "enum" then "an " else "a " end) .. body_word .. " is declared with its own word",
      "write `" .. (scope or "local") .. " " .. body_word .. " " .. name.name .. " ... end`")
    local body_at = S.pos
    advance()
    return parse_declaration_body(body_word, first, body_at, scope, name)
  end
  if S.text == "require" and peek_text(1) == "(" then
    advance()
    local open = S.pos
    advance()
    local module = ""
    if S.kind == "string" then
      module = S.tokens.value[S.pos]
      advance()
    else
      report("expected_token", S.pos, "expected the module name as a string, found " .. shown(S.pos),
        "write the module's name: `require(\"cosmic.fs\")`")
    end
    close(")", open, "call")
    local node: Ast.Import = { kind = "Import", id = 0, first = first, last = S.pos - 1, scope = scope, name = name, module = module }
    S.requires[#S.requires + 1] = { module = module, node = 0 }
    S.require_nodes[#S.require_nodes + 1] = node
    return node
  end
  local t = parse_annotation()
  return { kind = "Alias", id = 0, first = first, last = end_of(), scope = scope, name = name, typeparams = typeparams, type = t }
end

-- statements

local PLAIN_LOOP <const>: Loop = { repeat_loop = false, depth = 0, continue_at = 0, after = {}, after_at = 0 }

--- Notes the names that the statement at the token `at` declares at the
--- level of a `repeat` body after a `continue`: Lua cannot jump into the scope of
--- one, since the `until` is inside it.
local function declared(names: {string}, at: integer)
  local top = S.loops[#S.loops]
  if top ~= nil and top.repeat_loop and top.continue_at > 0 and #S.loops > S.loop_base and S.depth == top.depth then
    if top.after_at == 0 then
      top.after_at = at
    end
    for _, n in ipairs(names) do
      top.after[#top.after + 1] = n
    end
  end
end

local function parse_local_binding(what: string): Ast.Binding
  local b = binding(what)
  if S.text == "<" and peek_kind(1) == "identifier" and peek_text(2) == ">" then
    local attr = peek_text(1)
    if attr == "const" or attr == "close" then
      b.attr = attr
    else
      report("bad_attribute", S.pos + 1, "`<" .. attr .. ">` is not an attribute of a local",
        "write `<const>` for a local that is not reassigned or `<close>` for one that is closed at the end of its block")
    end
    advance()
    advance()
    advance()
    b.last = S.pos - 1
  end
  return b
end

local function parse_local(): Ast.Stat
  local first = S.pos
  local scope: Ast.Scope = if S.text == "global" then "global" else "local" end
  advance()
  if scope == "global" and not S.decl then
    report("global_in_program", first, "`global` declares a global, which only a declaration file does",
      "write `local`; a program's globals are exactly the ones a declaration file (`.d.tl`) declares")
  end
  if S.text == "function" and scope == "local" then
    local ffirst = S.pos
    advance()
    local name = binding("a function")
    name.doc = doc_of(first)
    declared({ name.name }, first)
    local typeparams: {Ast.TypeParam} = {}
    if S.text == "<" then
      typeparams = parse_typeparams()
    end
    local fn = parse_fn(ffirst, "function `" .. name.name .. "`")
    return { kind = "LocalFunction", id = 0, first = first, last = S.pos - 1, name = name, typeparams = typeparams, fn = fn }
  elseif S.kind == "identifier" and DECL_WORD[S.text] == true and peek_kind(1) == "identifier" then
    local decl = parse_typedecl(first, scope)
    -- A class, a record and an import are values in the Lua written for them.
    if (decl.kind == "Class") or (decl.kind == "Record") or (decl.kind == "Import") then
      declared({ decl.name.name }, first)
    end
    return decl
  end
  local head_binding = parse_local_binding("a local")
  local bindings: mut {Ast.Binding} = { head_binding }
  local closing = head_binding.attr == "close"
  while S.text == "," do
    advance()
    local at = S.pos
    local each = parse_local_binding("a local")
    if each.attr == "close" then
      if closing then
        report("close_repeated", at, "`" .. each.name .. "` is a second `<close>` local of one declaration, which Lua 5.4 refuses",
          "declare each `<close>` local in a statement of its own")
      end
      closing = true
    end
    bindings[#bindings + 1] = each
  end
  bindings[1].doc = doc_of(first)
  local types: {Ast.Type} = {}
  if S.text == ":" then
    advance()
    types = parse_type_list()
    settle()
  end
  local values: {Ast.Exp} = {}
  if S.text == "=" then
    advance()
    values = parse_explist()
  end
  local names: mut {string} = {}
  for i, b in ipairs(bindings) do
    names[i] = b.name
  end
  declared(names, first)
  return { kind = "Local", id = 0, first = first, last = S.pos - 1, scope = scope, bindings = bindings, types = types, values = values }
end

--- `function R.m(...)`; the colon form, a global and a longer path are refused.
local function parse_function_statement(): Ast.Stat
  local first = S.pos
  advance()
  local path: mut {Ast.Name} = {}
  local colon = false
  while true do
    local nfirst = S.pos
    local text = S.text
    if S.kind == "identifier" or (#path > 0 and is_field_word()) then
      advance()
      path[#path + 1] = { kind = "Name", id = 0, first = nfirst, last = nfirst, text = text }
    else
      report("expected_name", nfirst, "expected a name after `function`, found " .. shown(S.pos),
        "write `local function name(...)`, or `function Type.name(...)` for a function of a declared type")
      break
    end
    if S.text == "." then
      advance()
    elseif S.text == ":" then
      colon = true
      advance()
    else
      break
    end
  end
  local joined = path[1] and path[1].text or ""
  if colon then
    local method = path[#path] and path[#path].text or "m"
    report("method_in_record", first, "`" .. quoted_text(first, S.pos - 1) .. "` is not in the grammar: a method is declared in its class",
      "declare it inside its class as `function " .. method .. "(self, ...)`")
  elseif #path == 1 then
    report("bare_function", first, "`function " .. joined .. "(...)` declares a global",
      "write `local function " .. joined .. "(...)`; a program's globals are the ones a declaration file declares")
  elseif #path > 2 then
    local parts: mut {string} = {}
    for i, n in ipairs(path) do
      parts[i] = n.text
    end
    report("function_path", first, "`function " .. table.concat(parts, ".") .. "` has more than one dot",
      "assign the function to the field: `" .. table.concat(parts, ".") .. " = function(...) ... end`")
  end
  local typeparams: {Ast.TypeParam} = {}
  if S.text == "<" then
    typeparams = parse_typeparams()
  end
  local fn = parse_fn(first, "`function`")
  return { kind = "Function", id = 0, first = first, last = S.pos - 1, path = path, typeparams = typeparams, fn = fn, doc = doc_of(first) }
end

--- Runs `body` as the body of a loop.
local function parse_loop_body(loop: Loop): Ast.Block
  S.loops[#S.loops + 1] = loop
  local body = parse_block(0)
  S.loops[#S.loops] = nil
  return body
end

local function parse_while(): Ast.Stat
  local first = S.pos
  advance()
  local cond = parse_expression()
  expect("do", "after the condition of a `while`", "write `while cond do ... end`")
  local body = parse_loop_body(PLAIN_LOOP)
  close_block(body, "end", first, "`while`")
  return { kind = "While", id = 0, first = first, last = S.pos - 1, cond = cond, body = body }
end

--- The names a function binds itself: its parameters and the locals and loop
--- variables of its body, not those of a function inside it.
local function binds(fn: Ast.Fn): {string: boolean}
  local names: mut {string: boolean} = {}
  for _, p in ipairs(fn.params) do
    local name = p.name
    if name ~= nil then
      names[name.name] = true
    end
  end
  local stack: mut {Ast.Node} = { fn.body }
  while #stack > 0 do
    local node = table.remove(stack)
    if (node.kind == "Local") then
      for _, b in ipairs(node.bindings) do
        names[b.name] = true
      end
    elseif (node.kind == "LocalFunction") then
      names[node.name.name] = true
    elseif (node.kind == "ForNum") then
      names[node.var.name] = true
    elseif (node.kind == "ForIn") then
      for _, b in ipairs(node.vars) do
        names[b.name] = true
      end
    elseif (node.kind == "PatBind") then
      names[node.name.name] = true
    end
    if not ((node.kind == "Fn")) then
      Ast.children(node, function(child: Ast.Node)
        stack[#stack + 1] = child
      end)
    end
  end
  return names
end

--- The first use in `tree` of a name in `names`, or nil. A function inside
--- that binds the name itself, as a parameter or a local, reads its own.
local function find_read(tree: Ast.Node, names: {string: boolean}): Ast.Name
  local found: mut {Ast.Name} = {}
  local stack: mut {Ast.Node} = { tree }
  local masks: mut {{string: boolean}} = { {} }
  while #stack > 0 do
    local node = table.remove(stack)
    local mask = table.remove(masks)
    if (node.kind == "Name") then
      local best = found[1]
      if names[node.text] == true and mask[node.text] ~= true and (best == nil or node.first < best.first) then
        found[1] = node
      end
    else
      local inner = mask
      if (node.kind == "Fn") then
        inner = {}
        for k in pairs(mask) do
          inner[k] = true
        end
        for k in pairs(binds(node)) do
          inner[k] = true
        end
      end
      Ast.children(node, function(child: Ast.Node)
        stack[#stack + 1] = child
        masks[#masks + 1] = inner
      end)
    end
  end
  return found[1]
end

local function parse_repeat(): Ast.Stat
  local first = S.pos
  advance()
  local loop: Loop = { repeat_loop = true, depth = S.depth + 1, continue_at = 0, after = {}, after_at = 0 }
  local body = parse_loop_body(loop)
  close_block(body, "until", first, "`repeat`")
  local cond = parse_expression()
  if loop.after_at > 0 then
    local names: mut {string: boolean} = {}
    for _, n in ipairs(loop.after) do
      names[n] = true
    end
    local name = loop.after[1]
    local continue_line = S.ys[loop.continue_at]
    local fix = "wrap the code from `local " .. name .. "` to the end of the body in `do ... end`, so the local ends before `until`"
    local read = find_read(cond, names)
    if read ~= nil then
      name = read.text
      fix = "`until` reads `" .. name .. "`: declare it before the `repeat`, or before the `continue` on line " .. continue_line
    end
    report("continue_skips_local", loop.after_at, "`" .. name .. "` is declared after the `continue` on line " .. continue_line ..
        ", and Lua cannot jump into the scope of a local of a `repeat` body, which the `until` is inside", fix, loop.continue_at)
  end
  return { kind = "Repeat", id = 0, first = first, last = S.pos - 1, body = body, cond = cond }
end

local function parse_if(): Ast.Stat
  local first = S.pos
  advance()
  local arms: mut {Ast.Arm} = {}
  local else_body: Ast.Block = nil
  while true do
    local afirst = S.pos
    local cond = parse_expression()
    expect("then", "after the condition of an `if`", "write `if cond then ... end`")
    local body = parse_block(0)
    arms[#arms + 1] = { kind = "Arm", id = 0, first = afirst, last = body.last, cond = cond, body = body }
    if S.text == "elseif" then
      advance()
    else
      break
    end
  end
  if S.text == "else" then
    advance()
    else_body = parse_block(0)
  end
  local last_body = else_body or arms[#arms].body
  close_block(last_body, "end", first, "`if`")
  if else_body == nil then
    arms[#arms].last = last_body.last
  end
  return { kind = "If", id = 0, first = first, last = S.pos - 1, arms = arms, else_body = else_body }
end

local function parse_for(): Ast.Stat
  local first = S.pos
  advance()
  local name = binding("a loop variable")
  if S.text == "=" then
    advance()
    local from = parse_expression()
    expect(",", "between the bounds of a numeric `for`", "write `for i = from, to do`")
    local to = parse_expression()
    local step: Ast.Exp = nil
    if S.text == "," then
      advance()
      step = parse_expression()
    end
    expect("do", "after the bounds of a `for`", "write `for i = from, to do ... end`")
    local body = parse_loop_body(PLAIN_LOOP)
    close_block(body, "end", first, "`for`")
    return { kind = "ForNum", id = 0, first = first, last = S.pos - 1, var = name, from = from, to = to, step = step, body = body }
  end
  local vars: mut {Ast.Binding} = { name }
  while S.text == "," do
    advance()
    vars[#vars + 1] = binding("a loop variable")
  end
  expect("in", "after the variables of a `for`", "write `for k, v in pairs(t) do ... end`, or `for i = 1, n do ... end` to count")
  local iterators = parse_explist()
  expect("do", "after the iterator of a `for`", "write `for k, v in pairs(t) do ... end`")
  local body = parse_loop_body(PLAIN_LOOP)
  close_block(body, "end", first, "`for`")
  return { kind = "ForIn", id = 0, first = first, last = S.pos - 1, vars = vars, iterators = iterators, body = body }
end

local function parse_match(): Ast.Stat
  local first = S.pos
  advance()
  local scrutinee = parse_prefix()
  local call: Ast.CallExp
  if (scrutinee.kind == "Call") then
    call = scrutinee
  elseif (scrutinee.kind == "MethodCall") then
    call = scrutinee
  else
    if not ((scrutinee.kind == "Error")) then
      report("match_needs_call", first + 1, "`match` takes a call, found `" .. quoted_text(first + 1, S.pos - 1) .. "`",
        "call a function that returns a union of value lists: `match f(x) do | (true, v) then ... end`; to branch on a value write an `if`")
    end
    call = { kind = "Error", id = 0, first = first + 1, last = S.pos - 1 }
  end
  expect("do", "after the call of a `match`", "write `match f() do | (true, v) then ... end`")
  local arms: mut {Ast.MatchArm} = {}
  -- Whether an arm so far matches every value: no arm after it can run.
  local caught = false
  if S.text ~= "|" then
    report("expected_token", S.pos, "expected the first arm `|` of the `match`, found " .. shown(S.pos),
      "write each arm as `| (true, name) then ...`, `true` and `false` selecting the member and a name binding the value")
  end
  while S.text == "|" do
    advance()
    local afirst = S.pos
    local open = S.pos
    if caught then
      report("unreachable_arm", afirst, "this `match` arm can never run: the arm before it matches every value",
        "delete the arm, or move the arm that matches every value (`| (a, b) then`, with no `true` or `false`) to the end")
      caught = false
    end
    local pats: mut {Ast.PatItem} = {}
    if expect("(", "after `|` in a `match` arm", "write the arm as `| (true, name) then`") then
      while S.text ~= ")" and S.kind ~= "$EOF$" do
        local pfirst = S.pos
        if S.text == "true" or S.text == "false" then
          pats[#pats + 1] = { kind = "PatBool", id = 0, first = pfirst, last = pfirst, value = S.text == "true" }
          advance()
        else
          local b = binding("a bound value")
          pats[#pats + 1] = { kind = "PatBind", id = 0, first = pfirst, last = S.pos - 1, name = b }
        end
        if S.text == "," then
          advance()
          after_comma(")", "patterns")
        else
          break
        end
      end
      close(")", open, "pattern")
    end
    local bools = 0
    local bound: mut {string: boolean} = {}
    for _, pat in ipairs(pats) do
      if (pat.kind == "PatBool") then
        bools = bools + 1
      elseif (pat.kind == "PatBind") then
        local bound_name = pat.name.name
        if bound[bound_name] == true and bound_name:sub(1, 1) ~= "_" then
          report("duplicate_binding", pat.first, "`" .. bound_name .. "` is bound twice in this arm",
            "give each value of the pattern a name of its own, or `_` for one the arm does not use")
        end
        bound[bound_name] = true
      end
    end
    caught = bools == 0
    expect("then", "after the pattern of a `match` arm",
      "write `| (true, v) then ...`; an expression that goes on to the next line keeps its operator at the end of " ..
        "the line before, since a `|` that begins a line starts an arm")
    local saved = { S.arm_from, S.scan_at, S.scan_depth }
    S.arms = S.arms + 1
    S.arm_from, S.scan_at, S.scan_depth = S.pos, S.pos, 0
    local body = parse_block(0)
    S.arms = S.arms - 1
    S.arm_from, S.scan_at, S.scan_depth = saved[1], saved[2], saved[3]
    arms[#arms + 1] = { kind = "MatchArm", id = 0, first = afirst, last = body.last, pats = pats, body = body }
  end
  local last_arm = arms[#arms]
  if last_arm ~= nil then
    close_block(last_arm.body, "end", first, "`match`")
    last_arm.last = last_arm.body.last
  else
    close("end", first, "`match`")
  end
  return { kind = "Match", id = 0, first = first, last = S.pos - 1, scrutinee = call, arms = arms }
end

local function parse_return(): Ast.Stat
  local first = S.pos
  advance()
  local values: {Ast.Exp} = {}
  if TERMINATOR[S.text] ~= true and S.text ~= "|" then
    values = parse_explist()
  end
  return { kind = "Return", id = 0, first = first, last = S.pos - 1, values = values }
end

local function parse_do(): Ast.Stat
  local first = S.pos
  advance()
  local body = parse_block(0)
  close_block(body, "end", first, "`do`")
  return { kind = "Do", id = 0, first = first, last = S.pos - 1, body = body }
end

local function parse_break(): Ast.Stat
  local first = S.pos
  advance()
  if #S.loops <= S.loop_base then
    report("break_outside_loop", first, "`break` is outside a loop", "move it into the body of a `while`, `for` or `repeat`, or `return` to leave a function")
  end
  return { kind = "Break", id = 0, first = first, last = first }
end

local function parse_continue(): Ast.Stat
  local first = S.pos
  advance()
  local top = S.loops[#S.loops]
  if #S.loops <= S.loop_base or top == nil then
    report("continue_outside_loop", first, "`continue` is outside a loop",
      "move it into the body of a `while`, `for` or `repeat` of the same function; to leave a function write `return`")
  elseif top.repeat_loop and top.continue_at == 0 then
    top.continue_at = first
  end
  return { kind = "Continue", id = 0, first = first, last = first }
end

local function parse_goto(): Ast.Stat
  local first = S.pos
  advance()
  local label: string = nil
  if is_field_word() and S.ys[S.pos] == S.ys[first] then
    label = S.text
  end
  report("label_or_goto", first, "`goto" .. (if label then " " .. label else "" end) .. "` is not in the grammar",
    if label == "continue" then "write `continue" .. "`" else
      "write `continue` to skip the rest of a pass of the loop around it; restructure any other jump with an `if` around the code to skip, or move the code into a function and `return` from it" end)
  return skip_junk(first, false)
end

--- A call, or an assignment, which begins with a name or a parenthesis.
local function parse_expression_statement(): Ast.Stat
  local first = S.pos
  local e = parse_prefix()
  if S.text == "=" or S.text == "," then
    local targets: mut {Ast.Exp} = { e }
    while S.text == "," do
      advance()
      targets[#targets + 1] = parse_prefix()
    end
    for _, target in ipairs(targets) do
      local b = base_of(target)
      if target.kind ~= "Name" and target.kind ~= "Field" and target.kind ~= "Index" and target.kind ~= "Error" then
        report("bad_target", b.first, "`" .. quoted_text(b.first, b.last) .. "` cannot be assigned to",
          "assign to a name, a field `t.k` or an index `t[k]`")
      end
    end
    expect("=", "in an assignment", "write `target = value`")
    local values = parse_explist()
    return { kind = "Assign", id = 0, first = first, last = S.pos - 1, targets = targets, values = values }
  end
  if (e.kind == "Call") then
    return { kind = "CallStat", id = 0, first = first, last = S.pos - 1, call = e }
  elseif (e.kind == "MethodCall") then
    return { kind = "CallStat", id = 0, first = first, last = S.pos - 1, call = e }
  elseif (e.kind == "Error") then
    return e
  end
  local b = base_of(e)
  report("not_a_statement", first, "`" .. quoted_text(b.first, b.last) .. "` is not a statement: a statement is a call or an assignment",
    "call it, assign it (`local x = ...`), or delete it; a comparison alone does nothing")
  return skip_junk(first, false)
end

local STATEMENT <const>: {string: function(): Ast.Stat} = {
  ["local"] = parse_local, ["global"] = parse_local, ["function"] = parse_function_statement,
  ["while"] = parse_while, ["repeat"] = parse_repeat, ["if"] = parse_if, ["for"] = parse_for,
  ["match"] = parse_match, ["return"] = parse_return, ["do"] = parse_do, ["break"] = parse_break,
  ["continue"] = parse_continue, ["goto"] = parse_goto,
}

--- The kinds of statement a declaration file holds besides a `local`, a `global` and a `return`.
local DECLARATIONS <const>: {string: boolean} = {
  Record = true, Interface = true, Class = true, Enum = true, Alias = true, Import = true, Do = true, Error = true,
}

--- Whether `stat` is a `local x = require("m")`.
local function is_require_local(stat: Ast.Local): boolean
  local value = stat.values[1]
  if #stat.bindings ~= 1 or #stat.values ~= 1 or #stat.types > 0 or value == nil or not ((value.kind == "Call")) then
    return false
  end
  local callee, literal = value.callee, value.args[1]
  return (callee.kind == "Name") and callee.text == "require" and #value.args == 1 and literal ~= nil and (literal.kind == "String")
end

--- What a declaration file does not hold in `stat`, which is at the top level
--- of the chunk if `top`, or "" where it holds it: the types, `local x =
--- require("m")`, the `global` declarations, `do` blocks of those and one
--- `return Name`.
local function declaration_problem(stat: Ast.Stat, top: boolean): string
  if DECLARATIONS[stat.kind] == true then
    return ""
  elseif (stat.kind == "Local") then
    if stat.scope == "global" or is_require_local(stat) then
      return ""
    end
    return "a `local` of a declaration file is `local x = require(\"m\")`"
  elseif (stat.kind == "Return") then
    local value = stat.values[1]
    if top and #stat.values == 1 and value ~= nil and (value.kind == "Name") then
      return ""
    end
    return "a declaration file ends in one `return Name`, outside any block"
  end
  return "a declaration file holds declarations, not " .. (if stat.kind == "CallStat" then "calls" else "this statement" end)
end

local LITERAL_KIND <const>: {string: boolean} = { string = true, integer = true, number = true }
local LITERAL_TEXT <const>: {string: boolean} = { ["nil"] = true, ["true"] = true, ["false"] = true, ["{"] = true, ["..."] = true }

--- Whether the `match` or `continue` at the current token is used as a name: it is
--- assigned to, indexed, or called where no `do` follows on its line.
local function named_as_a_variable(): boolean
  local t = S.text
  if t ~= "match" and t ~= "continue" then
    return false
  end
  local nxt = peek_text(1)
  if nxt == "=" or nxt == "," or nxt == "." or nxt == ":" or nxt == "[" then
    return true
  elseif nxt ~= "(" or S.ys[S.pos + 1] ~= S.ys[S.pos] then
    return false
  elseif t == "continue" then
    return true
  end
  local i = S.pos + 1
  local line = S.ys[i]
  while i < S.last and S.ys[i] == line do
    if S.texts[i] == "do" then
      return false
    end
    i = i + 1
  end
  return true
end

local function unexpected_fix(text: string): string
  if text == "end" or text == "else" or text == "elseif" or text == "until" then
    return "delete the `" .. text .. "`, or add what it ends: an `if`, `while`, `for`, `repeat`, `function` or `do`"
  elseif text == "|" then
    return "an arm `|` belongs in a `match ... do` ... `end`; delete it otherwise"
  end
  return "a statement is a call, an assignment, a `local` or one of `if`, `while`, `for`, `repeat`, `do`, `match`, `return`, `break`, `continue`; delete this or begin the statement with one"
end

parse_statement = function(): Ast.Stat
  local handler = STATEMENT[S.text]
  local stat: Ast.Stat
  local first = S.pos
  if handler ~= nil and S.kind == "keyword" and not named_as_a_variable() then
    stat = handler()
  elseif S.kind == "identifier" and DECL_WORD[S.text] == true and peek_kind(1) == "identifier" then
    report("bare_declaration", first, "`" .. S.text .. " " .. peek_text(1) .. "` declares a type that nothing scopes",
      "write `local " .. S.text .. " " .. peek_text(1) .. "`; a declaration file writes `global`")
    stat = parse_typedecl(first, nil)
  elseif S.kind == "identifier" or S.text == "(" or (S.kind == "keyword" and RESERVED_NAME[S.text] == true) then
    stat = parse_expression_statement()
  elseif S.kind == "$ERR$" then
    advance()
    return error_node(first)
  elseif (LITERAL_KIND[S.kind] == true or LITERAL_TEXT[S.text] == true) and SUFFIX[peek_text(1)] == true then
    stat = parse_expression_statement()
  else
    local fix = unexpected_fix(S.text)
    if S.text == ":" and S.texts[S.pos - 1] == "end" then
      fix = "if `end` was meant as a field of a record, a field named by a keyword is declared and indexed as " ..
        "`[\"end\"]`: write `[\"end\"]: T` in the declaration and `t[\"end\"]` to read it"
    end
    report("unexpected_token", first, "unexpected " .. shown(S.pos) .. " where a statement begins", fix)
    return skip_junk(first, true)
  end
  if S.decl then
    local problem = declaration_problem(stat, S.depth == 1)
    if problem ~= "" then
      report("statement_in_declaration", first, problem,
        "declare types and values: `local record R ... end`, `global f <const> = ...`, `local x = require(\"m\")`, and end with `return Name`")
    end
  end
  return stat
end

--- The statements of a block up to a token that ends it. `mode` is 0 for a
--- block that `end`, `else`, `elseif` or `until` ends, or in a `match` arm the
--- `|` that begins the next arm, and 2 for the chunk, which only the end of
--- the file ends.
parse_block = function(mode: integer): Ast.Block
  local first = S.pos
  local stats: mut {Ast.Stat} = {}
  if S.nesting >= MAX_NESTING then
    report("too_deep", first, "more than " .. tostring(MAX_NESTING) .. " levels of nesting",
      "split the code: name an inner expression with a `local`, or move an inner block into a function")
    S.muted = true
    if TERMINATOR[S.text] ~= true then
      stats[1] = skip_to_terminator(first)
    end
    return { kind = "Block", id = 0, first = first, last = S.pos, stats = stats, close = S.pos }
  end
  S.nesting = S.nesting + 1
  S.depth = S.depth + 1
  local returned = 0
  while true do
    if S.muted and S.depth == 1 then
      -- What is left of the construct that was too deep is skipped, and the
      -- statements after it are reported again.
      S.muted = false
      local at = S.pos
      while S.kind ~= "$EOF$" and (SYNC[S.text] ~= true or CLOSES[S.text] == true) do
        if (S.kind == "identifier" or S.text == "(") and begins_line(S.pos) then
          break
        end
        advance()
      end
      if S.pos > at then
        table.insert(stats, error_node(at))
      end
    end
    local t = S.text
    if mode == 2 then
      if S.kind == "$EOF$" then break end
    elseif TERMINATOR[t] == true or (S.arms > 0 and arm_bar(true)) then
      break
    end
    local before = S.pos
    if returned > 0 then
      report("statement_after_return", before, "a statement follows the `return` on line " .. S.ys[returned] .. ": a `return` ends its block",
        "move the `return` to the end of the block, or write `do return end` to leave early", returned)
      returned = 0
    end
    local stat = parse_statement()
    if S.pos == before then
      stat = skip_junk(before, true)
    elseif t == "return" then
      returned = before
    end
    stats[#stats + 1] = stat
  end
  S.depth = S.depth - 1
  S.nesting = S.nesting - 1
  return { kind = "Block", id = 0, first = first, last = S.pos, stats = stats, close = S.pos }
end

function Parser.parse(lexed: Lexer.Lexed, name: string, dialect: Ast.Dialect): Parser.Parsed
  local tokens = lexed.tokens
  S.tokens = tokens
  S.kinds, S.texts, S.ys, S.yends = tokens.kind, tokens.text, tokens.y, tokens.yend
  S.last = #tokens.kind
  S.pos = 1
  S.text = tokens.text[1]
  S.kind = tokens.kind[1]
  S.errors = {}
  S.name = name
  S.decl = dialect == "decl"
  S.half = 0
  S.reported = {}
  S.beside = nil
  S.beside_work = 0
  S.muted = false
  S.nesting = 0
  S.arms = 0
  S.tables = 0
  S.arm_from = 1
  S.arm_same = 0
  S.scan_at = 1
  S.scan_depth = 0
  S.depth = 0
  S.loops = {}
  S.loop_base = 0
  S.requires = {}
  S.require_nodes = {}
  S.require_names = {}
  local body = parse_block(2)
  for index, taken in pairs(S.require_names) do
    if not taken then
      report("require_value", index, "`require` is read as a value here, and the build follows a require only where it is " ..
          "called directly on a name",
        "call it: `require(\"cosmic.fs\")`, or hand it to `pcall` as its first argument: `pcall(require, \"cosmic.fs\")`; " ..
          "to choose between modules, require each by its literal name and pick from a table, and never keep `require` " ..
          "in a variable, in parentheses or in another call's arguments")
    end
  end
  local chunk: Ast.Chunk = { kind = "Chunk", id = 0, first = 1, last = S.last, body = body, tokens = tokens, requires = S.requires }
  Ast.number(chunk)
  for i, req in ipairs(S.requires) do
    req.node = base_of(S.require_nodes[i]).id
  end
  local errors = S.errors
  for _, e in ipairs(lexed.errors) do
    errors[#errors + 1] = {
      filename = e.filename, code = LEXER_CODES[e.code], msg = e.msg, fix = e.fix, y = e.y, x = e.x,
      offset = e.offset, length = e.length,
    }
  end
  -- A statement after a `return` that begins a line the open construct ended at is that
  -- construct's missing `end`, which is the error.
  local unclosed: mut {integer: boolean} = {}
  for _, e in ipairs(errors) do
    if e.code == "unclosed" then
      unclosed[e.offset] = true
    end
  end
  local kept: mut {Parser.Error} = {}
  for _, e in ipairs(errors) do
    if not (e.code == "statement_after_return" and unclosed[e.offset] == true) then
      kept[#kept + 1] = e
    end
  end
  errors = kept
  table.sort(errors, function(a: Parser.Error, b: Parser.Error): boolean
    if a.offset ~= b.offset then
      return a.offset < b.offset
    end
    return tostring(a.code) < tostring(b.code)
  end)
  S.tokens, S.kinds, S.texts, S.ys, S.yends, S.last = NO_TOKENS, NO_TOKENS.kind, NO_TOKENS.text, NO_TOKENS.y, NO_TOKENS.yend, 1
  S.errors = {}
  S.loops = {}
  S.requires = {}
  S.require_nodes = {}
  S.require_names = {}
  return { chunk = chunk, errors = errors }
end

Parser.codes = {
  "label_or_goto", "semicolon", "long_comment", "unterminated_long_comment", "digit_separator",
  "hex_float", "malformed_number", "unterminated_string", "unterminated_long_string", "bad_escape",
  "stray_byte", "reserved_word", "nil_union", "method_in_record", "continue_outside_loop",
  "break_outside_loop", "continue_skips_local", "unclosed", "expected_token", "expected_name",
  "expected_expression", "expected_type", "unexpected_token", "not_a_statement", "bad_target",
  "statement_after_return", "chained_optional", "chained_is", "is_union", "bare_function",
  "bare_declaration", "function_path", "global_in_program", "userdata_in_program", "duplicate_field",
  "body_in_declaration", "statement_in_declaration", "mut_needs_collection", "string_call", "variadic_type",
  "optional_type", "tuple_type", "string_literal_type", "bare_function_type", "metamethod", "several_supers",
  "generic_function_literal", "bad_attribute", "if_needs_else", "match_needs_call", "method_needs_self",
  "method_path", "close_repeated", "trailing_comma", "arm_on_same_line", "unreachable_arm", "duplicate_binding", "reserved_method",
  "suffix_needs_parens", "nested_in_interface",
  "old_type_declaration", "narrowing_return", "too_deep", "computed_require", "require_value",
}

return Parser
