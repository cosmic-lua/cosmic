--- What each token of a parsed source is for: the second layer of the Teal formatter, between
--- [`build.fix.trivia`] (the stream of tokens and comments) and [`build.fix.layout`] (which writes them).
---
--- A role is decided from the syntax tree, never from the tokens next to a token: the `-` of `a - b` and of `-b`
--- are one token kind and two roles, as are the `(` of a call and of a parenthesized expression, the `:` of a type
--- and of a method call, the `<` of a comparison, of an attribute and of a type parameter list. The operator of a
--- node is not recorded on it, so the walk reads it from its place: the token after the left operand of a
--- `Binary`, the first of a `Unary`, the one after the object of a `Field` or a `MethodCall`.
---
--- A token that lies in a type (a [`Ast.Type`], a return list or a parameter of a function type) takes the role
--- `word` and belongs to a region, which is the first token of the outermost type that holds it. The layout keeps
--- the author's spacing between two tokens of a region, since a type's spelling is not laid out yet.
local Ast = require("lang.ast")
local Lexer = require("lang.lexer")

local record Roles
  --- The part a token plays in the spacing of its line. Each role is tight or loose before it and after it: the
  --- layout of a line is those two choices at every pair of neighbours.
  enum Role
    -- an operator, keyword, name, literal or any token that is spaced from both neighbours
    "word"
    -- `,`: tight before
    "comma"
    -- `:` of a declaration, a parameter or a return list: tight before
    "colon"
    -- `?` of an optional parameter or field: tight before
    "question"
    -- `.` of a field or a path: tight on both sides
    "dot"
    -- `:` of a method call: tight on both sides
    "method_colon"
    -- `(` of a call, a parameter list or an `import`: tight on both sides
    "call_open"
    -- `(` of a parenthesized expression or of the pattern of a `match` arm: tight after
    "group_open"
    -- any `)`: tight before
    "paren_close"
    -- the operator of a `Unary` other than `not`, and the `...` of a `Spread`: tight after
    "unary"
    -- `[` and `]` of an index: tight on both sides
    "index_open"
    "index_close"
    -- `[` and `]` of a table key or a field name: tight inside
    "key_open"
    "key_close"
    -- `[` of an index that begins with a long string, which a `[[` would join: tight before, loose after. Its `]`
    -- and both brackets of a key like that are `word`s.
    "wide_open"
    -- `{` and `}` of a table with entries: loose inside
    "table_open"
    "table_close"
    -- `{` and `}` of a table with none: tight inside
    "empty_open"
    "empty_close"
    -- `<` and `>` of an attribute: tight inside
    "attr_open"
    "attr_close"
    -- `<` and `>` of a type parameter list: tight on both sides
    "angle_open"
    "angle_close"
  end

  record Roled
    --- The role of each token, by the index [`Lexer.Tokens`] numbers them with; the `$EOF$` is a `word`.
    roles: {Role}
    --- For a token in a type, the index of the first token of the outermost type that holds it; 0 for the others.
    regions: {integer}
    --- The regions that are the body of a record, an interface or an enum, whose every line (the first included) is
    --- the author's own: the first token of each.
    bodies: {integer: boolean}
  end

  --- The roles of the tokens of `chunk`, a parse without errors.
  of: function(chunk: Ast.Chunk): Roled

  --- The role of token `i` of `roled`.
  role: function(roled: Roled, i: integer): Role

  --- The region of token `i` of `roled`.
  region: function(roled: Roled, i: integer): integer

  --- Whether token `i` of `roled` continues the region of the token `previous` (0 for none) before it: the two are in
  --- one region, or `i` is in the body of a record, interface or enum, which no token before it begins.
  continues: function(roled: Roled, i: integer, previous: integer): boolean

  --- Whether token `i` of `roled` is in the body of a record, interface or enum.
  in_body: function(roled: Roled, i: integer): boolean
end

