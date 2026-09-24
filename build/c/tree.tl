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
--- and `cosmic.shape` (see doc/roadmap.md): `Json.decode` with a raised
--- `max_depth`, since clang's trees nest deeper than its default 64,
--- after checking the memory a whole translation unit's dump takes. The
--- JSON form names every field rather than leaving it to this module to
--- read a line's text, and clang keeps it stable where the text form is
--- only meant for people to read.

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
  end
end

--- Whether `file`, as the dump names it, is C of this tree's own rather
--- than a system header, a vendored library, or a position the compiler
--- made up (`<built-in>`, `<scratch space>`).
function tree.own(file: string): boolean
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
  if root ~= nil and file:sub(1, #root + 1) == root .. "/" then
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
  local col = s:match("^col:(%d+)$")
  if col ~= nil then
    return at.file, at.line, math.tointeger(tonumber(col))
  end
  local line, lcol = s:match("^line:(%d+):(%d+)$")
  if line ~= nil then
    at.line = math.tointeger(tonumber(line))
    return at.file, at.line, math.tointeger(tonumber(lcol))
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
  return word:match("^col:%d+$") ~= nil or word:match("^line:%d+:%d+$") ~= nil
    or word:match("^[^']+:%d+:%d+$") ~= nil
end

--- Splits `rest`, what follows a node's kind, into its address, range and
--- the text after them, reading every position against `at` on the way.
--- Returns the address, the begin position, and the remaining text.
local function header(at: Cursor, rest: string): string, string, integer, integer, string
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
    local depth = 0
    local stop = pos + 1
    for i = pos + 1, #rest do
      local c = rest:sub(i, i)
      if c == "<" then
        depth = depth + 1
      elseif c == ">" then
        depth = depth - 1
        if depth == 0 then
          stop = i
          break
        end
      end
    end
    local range = rest:sub(pos + 2, stop - 1)
    for part in (range .. ", "):gmatch("(.-), ") do
      local f, l, c = located(at, part)
      if file == nil and f ~= nil then
        file, line, col = f, l, c
      end
    end
    pos = stop + 1
    local word = rest:match("^ (%S+)", pos)
    if word ~= nil and is_position(word) then
      located(at, word)
      pos = pos + #word + 1
    end
  end
  return id, file, line, col, rest:sub(pos + 1)
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
  for raw in dump:gmatch("[^\n]+") do
    local prefix = raw:match("^[| `]*[|`]%-") or ""
    local depth = #prefix // 2
    local content = raw:sub(#prefix + 1)
    local kind = content:match("^(%S+)") or ""
    local id, file, line, col, text = header(at, content:sub(#kind + 1))
    if depth == 1 then
      keeping = tree.own(file)
    end
    if depth >= 1 and keeping then
      local parent = open[depth - 1]
      local node: tree.Node = {
        kind = kind, id = id, file = file, line = line, col = col,
        text = text, children = {}, parent = parent,
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
  local written, canonical = node.text:match("^[^']*'([^']*)':'([^']*)'")
  if canonical ~= nil then return canonical end
  return written or tree.type_of(node)
end

--- What a reference refers to: its kind ("Function", "Var", "ParmVar"),
--- address and name, or nil for a node that is not one.
function tree.referent(node: tree.Node): string, string, string
  if node.kind ~= "DeclRefExpr" then return nil, nil, nil end
  return node.text:match(" (%a+) (0x%x+) '([^']*)'")
end

--- `node` with every implicit conversion and parenthesis around it seen
--- through.
function tree.bare(node: tree.Node): tree.Node
  while node ~= nil and (node.kind == "ImplicitCastExpr" or node.kind == "ParenExpr")
      and #node.children == 1 do
    node = node.children[1]
  end
  return node
end

--- The name of the function a call calls directly, or nil for a call
--- through a pointer.
function tree.callee(call: tree.Node): string
  if call.kind ~= "CallExpr" or #call.children == 0 then return nil end
  local kind, _, name = tree.referent(tree.bare(call.children[1]))
  if kind == "Function" then return name end
  return nil
end

--- The first node under `node`, itself included, that was spelled in
--- this tree's own C.
local function own_within(node: tree.Node): tree.Node
  if tree.own(node.file) then return node end
  for _, child in ipairs(node.children) do
    local found = own_within(child)
    if found ~= nil then return found end
  end
  return nil
end

--- The line of this tree's own C that `node` belongs to: its own when it
--- was spelled there. A node a macro expanded to is placed where the
--- macro was used: at the first of its arguments that was written there,
--- or else at the nearest enclosing node that was.
function tree.place(node: tree.Node): string, integer
  local within = own_within(node)
  if within ~= nil then return within.file, within.line end
  local at = node.parent
  while at ~= nil do
    if tree.own(at.file) then return at.file, at.line end
    at = at.parent
  end
  return nil, nil
end

return tree
