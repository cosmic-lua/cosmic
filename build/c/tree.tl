--- A C file's syntax tree, as clang's own text dump of it describes it.
---
--- `bin/zig cc` carries clang, and `-Xclang -ast-dump` has it print the
--- whole typed tree of a translation unit, one node to a line. That is
--- the only C parser this tree needs: it has already resolved every
--- include, expanded every macro and typed every expression, which no
--- parser written here could do without growing into a compiler.
---
--- The dump's own shape, which `parse` reads:
---
---     |-FunctionDecl 0x7f.. <core/surface.c:41:1, line:70:1> line:41:12 used print 'int (lua_State *)' static
---     | `-CompoundStmt 0x7f.. <col:40, line:70:1>
---
--- A node's depth is the width of the tree-drawing prefix before it, two
--- columns a level. Its kind comes next, then its address, then the
--- source range it spans in angle brackets, then (for a declaration) the
--- position of its name, then whatever that kind prints: types in single
--- quotes, a cast's kind in angle brackets, a referenced declaration's
--- kind, address and name.
---
--- A position is written only as far as it differs from the one printed
--- just before it, in document order: `col:9` keeps the last line and
--- file, `line:12:3` keeps the last file. So every position on every line
--- is read, including those of declarations `parse` then drops, or the
--- first position after a dropped header declaration would be read
--- against the wrong file. Positions are where a token was SPELLED: a
--- node a macro expanded to sits in the header that defines the macro,
--- and its arguments back in the file that wrote them.
---
--- Only declarations whose own position is in this tree's own C are kept
--- (see `own`): a translation unit's system and vendored headers are most
--- of its dump and none of them is checked here.
---
--- TODO: read `-Xclang -ast-dump=json` instead, through `cosmic.json`
--- and [`cosmic.shape`] (see doc/roadmap.md): [`Json.decode`] with a raised
--- `max_depth`, since clang's trees nest deeper than its default 64,
--- after checking the memory a whole translation unit's dump takes. The
--- JSON form names every field rather than leaving it to this module to
--- read a line's text, and clang keeps it stable where the text form is
--- only meant for people to read.

local String = require("cosmic.string")

local record tree
  --- One node of the dump.
  record Node
    --- The node's kind, as clang names it: "CallExpr", "IfStmt".
    --- A child slot the kind leaves empty is a node of kind "<<<NULL>>>".
    kind: string
    --- Its address, which is how a reference names what it refers to.
    id: string
    --- Where it begins, as spelled.
    file: string
    line: integer
    col: integer
    --- Everything the line prints after its range and position: types,
    --- names, a cast's kind, an operator.
    text: string
    children: {tree.Node}
    parent: tree.Node
    --- What `referent`, `callee`, [`canonical_type`], and `operator`
    --- answered the first time, so a rule that asks again reads it.
    --- Each has a flag saying it was asked, since nil is an answer.
    referent_cache: tree.Referent
    referent_asked: boolean
    callee_cache: string
    callee_asked: boolean
    canonical_cache: string
    canonical_asked: boolean
    operator_cache: string
    operator_asked: boolean
  end
  --- What a reference refers to, as the dump spells it.
  record Referent
    --- "Function", "Var", "ParmVar".
    kind: string
    --- The address of the declaration it refers to.
    id: string
    name: string
  end
end

--- Whether `file`, as the dump names it, is C of this tree's own rather
--- than a system header, a vendored library, or a position the compiler
--- made up (`<built-in>`, `<scratch space>`).
local function own(file: string): boolean
  if file == nil or file == "" then return false end
  local first = file:sub(1, 1)
  if first == "/" or first == "<" then return false end
  return file:sub(1, 7) ~= "vendor/"
end

--- `file` as the tree names it: relative to `root` when it is under it.
local function normalized(file: string, root: string): string
  while file:sub(1, 2) == "./" do
    file = file:sub(3)
  end
  if root ~= nil and String.starts_with(file, root .. "/") then
    file = file:sub(#root + 2)
  end
  return file
end

--- The running position of the dump: what an abbreviated position is
--- read against.
local record Cursor
  file: string
  line: integer
  root: string
end

--- Reads one position against `at`, moves `at` to it, and returns it.
--- Anything that is not a position (`invalid sloc`) leaves `at` alone.
local function located(at: Cursor, s: string): string, integer, integer
  -- Most positions are one of the two short forms, and the first byte
  -- says which one a position could be.
  local first = s:byte(1)
  if first == 99 then -- c
    local col = s:match("^col:(%d+)$")
    if col ~= nil then
      return at.file, at.line, math.tointeger(tonumber(col))
    end
  elseif first == 108 then -- l
    local line, lcol = s:match("^line:(%d+):(%d+)$")
    if line ~= nil then
      at.line = math.tointeger(tonumber(line))
      return at.file, at.line, math.tointeger(tonumber(lcol))
    end
  end
  local file, fline, fcol = s:match("^(.+):(%d+):(%d+)$")
  if file ~= nil then
    at.file = normalized(file, at.root)
    at.line = math.tointeger(tonumber(fline))
    return at.file, at.line, math.tointeger(tonumber(fcol))
  end
  return nil, nil, nil
end

--- Whether `word` is a position, the kind a declaration prints for its
--- name after its range.
local function is_position(word: string): boolean
  return word:match("^col:%d+$") ~= nil or word:match("^line:%d+:%d+$") ~= nil or
    word:match("^[^']+:%d+:%d+$") ~= nil
end

--- Splits `rest`, what follows a node's kind, into its address, range and
--- the text after them, reading every position against `at` on the way.
--- Returns the address, the begin position, and where the remaining
--- text starts in `rest`.
local function header(at: Cursor, rest: string): string, string, integer, integer, integer
  local id = rest:match("^ (0x%x+)")
  local pos = 1
  if id ~= nil then
    pos = #id + 2
  end
  -- `prev 0x..` and `parent 0x..` sit between an address and a range.
  while true do
    local skipped = rest:match("^ %a+ 0x%x+", pos)
    if skipped == nil then break end
    pos = pos + #skipped
  end
  local file, line, col: string, integer, integer
  if rest:sub(pos, pos + 1) == " <" then
    -- The range is balanced: `<<built-in>:1:1, col:5>` nests one.
    local _, stop = rest:find("^%b<>", pos + 1)
    stop = stop or pos + 1
    local range = rest:sub(pos + 2, stop - 1)
    local from = 1
    while true do
      local comma = range:find(", ", from, true)
      local f, l, c = located(at, range:sub(from, (comma or #range + 1) - 1))
      if file == nil and f ~= nil then
        file, line, col = f, l, c
      end
      if comma == nil then break end
      from = comma + 2
    end
    pos = stop + 1
    local word = rest:match("^ (%S+)", pos)
    if word ~= nil and is_position(word) then
      -- A declaration that begins with a system header's macro, `bool`
      -- (<stdbool.h>) above all, is placed at its name, where this
      -- tree spelled it, rather than in the header.
      local f, l, c = located(at, word)
      if not own(file) and own(f) then
        file, line, col = f, l, c
      end
      pos = pos + #word + 1
    end
  end
  return id, file, line, col, pos + 1
end

--- Reads the positions of the line in `dump` that ends before `stop` and
--- whose kind ends at `kind_end`, as `header` does, for the cursor `at`
--- alone: what a line of a declaration that is dropped has to give.
local function moved(at: Cursor, dump: string, kind_end: integer, stop: integer)
  local _, id_end = dump:find("^ 0x%x+", kind_end)
  local pos = id_end and id_end + 1 or kind_end
  while true do
    local _, skipped = dump:find("^ %a+ 0x%x+", pos)
    if skipped == nil then break end
    pos = skipped + 1
  end
  if dump:byte(pos) ~= 32 or dump:byte(pos + 1) ~= 60 then return end
  local _, range_end = dump:find("^%b<>", pos + 1)
  if range_end == nil or range_end >= stop then range_end = pos + 1 end
  local range = dump:sub(pos + 2, range_end - 1)
  local from = 1
  while true do
    local comma = range:find(", ", from, true)
    local _, _, _ = located(at, range:sub(from, (comma or #range + 1) - 1))
    if comma == nil then break end
    from = comma + 2
  end
  local word = dump:match("^ (%S+)", range_end + 1)
  if word ~= nil and is_position(word) then
    local _, _, _ = located(at, word)
  end
end

--- The declarations of this tree's own C in `dump`, a translation unit's
--- text dump, each with its whole subtree. A file under `root`, when it
--- is given, is named relative to it, as a compile from the root names it.
function tree.parse(dump: string, root?: string): {tree.Node}
  local at: Cursor = { file = "", line = 0, root = root }
  local out: {tree.Node} = {}
  -- The innermost open node at each depth; depth 1 is a top-level
  -- declaration, and nil while one that is not kept is being skipped.
  local open: {integer: tree.Node} = {}
  local keeping = false
  local size = #dump
  local pos = 1
  while pos <= size do
    local stop = dump:find("\n", pos, true) or size + 1
    local from = pos
    pos = stop + 1
    if stop > from then
      -- The prefix, `|-` or `\`-` after the bars and spaces that nest
      -- the line, is everything up to the first `-`.
      local first = from
      local lead = dump:byte(from)
      if lead == 124 or lead == 32 or lead == 96 then
        first = (dump:find("-", from, true) or stop) + 1
      end
      local depth = (first - from) // 2
      -- A line of a dropped declaration only has to move the cursor, and
      -- most move it nowhere: those whose range and name are `col:` alone,
      -- or a range of columns and a type.
      local kind_end = 0
      local quiet = false
      if depth >= 2 and not keeping then
        kind_end = dump:find("%s", first) or stop
        local _, range_end = dump:find("^ 0x%x+ <col:%d+, col:%d+>", kind_end)
        if range_end == nil then _, range_end = dump:find("^ 0x%x+ <col:%d+>", kind_end) end
        if range_end ~= nil then
          quiet = dump:find("^ col:%d+", range_end + 1) ~= nil or dump:byte(range_end + 2) == 39
        end
      end
      if quiet then
        -- Nothing on it can move the cursor.
      elseif depth >= 2 and not keeping then
        moved(at, dump, kind_end, stop)
      else
        kind_end = dump:find("%s", first) or stop
        local kind = dump:sub(first, kind_end - 1)
        local rest = dump:sub(kind_end, stop - 1)
        local id, file, line, col, text_at = header(at, rest)
        if depth == 1 then
          keeping = own(file)
        end
        if depth >= 1 and keeping then
          local parent = open[depth - 1]
          local node: tree.Node = {
            kind = kind, id = id, file = file, line = line, col = col,
            text = rest:sub(text_at), children = {}, parent = parent,
          }
          if depth == 1 then
            node.parent = nil
            out[#out + 1] = node
          elseif parent ~= nil then
            parent.children[#parent.children + 1] = node
          end
          open[depth] = node
        end
      end
    end
  end
  return out
end

--- The first single-quoted string in a node's text: an expression's type,
--- or a declaration's name's type, as written (`'lua_Integer':'long
--- long'` gives "lua_Integer").
function tree.type_of(node: tree.Node): string
  return node.text:match("'([^']*)'")
end

--- The type `node` has once every typedef is seen through: the second of
--- a sugared pair (`'lua_Integer':'long long'`), or the only one.
function tree.canonical_type(node: tree.Node): string
  if node.canonical_asked then return node.canonical_cache end
  local written, canonical = node.text:match("^[^']*'([^']*)':'([^']*)'")
  local answer: string = canonical or written or tree.type_of(node)
  node.canonical_cache = answer
  node.canonical_asked = true
  return answer
end

--- The operator of a unary or binary operator node: the last quoted word
--- of its text, as `'='` or `'<'`; nil when its text has none.
function tree.operator(node: tree.Node): string
  if node.operator_asked then return node.operator_cache end
  local op = node.text:match("'([^']*)'$")
  node.operator_cache = op
  node.operator_asked = true
  return op
end

--- What a reference refers to, or nil for a node that is not one.
function tree.referent(node: tree.Node): tree.Referent | nil
  if node == nil or node.kind ~= "DeclRefExpr" then return nil end
  if node.referent_asked then return node.referent_cache end
  local kind, id, name = node.text:match(" (%a+) (0x%x+) '([^']*)'")
  local found: tree.Referent = nil
  if kind ~= nil then found = { kind = kind, id = id, name = name } end
  node.referent_cache = found
  node.referent_asked = true
  return found
end

--- `node` with every implicit conversion and parenthesis around it seen
--- through.
function tree.bare(node: tree.Node): tree.Node
  while node ~= nil and (node.kind == "ImplicitCastExpr" or node.kind == "ParenExpr") and
      #node.children == 1 do
    node = node.children[1]
  end
  return node
end

--- The name of the function a call calls directly, or nil for a call
--- through a pointer.
function tree.callee(call: tree.Node): string
  if call.kind ~= "CallExpr" or #call.children == 0 then return nil end
  if call.callee_asked then return call.callee_cache end
  local r = tree.referent(tree.bare(call.children[1]))
  local name: string = nil
  if r ~= nil and r.kind == "Function" then name = r.name end
  call.callee_cache = name
  call.callee_asked = true
  return name
end

--- The first node under `node`, itself included, that was spelled in
--- this tree's own C.
local function own_within(node: tree.Node): tree.Node
  if own(node.file) then return node end
  for _, child in ipairs(node.children) do
    local found = own_within(child)
    if found ~= nil then return found end
  end
  return nil
end

--- The node of this tree's own C whose file and line `node` belongs
--- to: itself when it was spelled there. A node a macro expanded to is
--- placed where the macro was used: at the first of its arguments that
--- was written there, or else at the nearest enclosing node that was.
--- Nil when none was.
function tree.placed(node: tree.Node): tree.Node | nil
  local within = own_within(node)
  if within ~= nil then return within end
  local at = node.parent
  while at ~= nil do
    if own(at.file) then return at end
    at = at.parent
  end
  return nil
end

return tree
