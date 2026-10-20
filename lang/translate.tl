--- The translator from Teal, the fork's grammar, to the new checker's grammar
--- ([`doc/plans/new-checker-grammar.md`], "departures from Teal, and what the
--- translator does").
---
--- `translate` reads a Teal module with [`lang.parser`] and writes it back in
--- the new grammar. The parser is the reader: the grammar is Teal less the
--- forms it cuts, and the parser refuses each cut form while keeping a tree
--- that holds it (`T | nil` is a `TypeUnion` with a `TypeNil` member, `function
--- R:m` a `Function`, `goto continue` an `Error` and a `Continue`), so every
--- node has the tokens it was written with and a rewrite is an edit of those
--- tokens' bytes. The fork's parser would give a tree whose positions are
--- those of where a node was built, with no tokens and no comments, and it
--- adds a `;` and a `self` the source never wrote. A rule of the translator is
--- therefore the fix the parser's error already names, done in place.
---
--- A rewrite is a respelling wherever the table says so: only the bytes of
--- the cut form change, the lines of the file stay where they are, and
--- comments are never touched. The one row that moves lines is the class
--- (`function R:m` moves into its record, and the lines after it shift). A
--- long comment of several lines becomes the same number of line comments.
---
--- Rows, with the count of each in [`Result.counts`]:
---
--- - `nil_union`: `T | nil`, `nil | T` and `A | B | nil` become `T?` and
---   `(A | B)?`; a function type is parenthesized. A return list that would
---   begin with `(A | B)?` and go on is written in parentheses, which the
---   parser would otherwise read as the whole list.
--- - `variadic_type`: `T...` as a parameter's type becomes `...: T`.
--- - `optional_type`: `? T` becomes `argN?: T`, N being the parameter's place.
--- - `continue`: `goto continue` becomes `continue` and the `::continue::`
---   that ends the loop is deleted, leaving its line empty. It is done only
---   where the nearest label a block around the `goto` holds, before a
---   function ends, ends the innermost loop; otherwise the gotos and their
---   label stay.
--- - `semicolon`, `long_comment`, `digit_separator`, `hex_float`: removed or
---   respelled. The parser ends a table at its first `;`, so the ones after
---   it are changed in the same read up to the first word that begins a block,
---   and each after that takes a read. A long comment with code or another
---   long comment after its end on the last line stays.
--- - `type_declaration`: `local type X = record` becomes `local record X`.
--- - `metamethod`: `metamethod __close: T` becomes the field `__close: T`.
--- - `readonly`: `readonly f: T` becomes `f: T`.
--- - `ternary`: `c and a or b` becomes `if c then a else b end`, and a chain
---   `c and a or d and e or b` an `if` with `elseif`, where each middle operand
---   is written as something that can be neither false nor nil: a literal, a
---   table, a function, an arithmetic or concatenation, or a cast to a type
---   of those. The draft asks for the checker's type report; a ternary whose
---   middle operand needs one stays, and counts under the `or` and `and`
---   ceiling.
--- - `unary_power`: the fork reads `-a ^ b` as `(-a) ^ b`, Lua and the new grammar as `-(a ^ b)`, so the
---   unary operator and its operand are parenthesized, and so are those of `not not a ^ b`.
--- - `class`: a record with `function R:m()` statements at the top of the file
---   becomes a `class` that holds them as `function m(self, ...)`, with the
---   field of the same name that declared the method dropped, its doc comment
---   carried over and its parameter and return types written on the method
---   where the method leaves them out, and the `__close = function(self: R)` of the
---   `metatable<R>` literal that follows it, which the class declares as the method
---   `__close`. A record with an array part or
---   `userdata` stays a record. A method that reads a name declared between its
---   record and where it was written, or gives types that differ from its
---   field's, is a [`Hazard`].
--- - `class_literal`: `setmetatable(T, mt)` is `T` where `T` is a table literal, `mt` is the metatable of a class of
---   the file (`local mt: metatable<R> = { __index = R }`, or the literal `{ __index = R }`) and the place gives the
---   class as the type of the literal: the only value of a local declared `R`, which is declared `R` where it had no
---   type, or of a `return` in a function that answers `R`. The metatable local goes when every use of its name was
---   such a call, and with it every call of it stays when one is not. A row counts one metatable (or one inline
---   call) with its calls.
--- - `mut_field`, `mut_collection`, `mut_param`: `mut` on a field that a name
---   declared as its record assigns, on the array or map a field holds when
---   an index of it is assigned or a `table` function changes it, and on a
---   parameter that is an array or map and is changed the same way. A name
---   is credited to a record only where its block binds it once, as a
---   parameter or local with that record's plain name as its type, or as
---   `self` in a method. A field is `mut` in the interfaces of the file that
---   declare it and in every record that implements them and declares it; a
---   super written with a qualifier is the type of the file with its last name.
---   An interface of another file may need the same `mut`, which is reported. What this misses is a write through a name the syntax
---   does not type (a call's result, a field of a field) and a collection
---   passed on to a function that changes it. Both wait on the checker's type
---   report, which resolves every target.
---
--- A cast, `is`, `T...` as a return, and every other form the grammar keeps
--- are left as they are. The forms the draft has rewritten by hand first (a
--- tuple type, `where`, a reserved word as a name, a string call, a type
--- parameter on a function literal) are not handled: the errors they leave
--- are in [`Result.errors`], which is the whole account of what the translator
--- did not handle. A return list that begins with a parenthesized type is read
--- by the parser as a list, so it is not handled either.
---
--- `translate` is a function of its source: the same text gives the same
--- result, and text in the new grammar gives itself, `mut` aside (a field
--- assigned in a class without `mut` is given it) and a unary operator over a
--- `^`, which it reads as the fork does.
local Ast = require("lang.ast")
local Lexer = require("lang.lexer")
local Parser = require("lang.parser")

local record Translate
  --- A place where a rewrite may change what a program means or break it, and
  --- that the translator reports without deciding. `kind` is `scope` (a
  --- method that moved into a class reads a name declared between its record
  --- and where it was written, which the class cannot see), `shadow` (the same
  --- name is also declared before the record, so the moved method reads that
  --- one), `signature` (the method and the field that declared it give
  --- different types) or `interface` (a field given `mut` belongs to a record
  --- that implements an interface this file does not declare, so the
  --- interface may need the same `mut`; most are fields the interface does
  --- not have).
  record Hazard
    kind: string
    --- The class and the method, or for `interface` the record and the field.
    class: string
    method: string
    --- The line of the method as written, or of the field.
    y: integer
    --- The name that the method reads, the parameter (or `return`) whose type
    --- differs, or the interface.
    name: string
  end

  --- An interface the file declares: what the whole tree needs to say whether
  --- a record of another file gives `mut` to a field the interface declares.
  record Interface
    name: string
    --- The names of its fields.
    fields: {string}
    --- The last component of each interface it extends.
    supers: {string}
  end

  --- What `translate` answers.
  record Result
    --- The module in the new grammar.
    text: string
    --- How many times each row made a rewrite, by the row's name. A row that
    --- made none has no entry.
    counts: {string: integer}
    --- What `text` still parses with: the forms the translator does not
    --- handle, and any error the source had of its own. A source with none
    --- gives a `text` that parses clean.
    errors: {Parser.Error}
    --- Names a moved method may read that its class cannot see, and the
    --- other places a rewrite may change what a program means.
    hazards: {Hazard}
    --- The interfaces of the file.
    interfaces: {Interface}
    --- The names of the metatable locals the translation removed, whose calls are class literals now.
    metatables: {string}
    --- How many times the source was read, the last read being the one that
    --- gave `errors`.
    reads: integer
  end

  --- Translates `source`, a module named `name` (a name ending `.d.tl` is a
  --- declaration file).
  translate: function(source: string, name: string): Result

  --- The name of each row, in the order the module doc lists them.
  rows: {string}

  --- Whether `e` can be neither false nor nil, from its syntax alone: a literal, a table, a function, an
  --- arithmetic or concatenation, or a cast to a type that holds neither. It is what the translator
  --- needs of a middle operand to write an `if` expression, and what a code generator may take as truthy.
  never_false: function(e: Ast.Exp): boolean
end

Translate.rows = {
  "nil_union", "variadic_type", "optional_type", "continue", "semicolon", "long_comment",
  "digit_separator", "hex_float", "type_declaration", "metamethod", "readonly", "ternary", "class", "class_literal",
  "mut_field", "mut_collection", "mut_param", "unary_power",
}

--- One replacement of the bytes `lo` to `hi - 1` of the source by `text`. An
--- insertion has `hi == lo`.
local record Edit
  lo: integer
  hi: integer
  text: string
end

--- The edits of one rewrite, which are applied together or not at all.
local record Rewrite
  row: string
  edits: {Edit}
  --- Whether the rewritten text begins with a `(`.
  opens?: boolean
  --- The name of the local the rewrite removes, for [`Translate.Result.metatables`].
  removed?: string
end

local MAX_READS <const> = 8

local sub, find, byte, format = string.sub, string.find, string.byte, string.format
local concat = table.concat

--- The offset one past the last byte of token `i`.
local function stop_of(tokens: {Lexer.Token}, i: integer): integer
  local t = tokens[i]
  return t.offset + t.length
end

--- Where the blanks (spaces and tabs) that end just before `at` begin.
local function blanks_before(source: string, at: integer): integer
  local i = at
  while i > 1 do
    local c = byte(source, i - 1)
    if c ~= 32 and c ~= 9 then
      break
    end
    i = i - 1
  end
  return i
end

--- Where the blanks that begin at `at` end, one past the last.
local function blanks_after(source: string, at: integer): integer
  local i = at
  while true do
    local c = byte(source, i)
    if c ~= 32 and c ~= 9 then
      break
    end
    i = i + 1
  end
  return i
end

--- The offset of the first byte of the line holding `at`.
local function line_start(source: string, at: integer): integer
  local i = at
  while i > 1 do
    local c = byte(source, i - 1)
    if c == 10 or c == 13 then
      break
    end
    i = i - 1
  end
  return i
end

--- The offset one past the line break that ends the line holding `at`, or
--- one past the end of the source.
local function after_line(source: string, at: integer): integer
  local s = find(source, "[\r\n]", at)
  if s == nil then
    return #source + 1
  end
  local c, d = byte(source, s), byte(source, s + 1)
  if (c == 10 and d == 13) or (c == 13 and d == 10) then
    return s + 2
  end
  return s + 1
end

--- Whether the line that begins at `at` holds nothing but blanks.
local function blank_line(source: string, at: integer): boolean
  local i = blanks_after(source, at)
  local c = byte(source, i)
  return c == nil or c == 10 or c == 13
end

--- The edit that deletes token `i` and the blanks before it.
local function delete_with_blanks_before(source: string, tokens: {Lexer.Token}, i: integer): Edit
  return { lo = blanks_before(source, tokens[i].offset), hi = stop_of(tokens, i), text = "" }
end

--- The edit that deletes token `i` and the blanks after it.
local function delete_with_blanks_after(source: string, tokens: {Lexer.Token}, i: integer): Edit
  local hi = stop_of(tokens, i)
  return { lo = tokens[i].offset, hi = blanks_after(source, hi), text = "" }
end

local function replace_token(tokens: {Lexer.Token}, i: integer, text: string): Edit
  return { lo = tokens[i].offset, hi = stop_of(tokens, i), text = text }
end

local function insert_before(tokens: {Lexer.Token}, i: integer, text: string): Edit
  return { lo = tokens[i].offset, hi = tokens[i].offset, text = text }
end

local function insert_after(tokens: {Lexer.Token}, i: integer, text: string): Edit
  local at = stop_of(tokens, i)
  return { lo = at, hi = at, text = text }
end

--- The node's `first` and `last` token indexes.
local function bounds(node: Ast.Node): integer, integer
  local base: Ast.Base = node
  return base.first, base.last
end

-- walking

local kind_fields, kind_depths = Ast.fields, Ast.depths

--- Pushes the nodes of `value`, a node's list of nodes (`depth` 1) or of lists
--- (`depth` 2), onto `nodes` after `top` in source order, and answers the new top.
local function push_list(nodes: {Ast.Node}, top: integer, value: {any}, depth: integer): integer
  for i = 1, #value do
    local item = value[i]
    if depth == 1 then
      if item is Ast.Node then
        top = top + 1
        nodes[top] = item
      end
    elseif item is {any} then
      top = push_list(nodes, top, item, 1)
    end
  end
  return top
end

--- Pushes the children of `node` onto `nodes` after `top` in source order.
local function push_children(nodes: {Ast.Node}, top: integer, node: any): integer
  if not (node is {string: any}) then
    return top
  end
  local kind = node.kind
  if not (kind is string) then
    return top
  end
  local names, depth = kind_fields[kind], kind_depths[kind]
  for i = 1, #names do
    local value = node[names[i]]
    if type(value) == "table" then
      if depth[i] == 0 then
        if value is Ast.Node then
          top = top + 1
          nodes[top] = value
        end
      elseif value is {any} then
        top = push_list(nodes, top, value, depth[i])
      end
    end
  end
  return top
end

--- Calls `enter` with each node of the tree under `root`, parents first,
--- and `leave` with it after its children. It keeps its own stack, so a tree
--- as deep as a long chain of operators is walked.
local function walk(root: Ast.Node, enter: function(Ast.Node), leave: function(Ast.Node))
  local nodes: {Ast.Node} = { root }
  local leaving: {boolean} = { false }
  local top = 1
  while top > 0 do
    local node, exiting = nodes[top], leaving[top]
    nodes[top] = nil
    leaving[top] = nil
    top = top - 1
    if exiting then
      leave(node)
    else
      enter(node)
      top = top + 1
      nodes[top] = node
      leaving[top] = true
      local from = top
      top = push_children(nodes, top, node)
      for k = from + 1, top do
        leaving[k] = false
      end
      -- The children were pushed in source order; the first must come off first.
      local i, j = from + 1, top
      while i < j do
        nodes[i], nodes[j] = nodes[j], nodes[i]
        i = i + 1
        j = j - 1
      end
    end
  end
end

-- numbers, semicolons and comments: rows that read tokens alone

--- A hexadecimal float written in decimal, which reads back as the same float.
local function decimal_of(value: number): string | nil
  if value ~= value or value == math.huge or value == -math.huge then
    return nil
  end
  local text = format("%.17g", value)
  if not find(text, "[%.eE]") then
    text = text .. ".0"
  end
  return text
end

--- Whether every `_` of the number `text` sits between two digits (hexadecimal for `0x`), the one place the fork's lexer
--- takes it; `1__0` and `1_` are malformed there, so they are left for the new lexer to refuse.
local function separators_between_digits(text: string): boolean
  local digit = "^%d$"
  if find(text, "^0[xX]") ~= nil then
    digit = "^%x$"
  end
  local at = find(text, "_", 1, true)
  while at ~= nil do
    if find(text:sub(at - 1, at - 1), digit) == nil or find(text:sub(at + 1, at + 1), digit) == nil then
      return false
    end
    at = find(text, "_", at + 1, true)
  end
  return true
end

--- A cut number: `1_000` without its `_`, a hexadecimal float in decimal.
local function number_rewrite(tokens: {Lexer.Token}, i: integer): Rewrite | nil
  local t = tokens[i]
  local kind, text = t.kind, t.text
  if kind ~= "integer" and kind ~= "number" then
    return nil
  end
  if find(text, "_", 1, true) ~= nil and separators_between_digits(text) then
    return { row = "digit_separator", edits = { replace_token(tokens, i, (text:gsub("_", ""))) } }
  end
  local value = t.number
  if value ~= nil and find(text, "^0[xX]") and find(text, "[%.pP]") then
    local written = decimal_of(value)
    if written ~= nil then
      return { row = "hex_float", edits = { replace_token(tokens, i, written) } }
    end
  end
  return nil
end

--- The line comments that say what the long comment `text` (its brackets
--- included) at `offset` says, one for each line of it, or nil where it
--- cannot be written so: code follows its end on its last line (a line
--- comment may, another long comment may not). A line after the first begins
--- where the line of the comment does.
local function line_comments(source: string, offset: integer, text: string): string | nil
  local level = #(text:match("^%-%-%[(=*)%[") or "")
  local after = offset + #text
  local rest = sub(source, after, (find(source, "[\r\n]", after) or #source + 1) - 1)
  if find(rest, "%S") and (not find(rest, "^%s*%-%-") or find(rest, "^%s*%-%-%[=*%[")) then
    return nil
  end
  local from = line_start(source, offset)
  local indent = sub(source, from, blanks_after(source, from) - 1)
  local inner = sub(text, 5 + level, #text - level - 2)
  local out: {string} = {}
  local pos = 1
  local n = #inner
  while pos <= n + 1 do
    local s = find(inner, "[\r\n]", pos)
    local line = sub(inner, pos, (s or n + 1) - 1)
    local body = line:match("^%s*(.-)%s*$") or ""
    out[#out + 1] = (pos == 1 and "" or indent) .. (body == "" and "--" or "-- " .. body)
    if s == nil then
      break
    end
    local stop = after_line(inner, s)
    out[#out + 1] = sub(inner, s, stop - 1)
    pos = stop
  end
  return concat(out)
end

-- the walk's rewrites

--- The operators that answer a number or a string.
local NUMBERY <const>: {string: boolean} = {
  ["+"] = true, ["-"] = true, ["*"] = true, ["/"] = true, ["//"] = true, ["%"] = true, ["^"] = true,
  [".."] = true, ["&"] = true, ["|"] = true, ["~"] = true, ["<<"] = true, [">>"] = true,
}

local VALUE_TYPES <const>: {string: boolean} = { string = true, number = true, integer = true }

--- Whether `e` can be neither false nor nil, from its syntax alone: a
--- literal, a table, a function, an arithmetic or concatenation, or a cast to
--- a type that holds neither.
---
-- TODO: write the `if` expression for a middle operand that is neither boolean nor
-- optional by the type report and not by its syntax, once the new checker's
-- type report keyed by node id exists (doc/plans/new-checker-grammar.md, "the
-- interface"): a name or a call stays a ternary until then.
local function never_false(e: Ast.Exp): boolean
  local cur: Ast.Node = e
  while true do
    if cur is Ast.Paren then
      cur = cur.inner
    elseif cur is Ast.Cast then
      local ty = cur.type
      if ty is Ast.TypeName then
        local path = ty.path
        return #path == 1 and #ty.args == 0 and VALUE_TYPES[path[1]] == true
      end
      return ty is Ast.TypeArray or ty is Ast.TypeMap or ty is Ast.TypeFunction
    elseif cur is Ast.Binary then
      return NUMBERY[cur.op] == true
    elseif cur is Ast.Unary then
      local op = cur.op
      return op == "-" or op == "#" or op == "~"
    else
      return cur is Ast.String or cur is Ast.Integer or cur is Ast.Float or cur is Ast.Table or
        cur is Ast.FunctionLit
    end
  end
end

--- The rewrite of `c and a or b`, and of a chain `c and a or d and e or b`,
--- when each middle operand is never false, as an `if` expression. `top` is the
--- `or` node. `covered` receives the inner `or` nodes of a chain, which are
--- no ternary of their own.
local function ternary_rewrite(tokens: {Lexer.Token}, top: Ast.Binary, covered: {Ast.Node: boolean}): Rewrite | nil
  local ands: {Ast.Binary} = {}
  local spine: {Ast.Binary} = {}
  local cur: Ast.Exp = top.left
  while cur is Ast.Binary and cur.op == "or" do
    local right = cur.right
    if not (right is Ast.Binary and right.op == "and") then
      return nil
    end
    ands[#ands + 1] = right
    spine[#spine + 1] = cur
    cur = cur.left
  end
  if not (cur is Ast.Binary and cur.op == "and") then
    return nil
  end
  ands[#ands + 1] = cur
  -- The spine was walked from the last arm to the first.
  for i = 1, #ands // 2 do
    ands[i], ands[#ands + 1 - i] = ands[#ands + 1 - i], ands[i]
  end
  for _, a in ipairs(ands) do
    if not never_false(a.right) then
      return nil
    end
  end
  local edits: {Edit} = {}
  local first, last = bounds(top)
  edits[1] = insert_before(tokens, first, "if ")
  for i, a in ipairs(ands) do
    local _, a_last = bounds(a.left)
    local op = a_last + 1
    if tokens[op].text ~= "and" then
      return nil
    end
    edits[#edits + 1] = replace_token(tokens, op, "then")
    local _, a_end = bounds(a)
    local joiner = a_end + 1
    if tokens[joiner].text ~= "or" then
      return nil
    end
    edits[#edits + 1] = replace_token(tokens, joiner, i < #ands and "elseif" or "else")
  end
  edits[#edits + 1] = insert_after(tokens, last, " end")
  for _, inner in ipairs(spine) do
    covered[inner] = true
  end
  return { row = "ternary", edits = edits }
end

--- The rewrites of a function type's parameters: `T...` and `? T`.
local function parameter_rewrites(source: string, tokens: {Lexer.Token}, ty: Ast.TypeFunction, out: {Rewrite})
  for index, p in ipairs(ty.params) do
    local first, last = bounds(p)
    if p.variadic and last > first and tokens[last].kind == "..." then
      local edits: {Edit} = {}
      local type_first = bounds(p.type)
      if p.name ~= nil then
        edits[1] = { lo = tokens[first].offset, hi = tokens[type_first].offset, text = "...: " }
      else
        edits[1] = insert_before(tokens, first, "...: ")
      end
      edits[2] = delete_with_blanks_before(source, tokens, last)
      out[#out + 1] = { row = "variadic_type", edits = edits }
    elseif p.optional and p.name == nil and tokens[first].kind == "?" then
      local after = blanks_after(source, stop_of(tokens, first))
      local taken: {string: boolean} = {}
      for _, other in ipairs(ty.params) do
        local other_name = other.name
        if other_name ~= nil then
          taken[other_name] = true
        end
      end
      local name = "arg" .. index
      while taken[name] do
        name = name .. "_"
      end
      out[#out + 1] = {
        row = "optional_type",
        edits = { { lo = tokens[first].offset, hi = after, text = name .. "?: " } },
      }
    end
  end
end

--- The rewrite of a union with `nil`.
local function union_rewrite(source: string, tokens: {Lexer.Token}, union: Ast.TypeUnion): Rewrite | nil
  local kept: {Ast.Type} = {}
  local nils: {Ast.Type} = {}
  for _, m in ipairs(union.members) do
    if m is Ast.TypeNil then
      nils[#nils + 1] = m
    else
      kept[#kept + 1] = m
    end
  end
  if #nils == 0 or #kept == 0 then
    return nil
  end
  local edits: {Edit} = {}
  local first_kept = bounds(kept[1])
  local _, last_kept = bounds(kept[#kept])
  local only_member = kept[1]
  local opens = #kept > 1 or only_member is Ast.TypeFunction or only_member is Ast.TypeUnion
  -- The `|` that joins each nil to its neighbours goes with it: the one before
  -- a nil, or the one after the first member when the nil is first.
  local members = union.members
  for i, m in ipairs(members) do
    if m is Ast.TypeNil then
      local at = bounds(m)
      if i == 1 then
        edits[#edits + 1] = delete_with_blanks_after(source, tokens, at)
        edits[#edits + 1] = delete_with_blanks_after(source, tokens, at + 1)
      else
        edits[#edits + 1] = delete_with_blanks_before(source, tokens, at - 1)
        edits[#edits + 1] = delete_with_blanks_before(source, tokens, at)
      end
    end
  end
  if #kept == 1 then
    local only = kept[1]
    local before = tokens[first_kept - 1]
    if (only is Ast.TypeFunction or only is Ast.TypeUnion) and before ~= nil and before.kind == "(" and
        tokens[last_kept + 1].kind == ")" then
      -- Already written `(function(): R) | nil` or `(A | B) | nil`: the `?` goes
      -- after the `)`.
      edits[#edits + 1] = insert_after(tokens, last_kept + 1, "?")
    elseif only is Ast.TypeFunction then
      edits[#edits + 1] = insert_before(tokens, first_kept, "(")
      edits[#edits + 1] = insert_after(tokens, last_kept, ")?")
    elseif not (only is Ast.TypeOptional) then
      edits[#edits + 1] = insert_after(tokens, last_kept, "?")
    end
  else
    edits[#edits + 1] = insert_before(tokens, first_kept, "(")
    edits[#edits + 1] = insert_after(tokens, last_kept, ")?")
  end
  return { row = "nil_union", edits = edits, opens = opens }
end

--- The rewrite of `local type X = record`: `local record X`.
local function declaration_rewrite(tokens: {Lexer.Token}, decl: Ast.Node, scope: Ast.Scope | nil,
                                   name: Ast.Binding): Rewrite | nil
  local first = bounds(decl)
  local at = scope ~= nil and first + 1 or first
  if tokens[at].text ~= "type" then
    return nil
  end
  local eq = name.last + 1
  local depth = 0
  while tokens[eq].kind ~= "$EOF$" do
    local text = tokens[eq].text
    if text == "<" then
      depth = depth + 1
    elseif text == ">" then
      depth = depth - 1
    elseif text == ">>" then
      depth = depth - 2
    elseif text == "=" and depth <= 0 then
      break
    end
    eq = eq + 1
  end
  local word = eq + 1
  if tokens[eq].text ~= "=" or tokens[word].kind ~= "identifier" or tokens[word].y ~= tokens[name.last].yend or
      tokens[eq].y ~= tokens[name.last].yend then
    return nil
  end
  local before = eq - 1
  return {
    row = "type_declaration",
    edits = {
      replace_token(tokens, at, tokens[word].text),
      { lo = stop_of(tokens, before), hi = stop_of(tokens, word), text = "" },
    },
  }
end

--- Whether token `i` is the first on its line.
local function starts_line(tokens: {Lexer.Token}, i: integer): boolean
  return i == 1 or tokens[i - 1].yend < tokens[i].y
end

--- Whether token `i` is the last on its line.
local function ends_line(tokens: {Lexer.Token}, i: integer): boolean
  local after = tokens[i + 1]
  return after == nil or after.kind == "$EOF$" or after.y > tokens[i].yend
end

--- The rewrites of a field: `metamethod` and `readonly` dropped.
local function field_rewrite(source: string, tokens: {Lexer.Token}, field: Ast.FieldDecl): Rewrite | nil
  local first = bounds(field)
  local name_first = bounds(field.name)
  if first < name_first and tokens[first].text == "metamethod" and tokens[first].kind == "identifier" then
    return { row = "metamethod", edits = { delete_with_blanks_after(source, tokens, first) } }
  end
  -- `readonly f: T` parses as a field named `readonly` whose type is cut short.
  if field.name.name == "readonly" and tokens[first].kind == "identifier" and first == name_first then
    local name = tokens[first + 1]
    local fits = false
    if name.kind == "identifier" then
      fits = tokens[first + 2].kind == ":" or tokens[first + 2].kind == "?"
    elseif name.kind == "[" then
      fits = tokens[first + 3].kind == "]" and (tokens[first + 4].kind == ":" or tokens[first + 4].kind == "?")
    end
    if fits and starts_line(tokens, first) and name.y == tokens[first].y then
      return { row = "readonly", edits = { delete_with_blanks_after(source, tokens, first) } }
    end
  end
  return nil
end

--- The token of the label `::continue::` that is a statement of `body`, or nil.
local function direct_label(tokens: {Lexer.Token}, body: Ast.Block): integer | nil
  for _, stat in ipairs(body.stats) do
    if stat is Ast.Error then
      local first, stop = bounds(stat)
      if first == stop and tokens[first].kind == "$ERR$" and find(tokens[first].text, "^::[ \t]*continue[ \t]*::$") then
        return first
      end
    end
  end
  return nil
end

--- The index of the `}` that closes the `{` at token `open`, or of the last token.
local function brace_end(tokens: {Lexer.Token}, open: integer): integer
  local depth = 0
  local i = open
  while tokens[i + 1] ~= nil and tokens[i].kind ~= "$EOF$" do
    local kind = tokens[i].kind
    if kind == "{" then
      depth = depth + 1
    elseif kind == "}" then
      depth = depth - 1
      if depth == 0 then
        return i
      end
    end
    i = i + 1
  end
  return i
end

-- classes

--- A record of the chunk and the statements `function R:m(...)` written for
--- it, in source order.
local record Owner
  record: Ast.Record
  methods: {Ast.Function}
  --- The `__close = function(self: R) ... end` item of a `local m: metatable<R> = { ... }` of the chunk.
  close: Ast.Named | nil
end

--- The name of the record that `f`, a statement `function R:m(...)`, is a
--- method of, or nil where it is no method this translator moves: a path of
--- other than two names, or a method with type parameters of its own.
local function method_owner(tokens: {Lexer.Token}, f: Ast.Function): string | nil
  local path = f.path
  if #path ~= 2 or #f.typeparams > 0 then
    return nil
  end
  local first = bounds(path[1])
  if tokens[first + 1].kind ~= ":" then
    return nil
  end
  return path[1].text
end

--- `text` with each line indented by two spaces, except a blank line and a
--- line that begins inside one of the byte `ranges` (the multi-line strings).
local function indented(text: string, ranges: {{integer}}): string
  local out: {string} = {}
  local pos = 1
  local k = 1
  local n = #text
  while pos <= n do
    local stop = after_line(text, pos)
    while ranges[k] ~= nil and ranges[k][2] < pos do
      k = k + 1
    end
    local within = ranges[k] ~= nil and ranges[k][1] < pos
    local line = sub(text, pos, stop - 1)
    if within or blank_line(text, pos) then
      out[#out + 1] = line
    else
      out[#out + 1] = "  " .. line
    end
    pos = stop
  end
  return concat(out)
end

--- The byte ranges of the tokens that run over several lines.
local function multiline_tokens(tokens: {Lexer.Token}): {{integer}}
  local out: {{integer}} = {}
  for _, t in ipairs(tokens) do
    if t.yend > t.y then
      out[#out + 1] = { t.offset, t.offset + t.length - 1 }
    end
  end
  return out
end

--- The tokens at which the statements of the chunk declare each name, in order.
local function declarations(stats: {Ast.Stat}): {string: {integer}}
  local at: {string: {integer}} = {}
  local function note(name: string, index: integer)
    local list = at[name] or {}
    list[#list + 1] = index
    at[name] = list
  end
  for _, s in ipairs(stats) do
    local first = bounds(s)
    if s is Ast.Local then
      for _, b in ipairs(s.bindings) do
        note(b.name, first)
      end
    elseif s is Ast.LocalFunction then
      note(s.name.name, first)
    elseif s is Ast.Record then
      note(s.name.name, first)
    elseif s is Ast.Interface then
      note(s.name.name, first)
    elseif s is Ast.Class then
      note(s.name.name, first)
    elseif s is Ast.Enum then
      note(s.name.name, first)
    elseif s is Ast.TypeAlias then
      note(s.name.name, first)
    elseif s is Ast.Import then
      note(s.name.name, first)
    end
  end
  return at
end

--- Whether `name` is declared between the tokens `lo` and `hi`, and whether
--- it is also declared before `lo`.
local function declared_between(at: {string: {integer}}, name: string, lo: integer, hi: integer): boolean, boolean
  local list = at[name]
  local between, before = false, false
  if list == nil then
    return between, before
  end
  for _, index in ipairs(list) do
    if index < lo then
      before = true
    elseif index < hi then
      between = true
    end
  end
  return between, before
end

--- `text` with whitespace runs made single spaces, to compare how two types are written.
local function squeezed(text: string): string
  return (text:gsub("%s+", " "))
end

--- The bytes of the tokens `a` to `b`, squeezed.
local function spelled(source: string, tokens: {Lexer.Token}, a: integer, b: integer): string
  return squeezed(sub(source, tokens[a].offset, stop_of(tokens, b) - 1))
end

--- An insertion into a source: `at` is the offset it goes before.
local record Insertion
  at: integer
  text: string
end

--- `source` from `lo` to `hi` with the insertions made.
local function splice(source: string, lo: integer, hi: integer, insertions: {Insertion}): string
  table.sort(insertions, function(a: Insertion, b: Insertion): boolean return a.at < b.at end)
  local out: {string} = {}
  local at = lo
  for _, ins in ipairs(insertions) do
    out[#out + 1] = sub(source, at, ins.at - 1)
    out[#out + 1] = ins.text
    at = ins.at
  end
  out[#out + 1] = sub(source, at, hi)
  return concat(out)
end

--- The offset of the `)` that closes the `(` at token `open`.
local function closer_of(tokens: {Lexer.Token}, open: integer): integer
  local depth = 0
  local i = open
  while tokens[i].kind ~= "$EOF$" do
    local kind = tokens[i].kind
    if kind == "(" then
      depth = depth + 1
    elseif kind == ")" then
      depth = depth - 1
      if depth == 0 then
        return i
      end
    end
    i = i + 1
  end
  return open
end

--- The types of the field `field` that declared method `f`, which the method
--- leaves out: a parameter without a type, and the return list. A type that
--- both write and that differs is a `signature` hazard. The field's first
--- parameter is the receiver.
local function carried_types(source: string, tokens: {Lexer.Token}, f: Ast.Function, declared: Ast.TypeFunction,
                             hazards: {Translate.Hazard}): {Insertion}
  local out: {Insertion} = {}
  local line = tokens[bounds(f)].y
  local class_name = f.path[1].text
  local function differs(what: string)
    hazards[#hazards + 1] = { kind = "signature", class = class_name, method = f.path[2].text, y = line, name = what }
  end
  local given = declared.params
  if #declared.typeparams > 0 then
    -- A generic field names a type the method cannot see: the method keeps
    -- what it wrote, and what it left out is reported.
    local omits = f.fn.rets == nil and declared.rets ~= nil
    for _, p in ipairs(f.fn.params) do
      omits = omits or p.type == nil
    end
    if omits then
      differs("generic")
    end
    return out
  end
  for i, p in ipairs(f.fn.params) do
    local want = given[i + 1]
    local own = p.type
    if want ~= nil and want.variadic == p.variadic then
      local a, b = bounds(want.type)
      local _, last = bounds(p)
      local question = want.optional and not p.optional
      -- A bare `...` is read with a missing type, which the field supplies.
      if own == nil or own is Ast.TypeError then
        out[#out + 1] = { at = stop_of(tokens, last), text = (question and "?" or "") .. ": " .. spelled(source, tokens, a, b) }
      else
        local oa, ob = bounds(own)
        if spelled(source, tokens, oa, ob) ~= spelled(source, tokens, a, b) then
          local pn = p.name
          differs(pn ~= nil and pn.name or "...")
        end
        local pn = p.name
        if question and pn ~= nil then
          out[#out + 1] = { at = stop_of(tokens, (bounds(pn))), text = "?" }
        end
      end
    end
  end
  local rets = declared.rets
  if rets ~= nil then
    local a, b = bounds(rets)
    local own = f.fn.rets
    if own == nil then
      local close = closer_of(tokens, (bounds(f.fn)))
      out[#out + 1] = { at = stop_of(tokens, close), text = ": " .. spelled(source, tokens, a, b) }
    else
      local oa, ob = bounds(own)
      if spelled(source, tokens, oa, ob) ~= spelled(source, tokens, a, b) then
        differs("return")
      end
    end
  end
  return out
end

-- TODO: write a record with no method, whose metatable holds only a `__close`, as a class with that method (the
-- `Descriptor` and `AppendFile` of cosmic/fs.tl), so that its `setmetatable(T, mt)` is a class literal too: the
-- rewrite takes only a record with `function R:m` statements, and the guards that remain are the ceiling of
-- `setmetatable_call`.

--- The first comment of a statement's doc, nil where it has none.
local function leading_doc(doc: {Lexer.Comment} | nil): Lexer.Comment | nil
  if doc ~= nil and #doc > 0 then
    return doc[1]
  end
  return nil
end

--- Whether the node tree under `root` reads the name `text` as a value (a `Name` expression, which a type is not).
local function reads_name(root: Ast.Node, text: string): boolean
  local stack: {Ast.Node} = { root }
  while #stack > 0 do
    local node = table.remove(stack)
    if node is Ast.Name and node.text == text then
      return true
    end
    Ast.children(node, function(child: Ast.Node)
      stack[#stack + 1] = child
    end)
  end
  return false
end

--- Whether the expression `e` makes a value with no effect and reads nothing at the time: a literal, a function, or a table of
--- those. The statement that declares such a value can stand earlier in the file than it does, as a function can.
local function pure(e: Ast.Node): boolean
  if e is Ast.Table then
    for _, item in ipairs(e.items) do
      if item is Ast.Positional then
        if not pure(item.value) then
          return false
        end
      elseif item is Ast.Named then
        if not pure(item.value) then
          return false
        end
      else
        return false
      end
    end
    return true
  end
  return e is Ast.FunctionLit or e is Ast.String or e is Ast.Integer or e is Ast.Float or e is Ast.Boolean or e is Ast.Nil
end

--- What moves: the name a statement declares, its doc comments, and what kind of declaration it is (`function`, `type` or
--- `value`); nil for a statement that is none of these.
local record Mover
  name: string
  doc: {Lexer.Comment} | nil
  kind: string
end

--- Whether every member of a record or an interface is a field: one that declares a type of its own (`type Process = Process`)
--- would name another where it stood than where it was written.
local function fields_only(members: {Ast.Member}): boolean
  for _, m in ipairs(members) do
    if not (m is Ast.FieldDecl) then
      return false
    end
  end
  return true
end

local function mover_of(s: Ast.Stat, methods: {string: boolean}): Mover | nil
  if s is Ast.LocalFunction then
    return { name = s.name.name, doc = s.name.doc, kind = "function" }
  elseif s is Ast.Record then
    if methods[s.name.name] ~= true and s.array == nil and #s.supers == 0 and fields_only(s.members) then
      return { name = s.name.name, doc = s.name.doc, kind = "type" }
    end
  elseif s is Ast.Interface then
    if #s.supers == 0 and fields_only(s.members) then
      return { name = s.name.name, doc = s.name.doc, kind = "type" }
    end
  elseif s is Ast.Enum then
    return { name = s.name.name, doc = s.name.doc, kind = "type" }
  elseif s is Ast.Local then
    local only = s.values[1]
    if #s.bindings == 1 and #s.values == 1 and only ~= nil and pure(only) then
      return { name = s.bindings[1].name, doc = s.bindings[1].doc, kind = "value" }
    end
  end
  return nil
end

--- The statements that stand between the record of `held` and its methods, that a method reads, to move above the record: the
--- class stands where its record did, so a method that read a function, a type or a value declared after the record would read
--- a global in the Lua the generator writes. A declaration moves with every one it reads that is declared between too (a
--- type named in a signature is read freely, the new grammar letting a signature name a type declared later). It does not
--- move when it reads a local that cannot move (one that is made by a call, say), or the record as a value (it would then be
--- above the declaration it reads), when it shares its lines with other code, when its name is declared again, or when
--- another record took it. A function or a table of functions and literals moves; a record with methods of its own does not.
--- The methods that read what stays still read another name, and are hazards. In source order.
--
-- TODO: place a method after the local it reads that a call makes, and a function that reads the record as a value, instead of
-- refusing the method as `unknown_variable`: the fork accepts the file. This waits on the switch (doc/plans/strict-teal.md, "the
-- switch"), which deletes this translator and has the tree's files spell the class where the locals stand.
local function hoists_of(tokens: {Lexer.Token}, stats: {Ast.Stat}, declared: {string: {integer}}, held: Owner,
                         taken: {string: boolean}, methods: {string: boolean}): {Ast.Stat}
  local rec = held.record
  local _, rec_last = bounds(rec)
  local record_name = rec.name.name
  local movers: {string: Mover} = {}
  local by_name: {string: Ast.Stat} = {}
  local types: {string: boolean} = {}
  for _, s in ipairs(stats) do
    local first, last = bounds(s)
    local mover = mover_of(s, methods)
    if mover ~= nil and first > rec_last and taken[mover.name] ~= true and starts_line(tokens, first) and
        ends_line(tokens, last) and #(declared[mover.name] or {}) == 1 then
      movers[mover.name] = mover
      by_name[mover.name] = s
    end
    if s is Ast.Record or s is Ast.Interface or s is Ast.Class or s is Ast.Enum or s is Ast.TypeAlias then
      types[s.name.name] = true
    end
  end
  --- The names the tree under `root` reads (a name, or the head of a type's path), that are declared between the record and the
  --- token `at`. A type that is declared later is read freely before the token `signature_end`, the end of a signature, which
  --- may name one declared later.
  local function reads(root: Ast.Node, at: integer, params: {Ast.Param}, signature_end: integer): {string}
    local own: {string: boolean} = {}
    for _, p in ipairs(params) do
      local pn = p.name
      if pn ~= nil then
        own[pn.name] = true
      end
    end
    local out: {string} = {}
    local seen: {string: boolean} = {}
    local stack: {Ast.Node} = { root }
    while #stack > 0 do
      local node = table.remove(stack)
      local name = ""
      if node is Ast.Name then
        name = node.text
      elseif node is Ast.TypeName then
        local head = node.path[1]
        if head ~= nil and not (node.first < signature_end and types[head] == true) then
          name = head
        end
      end
      if name ~= "" and declared[name] ~= nil and own[name] ~= true and seen[name] ~= true and taken[name] ~= true and
          declared_between(declared, name, rec_last, at) then
        seen[name] = true
        out[#out + 1] = name
      end
      Ast.children(node, function(child: Ast.Node)
        stack[#stack + 1] = child
      end)
    end
    return out
  end
  local deps: {string: {string}} = {}
  local movable: {string: boolean} = {}
  for name, mover in pairs(movers) do
    local s = by_name[name]
    local first = bounds(s)
    if s is Ast.LocalFunction then
      deps[name] = reads(s.fn, first, s.fn.params, (bounds(s.fn.body)))
    elseif mover.kind == "type" then
      -- A type names the types it is made of freely, and has no super to read where it stands.
      deps[name] = {}
    else
      deps[name] = reads(s, first, {}, first)
    end
    movable[name] = mover.kind == "type" or not reads_name(s, record_name)
  end
  -- A declaration that reads a local that cannot move cannot either: until no more fall out.
  local again = true
  while again do
    again = false
    for name, list in pairs(deps) do
      if movable[name] == true then
        for _, d in ipairs(list) do
          if movable[d] ~= true then
            movable[name] = false
            again = true
          end
        end
      end
    end
  end
  local wanted: {string: boolean} = {}
  local function want(name: string)
    if movable[name] == true and wanted[name] ~= true then
      wanted[name] = true
      for _, d in ipairs(deps[name]) do
        want(d)
      end
    end
  end
  for _, m in ipairs(held.methods) do
    local first = bounds(m)
    for _, name in ipairs(reads(m.fn, first, m.fn.params, (bounds(m.fn.body)))) do
      want(name)
    end
  end
  local out: {Ast.Stat} = {}
  for _, s in ipairs(stats) do
    local mover = mover_of(s, methods)
    if mover ~= nil and wanted[mover.name] == true and by_name[mover.name] == s then
      out[#out + 1] = s
    end
  end
  return out
end

--- The rewrite that moves the methods written for `held.record` into it.
--- Nil where a method or the record is not written so that the lines can
--- be cut: a statement that shares its line with other code.
local function class_rewrite(source: string, tokens: {Lexer.Token}, declared: {string: {integer}}, held: Owner,
                             strings: {{integer}}, hazards: {Translate.Hazard}, hoisted: {Ast.Stat},
                             taken: {string: boolean}, methods: {string: boolean}): Rewrite | nil
  local rec = held.record
  local rec_first, rec_last = bounds(rec)
  local word = rec.scope ~= nil and rec_first + 1 or rec_first
  if rec.array ~= nil or tokens[word].text ~= "record" or not starts_line(tokens, rec_last) then
    return nil
  end
  for _, m in ipairs(rec.members) do
    if m is Ast.Userdata then
      return nil
    end
  end
  local fields: {string: Ast.FieldDecl} = {}
  for _, m in ipairs(rec.members) do
    if m is Ast.FieldDecl then
      fields[m.name.name] = m
    end
  end
  local edits: {Edit} = {}
  edits[1] = replace_token(tokens, word, "class")
  local pieces: {string} = {}
  local found: {Translate.Hazard} = {}
  -- The functions the methods read that stand between the record and them go above the record, with their docs.
  local moved: {string: boolean} = {}
  local lifted: {string} = {}
  for _, s in ipairs(hoisted) do
    local first, last = bounds(s)
    local mover = mover_of(s, methods)
    local s_first: Lexer.Comment | nil = nil
    if mover ~= nil then
      s_first = leading_doc(mover.doc)
    end
    local lo = line_start(source, s_first ~= nil and s_first.offset or tokens[first].offset)
    local hi = after_line(source, tokens[last].offset)
    lifted[#lifted + 1] = sub(source, lo, hi - 1) .. "\n"
    local cut = hi
    if lo > 1 and cut <= #source and blank_line(source, cut) and blank_line(source, line_start(source, lo - 1)) then
      cut = after_line(source, cut)
    end
    edits[#edits + 1] = { lo = lo, hi = cut, text = "" }
    if mover ~= nil then
      moved[mover.name] = true
    end
  end
  if #lifted > 0 then
    local rec_doc_first = leading_doc(rec.name.doc)
    local top = line_start(source, rec_doc_first ~= nil and rec_doc_first.offset or tokens[rec_first].offset)
    edits[#edits + 1] = { lo = top, hi = top, text = concat(lifted) }
  end
  for _, f in ipairs(held.methods) do
    local first, last = bounds(f)
    local open = bounds(f.fn)
    local name = f.path[2].text
    local f_doc = f.doc
    local doc_first = f_doc ~= nil and #f_doc > 0 and f_doc[1] or nil
    local top = doc_first ~= nil and doc_first.offset or tokens[first].offset
    if not (starts_line(tokens, first) and ends_line(tokens, last) and tokens[open].kind == "(") or
        blanks_before(source, top) ~= line_start(source, top) then
      return nil
    end
    local lo = line_start(source, top)
    local hi = after_line(source, tokens[last].offset)
    local params = f.fn.params
    local header = "function " .. name .. "(self" .. (#params > 0 and ", " or "")
    local head_lo, head_hi = tokens[first].offset, stop_of(tokens, open)
    local field = fields[name]
    local carried: {Insertion} = {}
    local declared_type = field ~= nil and field.type or nil
    if declared_type ~= nil and declared_type is Ast.TypeFunction then
      carried = carried_types(source, tokens, f, declared_type, found)
    end
    local signature = splice(source, head_hi, hi - 1, carried)
    local slice = sub(source, lo, head_lo - 1) .. header .. signature
    -- The multi-line strings of the body, in the slice's own offsets.
    local shift = (head_lo - lo) + #header + 1 - head_hi + (#signature - (hi - head_hi))
    local ranges: {{integer}} = {}
    for _, r in ipairs(strings) do
      if r[1] >= head_hi and r[2] < hi then
        ranges[#ranges + 1] = { r[1] + shift, r[2] + shift }
      end
    end
    local docs = ""
    if field ~= nil then
      local field_first, field_last = bounds(field)
      local field_doc = field.doc
      local first_doc = field_doc ~= nil and #field_doc > 0 and field_doc[1] or nil
      local flo = line_start(source, first_doc ~= nil and first_doc.offset or tokens[field_first].offset)
      local fhi = after_line(source, tokens[field_last].offset)
      docs = sub(source, flo, line_start(source, tokens[field_first].offset) - 1)
      -- A comment after the field on its last line goes with its docs.
      local trailing = sub(source, stop_of(tokens, field_last), fhi - 1):match("^%s*(%-%-.-)%s*$")
      if trailing ~= nil then
        docs = docs .. "  " .. trailing .. "\n"
      end
      edits[#edits + 1] = { lo = flo, hi = fhi, text = "" }
    end
    pieces[#pieces + 1] = ((#pieces == 0 and #rec.members == 0) and "" or "\n") .. docs .. indented(slice, ranges)
    -- Cut the statement's lines, and a blank line when two would meet.
    local cut = hi
    if lo > 1 and cut <= #source and blank_line(source, cut) and blank_line(source, line_start(source, lo - 1)) then
      cut = after_line(source, cut)
    end
    edits[#edits + 1] = { lo = lo, hi = cut, text = "" }
    -- A name declared between the record and the method that the method reads.
    local own: {string: boolean} = {}
    for _, p in ipairs(params) do
      local pn = p.name
      if pn ~= nil then
        own[pn.name] = true
      end
    end
    local reported: {string: boolean} = {}
    for i = first, last do
      local t = tokens[i]
      local prev = tokens[i - 1]
      if t.kind == "identifier" and declared[t.text] ~= nil and not own[t.text] and not reported[t.text] and
          moved[t.text] ~= true and taken[t.text] ~= true and not (prev ~= nil and (prev.kind == "." or prev.kind == ":")) then
        local between, before = declared_between(declared, t.text, rec_last, first)
        if between then
          reported[t.text] = true
          found[#found + 1] = {
            kind = before and "shadow" or "scope", class = rec.name.name, method = name, y = tokens[first].y,
            name = t.text,
          }
        end
      end
    end
  end
  local close = held.close
  if close ~= nil then
    local value = close.value
    local first, last = bounds(close)
    if value is Ast.FunctionLit and #value.fn.params > 0 and starts_line(tokens, first) and tokens[last + 1] ~= nil and
        tokens[last + 1].kind == "," and ends_line(tokens, last + 1) then
      local fl, ll = bounds(value)
      local pf, pl = bounds(value.fn.params[1])
      local indent = sub(source, line_start(source, tokens[first].offset), tokens[first].offset - 1)
      local text = indent .. "function __close" .. sub(source, stop_of(tokens, fl), tokens[pf].offset - 1) ..
        tokens[pf].text .. sub(source, stop_of(tokens, pl), stop_of(tokens, ll) - 1) .. "\n"
      -- The field `metamethod __close: T` declared goes, its docs to the method.
      local docs = ""
      local field = fields["__close"]
      if field ~= nil then
        local field_first, field_last = bounds(field)
        local field_doc = field.doc
        local first_doc = field_doc ~= nil and #field_doc > 0 and field_doc[1] or nil
        local flo = line_start(source, first_doc ~= nil and first_doc.offset or tokens[field_first].offset)
        local fhi = after_line(source, tokens[field_last].offset)
        docs = sub(source, flo, line_start(source, tokens[field_first].offset) - 1)
        edits[#edits + 1] = { lo = flo, hi = fhi, text = "" }
      end
      pieces[#pieces + 1] = ((#pieces == 0 and #rec.members == 0) and "" or "\n") .. docs .. text
      edits[#edits + 1] = {
        lo = line_start(source, tokens[first].offset), hi = after_line(source, tokens[last + 1].offset), text = "",
      }
      local own: {string: boolean} = {}
      for _, p in ipairs(value.fn.params) do
        local pn = p.name
        if pn ~= nil then
          own[pn.name] = true
        end
      end
      local reported: {string: boolean} = {}
      for i = fl, ll do
        local t = tokens[i]
        local prev = tokens[i - 1]
        if t.kind == "identifier" and declared[t.text] ~= nil and not own[t.text] and not reported[t.text] and
            moved[t.text] ~= true and taken[t.text] ~= true and not (prev ~= nil and (prev.kind == "." or prev.kind == ":")) then
          local between, before = declared_between(declared, t.text, rec_last, fl)
          if between then
            reported[t.text] = true
            found[#found + 1] = {
              kind = before and "shadow" or "scope", class = rec.name.name, method = "__close", y = tokens[fl].y,
              name = t.text,
            }
          end
        end
      end
    end
  end
  local at = line_start(source, tokens[rec_last].offset)
  edits[#edits + 1] = { lo = at, hi = at, text = concat(pieces) }
  for _, h in ipairs(found) do
    hazards[#hazards + 1] = h
  end
  return { row = "class", edits = edits }
end

--- The class rewrites of a chunk: each record that has methods written for
--- it, with those methods moved into it.
local function class_rewrites(source: string, parsed: Parser.Parsed, hazards: {Translate.Hazard}): {Rewrite}
  local chunk = parsed.chunk
  local tokens = chunk.tokens
  local stats = chunk.body.stats
  local owners: {string: Owner} = {}
  local times: {string: integer} = {}
  for _, s in ipairs(stats) do
    if s is Ast.Record then
      times[s.name.name] = (times[s.name.name] or 0) + 1
      owners[s.name.name] = { record = s, methods = {}, close = nil }
    elseif s is Ast.Interface or s is Ast.Class or s is Ast.Enum or s is Ast.TypeAlias or s is Ast.Import then
      times[s.name.name] = (times[s.name.name] or 0) + 1
    end
  end
  for _, s in ipairs(stats) do
    local annotation = s is Ast.Local and #s.types == 1 and s.types[1] or nil
    local literal = s is Ast.Local and #s.values == 1 and s.values[1] or nil
    if annotation ~= nil and annotation is Ast.TypeName and #annotation.path == 1 and annotation.path[1] == "metatable" and
        #annotation.args == 1 and literal ~= nil and literal is Ast.Table then
      local target = annotation.args[1]
      local held = target is Ast.TypeName and #target.path == 1 and owners[target.path[1]] or nil
      -- A class has the metamethods `__close` and `__tostring` and no other: a metatable that holds more keeps its
      -- `__close`, since a value made with it would lose the method that moved.
      local only = true
      for _, item in ipairs(literal.items) do
        only = only and item is Ast.Named and (item.name == "__index" or item.name == "__close")
      end
      if held ~= nil and only then
        for _, item in ipairs(literal.items) do
          if item is Ast.Named and item.name == "__close" and held.close == nil then
            held.close = item
          end
        end
      end
    end
  end
  local order: {Owner} = {}
  for _, s in ipairs(stats) do
    if s is Ast.Function then
      local name = method_owner(tokens, s)
      local held = name ~= nil and owners[name] or nil
      if name ~= nil and held ~= nil and times[name] == 1 then
        if #held.methods == 0 then
          order[#order + 1] = held
        end
        held.methods[#held.methods + 1] = s
      end
    end
  end
  local out: {Rewrite} = {}
  if #order == 0 then
    return out
  end
  local strings = multiline_tokens(tokens)
  local declared = declarations(stats)
  -- The records in the order they stand: a function that moves above a record is above every record after it as well, and
  -- one an earlier record took is not a name between a later record and its methods.
  table.sort(order, function(a: Owner, b: Owner): boolean
    return (bounds(a.record)) < (bounds(b.record))
  end)
  local taken: {string: boolean} = {}
  -- The records that get methods, which are classes and stay where they are.
  local with_methods: {string: boolean} = {}
  for _, held in ipairs(order) do
    with_methods[held.record.name.name] = true
  end
  for _, held in ipairs(order) do
    local lifts = hoists_of(tokens, stats, declared, held, taken, with_methods)
    local made = class_rewrite(source, tokens, declared, held, strings, hazards, lifts, taken, with_methods)
    if made ~= nil then
      out[#out + 1] = made
      for _, lift in ipairs(lifts) do
        local mover = mover_of(lift, with_methods)
        if mover ~= nil then
          taken[mover.name] = true
        end
      end
    end
  end
  return out
end

-- class literals

--- A call `setmetatable(T, mt)` that can be written as the class literal `T`.
local record Literal
  call: Ast.Call
  literal: Ast.Node
  --- The binding of the local it initializes, which gets the class as its type where it has none written.
  annotate: Ast.Binding | nil
  class: string
end

--- A metatable local of the file that is the metatable of a class: `local mt: metatable<R> = { __index = R }`, `R` a
--- class of the file.
local record ClassMetatable
  --- The class's name.
  class: string
  stat: Ast.Local
  binding: Ast.Binding
  --- The calls `setmetatable(T, mt)` that can be written as `T`.
  calls: {Literal}
end

--- The return list of the function being walked, nil where it writes none.
local record Returning
  rets: Ast.Rets | nil
end

--- The name `t` writes alone as a type with no arguments, or nil.
local function plain_type(t: Ast.Type | nil): string | nil
  if t ~= nil and t is Ast.TypeName and #t.path == 1 and #t.args == 0 then
    return t.path[1]
  end
  return nil
end

--- The class `{ __index = R }` is the metatable of, for a literal that holds that item alone and nothing else.
local function index_class(literal: Ast.Table, classes: {string: boolean}): string | nil
  local items = literal.items
  local item = items[1]
  if #items == 1 and item is Ast.Named and item.name == "__index" then
    local value = item.value
    if value is Ast.Name and classes[value.text] then
      return value.text
    end
  end
  return nil
end

--- The edit that removes the lines of the statement `s`, its docs with it, and a blank line where two would meet; nil
--- where it shares its lines with other code.
local function statement_cut(source: string, tokens: {Lexer.Token}, s: Ast.Local, binding: Ast.Binding): Edit | nil
  local first, last = bounds(s)
  if not (starts_line(tokens, first) and ends_line(tokens, last)) then
    return nil
  end
  local doc = binding.doc
  local doc_first = doc ~= nil and #doc > 0 and doc[1] or nil
  local lo = line_start(source, doc_first ~= nil and doc_first.offset or tokens[first].offset)
  local hi = after_line(source, tokens[last].offset)
  if lo > 1 and hi <= #source and blank_line(source, hi) and blank_line(source, line_start(source, lo - 1)) then
    hi = after_line(source, hi)
  end
  return { lo = lo, hi = hi, text = "" }
end

--- The class literals of a chunk: each `setmetatable(T, mt)` whose table `T` is a literal and whose `mt` is the
--- metatable of a class of the file (a local `metatable<R> = { __index = R }`, or the literal `{ __index = R }`), in a
--- place that gives the class as the literal's type: the only value of a local declared `R` or with no type, which
--- then is declared `R`, or of a `return` in a function that answers `R`. The call is written as `T`. A metatable
--- local goes with its calls when every use of its name is one of them; one used otherwise stays, with its calls.
local function literal_rewrites(source: string, parsed: Parser.Parsed): {Rewrite}
  local chunk = parsed.chunk
  local tokens = chunk.tokens
  local stats = chunk.body.stats
  local declared = declarations(stats)
  local classes: {string: boolean} = {}
  for _, s in ipairs(stats) do
    if s is Ast.Class and #(declared[s.name.name] or {}) == 1 then
      classes[s.name.name] = true
    end
  end
  local out: {Rewrite} = {}
  if next(classes) == nil then
    return out
  end
  local metatables: {string: ClassMetatable} = {}
  local order: {string} = {}
  for _, s in ipairs(stats) do
    if s is Ast.Local and #s.bindings == 1 and #s.types == 1 and #s.values == 1 then
      local annotation, literal = s.types[1], s.values[1]
      local binding = s.bindings[1]
      if annotation is Ast.TypeName and #annotation.path == 1 and annotation.path[1] == "metatable" and
          #annotation.args == 1 and literal is Ast.Table and #(declared[binding.name] or {}) == 1 then
        local class = index_class(literal, classes)
        local target = plain_type(annotation.args[1])
        if class ~= nil and class == target then
          metatables[binding.name] = { class = class, stat = s, binding = binding, calls = {} }
          order[#order + 1] = binding.name
        end
      end
    end
  end
  local inline: {Literal} = {}
  local returns: {Returning} = {}
  --- Notes the call `e` as a class literal if it is one, where the place wants the class `accepts` says.
  local function consider(e: Ast.Exp, accepts: function(class: string): boolean, annotate: Ast.Binding | nil)
    if not (e is Ast.Call) then
      return
    end
    local callee = e.callee
    local args = e.args
    local made, second = args[1], args[2]
    if not (callee is Ast.Name and callee.text == "setmetatable" and #args == 2 and made is Ast.Table and
        tokens[e.first + 1].kind == "(") then
      return
    end
    local held: ClassMetatable | nil = nil
    local class: string | nil = nil
    if second is Ast.Name then
      held = metatables[second.text]
      class = held ~= nil and held.class or nil
    elseif second is Ast.Table then
      class = index_class(second, classes)
    end
    if class == nil or not accepts(class) then
      return
    end
    -- A comment between the table and the end of the call would go with the metatable.
    if find(sub(source, stop_of(tokens, made.last), stop_of(tokens, e.last)), "--", 1, true) ~= nil then
      return
    end
    local noted: Literal = { call = e, literal = made, annotate = annotate, class = class }
    if held ~= nil then
      held.calls[#held.calls + 1] = noted
    else
      inline[#inline + 1] = noted
    end
  end
  local function enter(node: Ast.Node)
    if node is Ast.Fn then
      returns[#returns + 1] = { rets = node.rets }
    elseif node is Ast.Method then
      returns[#returns + 1] = { rets = node.rets }
    elseif node is Ast.Local and #node.bindings == 1 and #node.values == 1 then
      local given = node.types[1]
      consider(node.values[1], function(class: string): boolean
        return given == nil or plain_type(given) == class
      end, given == nil and node.bindings[1] or nil)
    elseif node is Ast.Return and #node.values == 1 then
      local frame = returns[#returns]
      local rets = frame ~= nil and frame.rets or nil
      consider(node.values[1], function(class: string): boolean
        if rets == nil or #rets.lists ~= 1 or rets.variadic then
          return false
        end
        local list = rets.lists[1]
        local item = list[1]
        return #list == 1 and not (item is Ast.Narrows) and plain_type(item) == class
      end, nil)
    end
  end
  local function leave(node: Ast.Node)
    if node is Ast.Fn or node is Ast.Method then
      returns[#returns] = nil
    end
  end
  walk(chunk.body, enter, leave)
  local references: {string: integer} = {}
  for _, t in ipairs(tokens) do
    if t.kind == "identifier" and metatables[t.text] ~= nil then
      references[t.text] = (references[t.text] or 0) + 1
    end
  end
  --- The edits that write the call of `l` as its table.
  local function call_edits(l: Literal): {Edit}
    local edits: {Edit} = {
      { lo = tokens[l.call.first].offset, hi = stop_of(tokens, l.call.first + 1), text = "" },
      { lo = stop_of(tokens, l.literal.last), hi = stop_of(tokens, l.call.last), text = "" },
    }
    local binding = l.annotate
    if binding ~= nil then
      local _, last = bounds(binding)
      edits[#edits + 1] = insert_after(tokens, last, ": " .. l.class)
    end
    return edits
  end
  for _, name in ipairs(order) do
    local held = metatables[name]
    local cut = statement_cut(source, tokens, held.stat, held.binding)
    -- The declaration is one reference of its name, and each call one.
    if #held.calls > 0 and cut ~= nil and references[name] == 1 + #held.calls then
      local edits: {Edit} = { cut }
      for _, l in ipairs(held.calls) do
        for _, e in ipairs(call_edits(l)) do
          edits[#edits + 1] = e
        end
      end
      out[#out + 1] = { row = "class_literal", edits = edits, removed = name }
    end
  end
  for _, l in ipairs(inline) do
    out[#out + 1] = { row = "class_literal", edits = call_edits(l) }
  end
  return out
end

-- mut

--- The record or class a type names when it is a plain name, looking through `?`.
local function named_record(t: Ast.Type | nil): string | nil
  if t == nil then
    return nil
  end
  local cur: Ast.Type = t
  if cur is Ast.TypeOptional then
    cur = cur.inner
  end
  if cur is Ast.TypeName and #cur.path == 1 then
    return cur.path[1]
  end
  return nil
end

--- The array or map a type is, looking through `?`.
local function collection_of(t: Ast.Type | nil): Ast.Type | nil
  if t == nil then
    return nil
  end
  local cur: Ast.Type = t
  if cur is Ast.TypeOptional then
    cur = cur.inner
  end
  if cur is Ast.TypeArray or cur is Ast.TypeMap then
    return cur
  end
  return nil
end

--- The last component of a dotted name.
local function last_name(dotted: string): string
  return dotted:match("([^%.]+)$") or dotted
end

--- What a name stands for in a block: the record it is declared as, and the
--- parameter it is.
local record Entry
  record_name: string | nil
  param: Ast.Param | nil
end

--- The walk of [`mut_tracker`]: `enter` and `leave` see each node of a tree
--- walked, and `finish` answers the rewrites.
local record MutTracker
  enter: function(Ast.Node)
  leave: function(Ast.Node)
  finish: function(): {Rewrite}
end

local TABLE_WRITES <const>: {string: boolean} = { insert = true, remove = true, sort = true, move = true }

--- The rewrites that write `mut` where the syntax shows a place changed:
--- a field of a record or class that a name declared as that record assigns,
--- the collection a field holds when an index of it is assigned or a `table`
--- function changes it, and a parameter that is a collection and is changed
--- the same way. A name is taken for a record only where it is bound, in the
--- block that sees it, as a parameter or a local with a plain type name (or
--- as `self` in a method of a class), so no change is credited to the wrong
--- record.
---
-- TODO: write `mut` for the writes that the syntax cannot attribute (a call's
-- result, a field of a field) and for a collection passed on to a function that
-- changes it, once the new checker's type report resolves the record and field
-- of each assignment target and the `mut` parameters of each callee.
local function mut_tracker(tokens: {Lexer.Token}, hazards: {Translate.Hazard}, interfaces: {Translate.Interface}): MutTracker
  local declared: {string: {string: Ast.FieldDecl}} = {}
  local seen: {string: integer} = {}
  local assigned: {string: boolean} = {}
  local changed: {string: boolean} = {}
  local changed_params: {Ast.Param: boolean} = {}
  -- The blocks being walked, innermost last, each with the names it binds.
  local scopes: {{string: Entry}} = {}
  -- The names a block binds before its statements: a function's parameters,
  -- a loop's variables, a `match` arm's bindings.
  local arriving: {Ast.Block: {string: Entry}} = {}
  local classes: {string} = {}
  -- The interfaces (or the one interface) each type of the file names after `is`.
  local supers: {string: {string}} = {}
  -- The first token of each type of the file.
  local starts: {string: integer} = {}
  -- The record a method written as `function R:m()` is of, by its function.
  local owner_of: {Ast.Fn: string} = {}

  local function binder(name: string): Entry | nil
    for i = #scopes, 1, -1 do
      local found = scopes[i][name]
      if found ~= nil then
        return found
      end
    end
    return nil
  end

  local function bind(name: string, record_name: string | nil, param?: Ast.Param)
    local scope = scopes[#scopes]
    if scope ~= nil then
      scope[name] = { record_name = record_name, param = param }
    end
  end

  --- Names that a block gets before its statements.
  local function arrive(body: Ast.Block, names: {string: Entry})
    arriving[body] = names
  end

  local function param_entries(params: {Ast.Param}, self_record: string | nil, implicit_self: string | nil): {string: Entry}
    local names: {string: Entry} = {}
    if implicit_self ~= nil then
      names.self = { record_name = implicit_self }
    end
    for _, p in ipairs(params) do
      local name = p.name
      if name ~= nil then
        local record_name = named_record(p.type)
        if record_name == nil and name.name == "self" and p.type == nil then
          record_name = self_record
        end
        names[name.name] = { record_name = record_name, param = p }
      end
    end
    return names
  end

  --- The key of a field of a record in `assigned` and `changed`.
  local function field_key(e: Ast.Field): string | nil
    local object = e.object
    if not (object is Ast.Name) then
      return nil
    end
    local entry = binder(object.text)
    local record_name = entry ~= nil and entry.record_name or nil
    if record_name == nil then
      return nil
    end
    return record_name .. "\0" .. e.name
  end

  --- Credits a change to the collection that `e` names: a parameter, or a
  --- field of a record.
  local function collection_changed(e: Ast.Exp)
    if e is Ast.Name then
      local entry = binder(e.text)
      local param = entry ~= nil and entry.param or nil
      if param ~= nil then
        changed_params[param] = true
      end
    elseif e is Ast.Field then
      local key = field_key(e)
      if key ~= nil then
        changed[key] = true
      end
    end
  end

  local function enter(node: Ast.Node)
    local base: Ast.Base = node
    local kind = base.kind
    if kind == "Block" then
      local names = node is Ast.Block and arriving[node] or nil
      scopes[#scopes + 1] = names or {}
    elseif kind == "Local" then
      if node is Ast.Local then
        local aligned = #node.types == #node.bindings
        for i, b in ipairs(node.bindings) do
          bind(b.name, aligned and named_record(node.types[i]) or nil)
        end
      end
    elseif kind == "LocalFunction" then
      if node is Ast.LocalFunction then
        bind(node.name.name, nil)
      end
    elseif kind == "ForNum" then
      if node is Ast.ForNum then
        arrive(node.body, { [node.var.name] = {} })
      end
    elseif kind == "ForIn" then
      if node is Ast.ForIn then
        local names: {string: Entry} = {}
        for _, b in ipairs(node.vars) do
          names[b.name] = {}
        end
        arrive(node.body, names)
      end
    elseif kind == "MatchArm" then
      if node is Ast.MatchArm then
        local names: {string: Entry} = {}
        for _, pat in ipairs(node.pats) do
          if pat is Ast.PatBind then
            names[pat.name.name] = {}
          end
        end
        arrive(node.body, names)
      end
    elseif kind == "Function" then
      if node is Ast.Function then
        local path = node.path
        if #path == 2 and tokens[bounds(path[1]) + 1].kind == ":" then
          owner_of[node.fn] = path[1].text
        end
      end
    elseif kind == "Fn" then
      if node is Ast.Fn then
        arrive(node.body, param_entries(node.params, nil, owner_of[node]))
      end
    elseif kind == "Method" then
      if node is Ast.Method then
        arrive(node.body, param_entries(node.params, classes[#classes], nil))
      end
    elseif kind == "Record" or kind == "Class" or kind == "Interface" then
      if node is Ast.Record or node is Ast.Class or node is Ast.Interface then
        local name = node.name.name
        seen[name] = (seen[name] or 0) + 1
        local fields: {string: Ast.FieldDecl} = {}
        for _, m in ipairs(node.members) do
          if m is Ast.FieldDecl then
            fields[m.name.name] = m
          end
        end
        declared[name] = fields
        local names: {string} = {}
        for _, super in ipairs(node.supers) do
          names[#names + 1] = table.concat(super.path, ".")
        end
        supers[name] = names
        starts[name] = bounds(node)
        if node is Ast.Class then
          classes[#classes + 1] = name
        end
        if node is Ast.Interface then
          local listed: {string} = {}
          for field_name in pairs(fields) do
            listed[#listed + 1] = field_name
          end
          table.sort(listed)
          local parents: {string} = {}
          for _, super in ipairs(names) do
            parents[#parents + 1] = last_name(super)
          end
          interfaces[#interfaces + 1] = { name = name, fields = listed, supers = parents }
        end
      end
    elseif kind == "Assign" then
      if node is Ast.Assign then
        for _, target in ipairs(node.targets) do
          if target is Ast.Field then
            local key = field_key(target)
            if key ~= nil then
              assigned[key] = true
            end
          elseif target is Ast.Index then
            collection_changed(target.object)
          end
        end
      end
    elseif kind == "Call" then
      if node is Ast.Call then
        local callee = node.callee
        if callee is Ast.Field and TABLE_WRITES[callee.name] then
          local object = callee.object
          if object is Ast.Name and object.text == "table" and binder("table") == nil then
            -- `insert`, `remove` and `sort` change their first argument;
            -- `move` its fifth, and its first when it has no fifth.
            local target = node.args[1]
            if callee.name == "move" and node.args[5] ~= nil then
              target = node.args[5]
            end
            if target ~= nil then
              collection_changed(target)
            end
          end
        end
      end
    end
  end

  local function leave(node: Ast.Node)
    local base: Ast.Base = node
    local kind = base.kind
    if kind == "Block" then
      scopes[#scopes] = nil
    elseif kind == "Class" then
      classes[#classes] = nil
    end
  end

  local function finish(): {Rewrite}
    local out: {Rewrite} = {}
    local function write(t: Ast.Type | nil, row: string)
      local collection = collection_of(t)
      if collection ~= nil then
        local first = bounds(collection)
        out[#out + 1] = { row = row, edits = { insert_before(tokens, first, "mut ") } }
      end
    end
    -- A record declares a field `mut` exactly when its interface does: a
    -- mark goes up to the interfaces of the file that declare the field, and
    -- from each of those down to the types that implement it and declare it
    -- too. A super written with a qualifier ([`Stream.Reader`]) is the type of
    -- the file with its last name, if the file has one.
    local function resolved(super: string): string | nil
      local short = last_name(super)
      return seen[short] == 1 and short or nil
    end
    local implementers: {string: {string}} = {}
    for name, list in pairs(supers) do
      for _, super in ipairs(list) do
        local parent = resolved(super)
        if parent ~= nil then
          local held = implementers[parent] or {}
          held[#held + 1] = name
          implementers[parent] = held
        end
      end
    end
    local function single(name: string, field: string): Ast.FieldDecl | nil
      local fields = declared[name]
      return seen[name] == 1 and fields ~= nil and fields[field] or nil
    end
    local function spread(keys: {string: boolean}, collection: boolean): {Ast.FieldDecl: string}
      local marked: {Ast.FieldDecl: string} = {}
      for key in pairs(keys) do
        local cut = find(key, "\0", 1, true)
        local start, field = sub(key, 1, cut - 1), sub(key, cut + 1)
        -- Up: the start and its interfaces, through those that lack the field.
        local up: {string} = { start }
        local visited: {string: boolean} = { [start] = true }
        local declarers: {string} = {}
        local outside: {string} = {}
        local at = 1
        while at <= #up do
          local name = up[at]
          at = at + 1
          if single(name, field) ~= nil then
            declarers[#declarers + 1] = name
          end
          for _, super in ipairs(supers[name] or {}) do
            local parent = resolved(super)
            if parent == nil then
              outside[#outside + 1] = super
            elseif not visited[parent] then
              visited[parent] = true
              up[#up + 1] = parent
            end
          end
        end
        -- Down: from each type that declares the field, those that implement it.
        for _, declarer in ipairs(declarers) do
          local down: {string} = { declarer }
          local reached: {string: boolean} = { [declarer] = true }
          local d = 1
          while d <= #down do
            local name = down[d]
            d = d + 1
            local decl = single(name, field)
            if decl ~= nil then
              marked[decl] = name
            end
            for _, user in ipairs(implementers[name] or {}) do
              if not reached[user] then
                reached[user] = true
                down[#down + 1] = user
              end
            end
          end
        end
        -- An interface of another file may declare the field too.
        local own = single(start, field)
        local needed = own ~= nil and (collection and collection_of(own.type) ~= nil or not collection and not own.mut)
        if (own ~= nil and needed) or #declarers == 0 then
          local where = own ~= nil and bounds(own) or starts[start]
          for _, super in ipairs(outside) do
            if where ~= nil then
              hazards[#hazards + 1] = {
                kind = "interface", class = start, method = field, y = tokens[where].y, name = super,
              }
            end
          end
        end
      end
      return marked
    end
    for decl in pairs(spread(assigned, false)) do
      if not decl.mut then
        out[#out + 1] = { row = "mut_field", edits = { insert_before(tokens, bounds(decl), "mut ") } }
      end
    end
    for decl in pairs(spread(changed, true)) do
      write(decl.type, "mut_collection")
    end
    for param in pairs(changed_params) do
      write(param.type, "mut_param")
    end
    -- Tables have no order, and a rewrite that clashes with another is left to
    -- the next read: sort so that the same source always gives the same text.
    table.sort(out, function(a: Rewrite, b: Rewrite): boolean
      return a.edits[1].lo < b.edits[1].lo
    end)
    return out
  end

  return { enter = enter, leave = leave, finish = finish }
end

-- the rewrites of one read

--- A loop whose body may be left by `continue`, or a function boundary.
--- The words after which a `;` may end a statement.
local BLOCK_WORDS <const>: {string: boolean} = {
  ["function"] = true, ["do"] = true, ["if"] = true, ["repeat"] = true, ["while"] = true, ["for"] = true,
}

--- A block being walked, or the boundary of a function, which no `goto` crosses.
local record Frame
  barrier: boolean
  --- Whether the block is the body of a loop.
  loop: boolean
  --- The token of the `::continue::` that is one of its statements.
  label: integer | nil
end

--- The `goto continue` statements that jump to one label, and whether the
--- label ends the body of the innermost loop around each of them.
local record Jumps
  ends_loop: boolean
  gotos: {integer}
end

--- Every rewrite of the first kind (all but the class) that the tree and
--- tokens of `parsed` call for.
local function collect(source: string, parsed: Parser.Parsed, hazards: {Translate.Hazard},
                       interfaces: {Translate.Interface}): {Rewrite}
  local chunk = parsed.chunk
  local tokens = chunk.tokens
  local out: {Rewrite} = {}
  local semicolons: {integer} = {}
  for i = 1, #tokens do
    local t = tokens[i]
    local kind = t.kind
    if kind == "integer" or kind == "number" then
      local made = number_rewrite(tokens, i)
      if made ~= nil then
        out[#out + 1] = made
      end
    elseif kind == "$ERR$" and t.text == ";" then
      semicolons[#semicolons + 1] = i
    end
  end
  for _, e in ipairs(parsed.errors) do
    if e.code == "long_comment" then
      local written = line_comments(source, e.offset, sub(source, e.offset, e.offset + e.length - 1))
      if written ~= nil then
        out[#out + 1] = { row = "long_comment", edits = { { lo = e.offset, hi = e.offset + e.length, text = written } } }
      end
    end
  end

  local covered: {Ast.Node: boolean} = {}
  local frames: {Frame} = {}
  local stopped: {integer: integer} = {}
  local open_tables: {integer} = {}
  local loop_bodies: {Ast.Block: boolean} = {}
  local jumps: {integer: Jumps} = {}
  local labels: {integer} = {}

  local function enter(node: Ast.Node)
    local base: Ast.Base = node
    local kind = base.kind
    if kind == "Rets" then
      -- A return list that begins with `(A | B)?` and goes on is written in
      -- parentheses, which would otherwise be taken for the whole list.
      if node is Ast.Rets and #node.lists == 1 then
        local list = node.lists[1]
        local head = list[1]
        local first, last = bounds(node)
        if head ~= nil and head is Ast.TypeUnion and (#list > 1 or node.variadic) and tokens[first].kind ~= "(" then
          local made = union_rewrite(source, tokens, head)
          if made ~= nil and made.opens then
            table.insert(made.edits, insert_before(tokens, first, "("))
            table.insert(made.edits, insert_after(tokens, last, ")"))
            covered[head] = true
            out[#out + 1] = made
          end
        end
      end
    elseif kind == "TypeUnion" then
      if node is Ast.TypeUnion and not covered[node] then
        local made = union_rewrite(source, tokens, node)
        if made ~= nil then
          out[#out + 1] = made
        end
      end
    elseif kind == "TypeFunction" then
      if node is Ast.TypeFunction then
        parameter_rewrites(source, tokens, node, out)
      end
    elseif kind == "Binary" then
      if node is Ast.Binary and node.op == "or" and not covered[node] then
        local made = ternary_rewrite(tokens, node, covered)
        if made ~= nil then
          out[#out + 1] = made
        end
      end
    elseif kind == "Unary" then
      if node is Ast.Unary and not covered[node] then
        local cur: Ast.Exp = node.operand
        while cur is Ast.Unary do
          covered[cur] = true
          cur = cur.operand
        end
        if cur is Ast.Binary and cur.op == "^" then
          local first = bounds(node)
          local _, last = bounds(cur.left)
          out[#out + 1] = { row = "unary_power", edits = { insert_before(tokens, first, "("), insert_after(tokens, last, ")") } }
        end
      end
    elseif kind == "FieldDecl" then
      if node is Ast.FieldDecl then
        local made = field_rewrite(source, tokens, node)
        if made ~= nil then
          out[#out + 1] = made
        end
      end
    elseif kind == "Record" then
      if node is Ast.Record then
        local made = declaration_rewrite(tokens, node, node.scope, node.name)
        if made ~= nil then
          out[#out + 1] = made
        end
      end
    elseif kind == "Enum" then
      if node is Ast.Enum then
        local made = declaration_rewrite(tokens, node, node.scope, node.name)
        if made ~= nil then
          out[#out + 1] = made
        end
      end
    elseif kind == "Interface" then
      if node is Ast.Interface then
        local made = declaration_rewrite(tokens, node, node.scope, node.name)
        if made ~= nil then
          out[#out + 1] = made
        end
      end
    elseif kind == "Table" then
      -- A `;` after the table's last token whose `{` is closed further on
      -- ended it: the table of a nested `{ a = { b }; c }` is the outer one.
      local first, last = bounds(node)
      local after = tokens[last + 1]
      if after.kind == "$ERR$" and after.text == ";" and brace_end(tokens, first) ~= last then
        stopped[last + 1] = first
        open_tables[#open_tables + 1] = first
      end
    elseif kind == "While" or kind == "Repeat" or kind == "ForNum" or kind == "ForIn" then
      if node is Ast.While then
        loop_bodies[node.body] = true
      elseif node is Ast.Repeat then
        loop_bodies[node.body] = true
      elseif node is Ast.ForNum then
        loop_bodies[node.body] = true
      elseif node is Ast.ForIn then
        loop_bodies[node.body] = true
      end
    elseif kind == "Block" then
      if node is Ast.Block then
        local label = direct_label(tokens, node)
        local loop = loop_bodies[node] == true
        frames[#frames + 1] = { barrier = false, loop = loop, label = label }
        if label ~= nil then
          local stats = node.stats
          local last = stats[#stats]
          local ends = false
          if last ~= nil then
            ends = bounds(last) == label
          end
          jumps[label] = { ends_loop = loop and ends, gotos = {} }
          labels[#labels + 1] = label
        end
      end
    elseif kind == "Fn" or kind == "Method" then
      frames[#frames + 1] = { barrier = true, loop = false }
    elseif kind == "Error" then
      local first, last = bounds(node)
      local t = tokens[first]
      if first == last and t.kind == "keyword" and t.text == "goto" then
        local label = tokens[first + 1]
        if label.text == "continue" then
          -- The label it jumps to is the nearest one a block around it holds
          -- before a function ends; `continue` leaves the innermost loop.
          local crossed = false
          for i = #frames, 1, -1 do
            local frame = frames[i]
            if frame.barrier then
              break
            end
            local target = frame.label
            if target ~= nil then
              local group = jumps[target]
              group.gotos[#group.gotos + 1] = first
              if crossed then
                group.ends_loop = false
              end
              break
            end
            if frame.loop then
              crossed = true
            end
          end
        end
      end
    end
  end

  local function leave(node: Ast.Node)
    local base: Ast.Base = node
    local kind = base.kind
    if kind == "Block" or kind == "Fn" or kind == "Method" then
      frames[#frames] = nil
    end
  end

  for i = #interfaces, 1, -1 do
    interfaces[i] = nil
  end
  local tracker = mut_tracker(tokens, hazards, interfaces)
  walk(chunk, function(node: Ast.Node)
    enter(node)
    tracker.enter(node)
  end, function(node: Ast.Node)
    leave(node)
    tracker.leave(node)
  end)
  for _, made in ipairs(tracker.finish()) do
    out[#out + 1] = made
  end

  -- A label that ends the innermost loop around every `goto` that reaches
  -- it is deleted and the gotos become `continue`; any other is left.
  for _, label in ipairs(labels) do
    local group = jumps[label]
    if group.ends_loop then
      local edits: {Edit} = { delete_with_blanks_before(source, tokens, label) }
      for _, at in ipairs(group.gotos) do
        edits[#edits + 1] = delete_with_blanks_after(source, tokens, at)
      end
      out[#out + 1] = { row = "continue", edits = edits }
    end
  end

  -- A `;` between table items stops the table, which then ends before it
  -- with no `}`. The `;` after it that stand between items of the same table,
  -- up to the first word that begins a block (a `;` there may end a statement),
  -- are commas too, so a table of data takes one read. The rest of the table
  -- waits for the next read, when the table reaches it.
  local commas: {integer: boolean} = {}
  for _, s in ipairs(semicolons) do
    local open = stopped[s]
    if open ~= nil and not commas[s] then
      commas[s] = true
      local close = brace_end(tokens, open)
      local openers: {string} = {}
      local i = s + 1
      while i < close do
        local t = tokens[i]
        local kind = t.kind
        if kind == "{" or kind == "(" or kind == "[" then
          openers[#openers + 1] = kind
        elseif kind == "}" or kind == ")" or kind == "]" then
          openers[#openers] = nil
        elseif kind == "keyword" and BLOCK_WORDS[t.text] then
          break
        elseif kind == "$ERR$" and t.text == ";" and (openers[#openers] or "{") == "{" then
          commas[i] = true
        end
        i = i + 1
      end
    end
  end
  local waiting: {{integer}} = {}
  for _, open in ipairs(open_tables) do
    waiting[#waiting + 1] = { open, brace_end(tokens, open) }
  end
  for _, s in ipairs(semicolons) do
    local pending = false
    for _, span in ipairs(waiting) do
      if s > span[1] and s < span[2] then
        pending = true
      end
    end
    if commas[s] then
      out[#out + 1] = { row = "semicolon", edits = { replace_token(tokens, s, ",") } }
    elseif not pending then
      out[#out + 1] = { row = "semicolon", edits = { delete_with_blanks_before(source, tokens, s) } }
    end
  end
  return out
end

-- applying

--- The text of an insertion that closes what an earlier one opened.
local CLOSERS <const>: {string: boolean} = { [")"] = true, [")?"] = true, ["?"] = true, [" end"] = true }

local record Placed
  lo: integer
  hi: integer
  text: string
  group: integer
  seq: integer
end

--- `source` with the edits of the `rewrites` made. Rewrites whose edits
--- overlap another's are left out (they are made on a later read), and the
--- count of each row made is added to `counts`.
local function apply(source: string, rewrites: {Rewrite}, counts: {string: integer}, removed?: {string}): string, integer
  local dropped: {integer: boolean} = {}
  local placed: {Placed} = {}
  local seq = 0
  for g, r in ipairs(rewrites) do
    for _, e in ipairs(r.edits) do
      seq = seq + 1
      placed[#placed + 1] = { lo = e.lo, hi = e.hi, text = e.text, group = g, seq = seq }
    end
  end
  -- Insertions at one offset: those that close something go first and the
  -- one made last (the innermost) first, the others in the order made.
  table.sort(placed, function(a: Placed, b: Placed): boolean
    if a.lo ~= b.lo then return a.lo < b.lo end
    if a.hi ~= b.hi then return a.hi < b.hi end
    local a_closes, b_closes = CLOSERS[a.text] == true, CLOSERS[b.text] == true
    if a_closes ~= b_closes then return a_closes end
    if a_closes then return a.seq > b.seq end
    return a.seq < b.seq
  end)
  while true do
    local clash = false
    local reach = 0
    for _, p in ipairs(placed) do
      if not dropped[p.group] then
        if p.lo < reach then
          dropped[p.group] = true
          clash = true
        else
          reach = math.max(reach, p.hi)
        end
      end
    end
    if not clash then
      break
    end
  end
  local out: {string} = {}
  local at = 1
  for _, p in ipairs(placed) do
    if not dropped[p.group] then
      out[#out + 1] = sub(source, at, p.lo - 1)
      out[#out + 1] = p.text
      at = p.hi
    end
  end
  out[#out + 1] = sub(source, at)
  local made = 0
  for g, r in ipairs(rewrites) do
    if not dropped[g] then
      made = made + 1
      counts[r.row] = (counts[r.row] or 0) + 1
      local gone = r.removed
      if removed ~= nil and gone ~= nil then
        removed[#removed + 1] = gone
      end
    end
  end
  return concat(out), made
end

local function read(source: string, name: string, dialect: Ast.Dialect): Parser.Parsed
  return Parser.parse(Lexer.lex(source, name), name, dialect)
end

--- The text of a translation in progress, how it parses and how many times it was read.
local record Run
  text: string
  parsed: Parser.Parsed
  reads: integer
  --- The reads allowed before the loop stops.
  limit: integer
end

--- Makes the rewrites of `collect` until the text holds none or the reads are used.
local function converge(run: Run, name: string, dialect: Ast.Dialect, counts: {string: integer},
                        hazards: {Translate.Hazard}, interfaces: {Translate.Interface})
  while run.reads < run.limit do
    local rewrites = collect(run.text, run.parsed, hazards, interfaces)
    if #rewrites == 0 then
      break
    end
    local after, made = apply(run.text, rewrites, counts)
    if made == 0 then
      break
    end
    run.text = after
    run.reads = run.reads + 1
    run.parsed = read(after, name, dialect)
  end
end

Translate.never_false = never_false

function Translate.translate(source: string, name: string): Translate.Result
  local dialect: Ast.Dialect = find(name, "%.d%.tl$") and "decl" or "tl"
  local counts: {string: integer} = {}
  local hazards: {Translate.Hazard} = {}
  local interfaces: {Translate.Interface} = {}
  -- A table with several `;` between its items takes a read for each.
  local _, semicolons = source:gsub(";", "")
  local run: Run = { text = source, parsed = read(source, name, dialect), reads = 1, limit = MAX_READS + semicolons }
  converge(run, name, dialect, counts, hazards, interfaces)
  local rewrites = class_rewrites(run.text, run.parsed, hazards)
  if #rewrites > 0 then
    local after, made = apply(run.text, rewrites, counts)
    if made > 0 then
      run.text = after
      run.reads = run.reads + 1
      run.parsed = read(after, name, dialect)
      -- A method that took its parameter types from its field may now change
      -- them, and a parameter that is a collection now says so.
      run.limit = run.reads + MAX_READS
      converge(run, name, dialect, counts, hazards, interfaces)
    end
  end
  -- The class literals follow the classes and the `mut` rewrites, which read the calls as they were written.
  local removed: {string} = {}
  while run.reads < run.limit do
    local literals = literal_rewrites(run.text, run.parsed)
    if #literals == 0 then
      break
    end
    local after, made = apply(run.text, literals, counts, removed)
    if made == 0 then
      break
    end
    run.text = after
    run.reads = run.reads + 1
    run.parsed = read(after, name, dialect)
  end
  local text, parsed, reads = run.text, run.parsed, run.reads
  -- A rewrite left for a later read can report the same place twice.
  local unique: {Translate.Hazard} = {}
  local seen_hazards: {string: boolean} = {}
  for _, h in ipairs(hazards) do
    local key = h.kind .. "\0" .. h.class .. "\0" .. h.method .. "\0" .. h.name
    if not seen_hazards[key] then
      seen_hazards[key] = true
      unique[#unique + 1] = h
    end
  end
  return {
    text = text, counts = counts, errors = parsed.errors, hazards = unique, interfaces = interfaces, metatables = removed,
    reads = reads,
  }
end

return Translate