--- The role of a token by its text alone, for the tokens whose part the tree does not change; the walk sets the
--- others.
local TEXT_ROLES <const>: {string: Roles.Role} = {
  [","] = "comma", [":"] = "colon", ["?"] = "question", ["."] = "dot", ["("] = "call_open", [")"] = "paren_close",
}

--- The kinds of node that are members of a record, an interface or an enum.
local MEMBER_KINDS <const>: {string: boolean} = {
  FieldDecl = true, Record = true, Interface = true, Enum = true, Alias = true, Import = true, Userdata = true,
  Error = true, EnumValue = true,
}

--- The first and last token of the members of `node`, a declaration whose body is kept as the author wrote it (a record
--- or an enum: the alignment of its fields or its values is the author's). Empty for a body with no member or with
--- code in it, which is a method or a class.
local function body_of(node: Ast.Node): {integer}
  local members: mut {Ast.Node} = {}
  local code: mut {string} = {}
  Ast.children(node, function(child: Ast.Node)
    local base = child
    if base.kind == "Method" or base.kind == "Class" then
      code[#code + 1] = base.kind
    elseif MEMBER_KINDS[base.kind] == true then
      members[#members + 1] = base
    end
  end)
  local first, last = members[1], members[#members]
  if #code > 0 or first == nil or last == nil then
    return {}
  end
  return { first.first, last.last }
end

--- The kinds of node that are types, whose tokens form a region.
local TYPE_KINDS <const>: {string: boolean} = {
  TypeName = true, TypeBool = true, TypeNil = true, TypeError = true, TypeArray = true, TypeMap = true,
  TypeUnion = true, TypeOptional = true, TypeMut = true, TypeFunction = true, PType = true, Narrows = true,
  Rets = true,
}

function Roles.of(chunk: Ast.Chunk): Roles.Roled
  local tokens = chunk.tokens
  local count = Lexer.count(tokens)
  -- Sparse while the tree is walked; the arrays are filled in token order at the end.
  local set: mut {integer: Roles.Role} = {}
  local region_of: mut {integer: integer} = {}

  --- Gives token `i` the role `role` where it is the token `text`: a parse that recovered, or a `>>` that closes
  --- two lists of type arguments, leaves a different token there.
  local function mark(i: integer, text: string, role: Roles.Role)
    if i >= 1 and i <= count and Lexer.text(tokens, i) == text then
      set[i] = role
    end
  end

  --- Marks the brackets of an index or a key: `open` and `close` are the tokens of the `[` and the `]`, and the
  --- key begins at `key`. The brackets of one that begins with a long string stand off it: `wide` is the role of
  --- its `[`.
  local function mark_brackets(open: integer, close: integer, key: integer, narrow_open: Roles.Role,
                               narrow_close: Roles.Role, wide: Roles.Role)
    if key <= count and Lexer.kind(tokens, key) == "string" and Lexer.text(tokens, key):sub(1, 1) == "[" then
      mark(open, "[", wide)
      mark(close, "]", "word")
    else
      mark(open, "[", narrow_open)
      mark(close, "]", narrow_close)
    end
  end

  --- Notes what the tree says of the tokens of the node `base`, whose children are `kids`, that its children do
  --- not hold. The node's own fields are not read: its kind, its tokens and the order of its children say it.
  local function note(base: Ast.Node, kids: {Ast.Node})
    local kind = base.kind
    local head = kids[1]
    local first = if head == nil then nil else head end
    local second = kids[2]
    local next_one = if second == nil then nil else second end
    if kind == "Paren" or kind == "MatchArm" then
      mark(base.first, "(", "group_open")
    elseif kind == "MethodCall" then
      if first ~= nil then
        mark(first.last + 1, ":", "method_colon")
      end
    elseif kind == "Index" then
      if first ~= nil and next_one ~= nil then
        mark_brackets(first.last + 1, base.last, next_one.first, "index_open", "index_close", "wide_open")
      end
    elseif kind == "Keyed" then
      if first ~= nil then
        mark_brackets(base.first, first.last + 1, first.first, "key_open", "key_close", "word")
      end
    elseif kind == "Table" then
      local empty = base.last == base.first + 1
      mark(base.first, "{", if empty then "empty_open" else "table_open" end)
      mark(base.last, "}", if empty then "empty_close" else "table_close" end)
    elseif kind == "Unary" then
      if Lexer.text(tokens, base.first) ~= "not" then
        set[base.first] = "unary"
      end
    elseif kind == "Spread" then
      set[base.first] = "unary"
    elseif kind == "Binding" then
      if base.last == base.first + 3 then
        mark(base.last - 2, "<", "attr_open")
        mark(base.last, ">", "attr_close")
      end
    elseif kind == "FieldDecl" then
      -- The name is the first child; a bracketed name is a `[`, a string and a `]`.
      if first ~= nil and first.last == first.first + 2 then
        mark_brackets(first.first, first.last, first.first + 1, "key_open", "key_close", "word")
      end
    elseif kind == "TypeParam" then
      -- The list's first parameter follows the `<` and its last precedes the `>`.
      mark(base.first - 1, "<", "angle_open")
      mark(base.last + 1, ">", "angle_close")
    end
  end

  -- The declarations whose bodies are kept, outermost first.
  local bodies: mut {Ast.Node} = {}
  -- The order of the walk is of no matter: no two nodes mark one token.
  local queue: mut {Ast.Node} = { chunk }
  for _, node in ipairs(queue) do
    local base = node
    if TYPE_KINDS[base.kind] == true then
      -- The parentheses of a parenthesized type, `(T | U)`, are in no node: take them in.
      local first, last = base.first, base.last
      while first > 1 and last < count and Lexer.text(tokens, first - 1) == "(" and
          Lexer.text(tokens, last + 1) == ")" do
        first, last = first - 1, last + 1
      end
      for i = first, last do
        region_of[i] = first
      end
    else
      local kids: mut {Ast.Node} = {}
      Ast.children(node, function(child: Ast.Node)
        kids[#kids + 1] = child
        queue[#queue + 1] = child
      end)
      note(base, kids)
      if base.kind == "Record" or base.kind == "Interface" or base.kind == "Enum" then
        bodies[#bodies + 1] = node
      end
    end
  end

  -- A body is one region that no type inside it splits, and one inside another is the outer body's.
  local verbatim: mut {integer: boolean} = {}
  local held: mut {integer: boolean} = {}
  for _, node in ipairs(bodies) do
    local span = body_of(node)
    local first, last = span[1], span[2]
    if first ~= nil and last ~= nil and held[first] ~= true then
      for i = first, math.min(last, count) do
        region_of[i] = first
        held[i] = true
      end
      verbatim[first] = true
    end
  end

  local roles: mut {Roles.Role} = {}
  local regions: mut {integer} = {}
  for i = 1, count do
    local region = region_of[i] or 0
    regions[#regions + 1] = region
    roles[#roles + 1] = if region ~= 0 then "word" else set[i] or TEXT_ROLES[Lexer.text(tokens, i)] or "word" end
  end
  return { roles = roles, regions = regions, bodies = verbatim }
end

function Roles.role(roled: Roles.Roled, i: integer): Roles.Role
  return roled.roles[i] or "word"
end

function Roles.region(roled: Roles.Roled, i: integer): integer
  return roled.regions[i] or 0
end

function Roles.in_body(roled: Roles.Roled, i: integer): boolean
  local region = Roles.region(roled, i)
  return region ~= 0 and roled.bodies[region] == true
end

function Roles.continues(roled: Roles.Roled, i: integer, previous: integer): boolean
  local region = Roles.region(roled, i)
  return region ~= 0 and (roled.bodies[region] == true or (previous ~= 0 and region == Roles.region(roled, previous)))
end

return Roles
