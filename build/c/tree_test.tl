--- Reading clang's text dump: positions written only as far as they
--- differ, and only the tree's own declarations kept.

local tree = require("build.c.tree")

local dump = table.concat({
  "TranslationUnitDecl 0x1 <<invalid sloc>> <invalid sloc>",
  "|-FunctionDecl 0x2 </usr/include/stdio.h:10:1, col:20> col:5 printf 'int (const char *, ...)' extern",
  "|-FunctionDecl 0x3 <core/a.c:4:1, line:7:1> line:4:12 used f 'int (lua_State *)' static",
  "| |-ParmVarDecl 0x4 <col:14, col:25> col:25 used L 'lua_State *'",
  "| `-CompoundStmt 0x5 <col:28, line:7:1>",
  "|   `-ReturnStmt 0x6 <line:6:3, vendor/lua/src/lua.h:9:9>",
  "|     `-CStyleCastExpr 0x7 <core/a.c:6:10, col:30> 'int' <IntegralCast>",
  "`-VarDecl 0x8 <line:9:1, col:9> col:5 x 'int'",
}, "\n")

local function test_only_the_trees_own_declarations_are_kept()
  local decls = tree.parse(dump)
  assert(#decls == 2, "kept " .. #decls)
  assert(decls[1].kind == "FunctionDecl" and decls[1].file == "core/a.c")
  assert(decls[2].kind == "VarDecl")
end

--- `col:` keeps the last line and `line:` the last file, even across a
--- position in another file: the cast is back in core/a.c, and the
--- declaration after it is on core/a.c's line 9, not lua.h's.
local function test_an_abbreviated_position_reads_against_the_last()
  local decls = tree.parse(dump)
  local fn = decls[1]
  local param = fn.children[1]
  assert(param.file == "core/a.c" and param.line == 4 and param.col == 14)
  local ret = fn.children[2].children[1]
  assert(ret.line == 6 and ret.col == 3)
  local cast = ret.children[1]
  assert(cast.file == "core/a.c" and cast.line == 6 and cast.col == 10)
  assert(tree.type_of(cast) == "int")
  assert(decls[2].file == "core/a.c" and decls[2].line == 9)
end

local function test_a_sugared_type_reads_both_ways()
  local node: tree.Node = { kind = "CallExpr", text = "'lua_Integer':'long long'", children = {} }
  assert(tree.type_of(node) == "lua_Integer")
  assert(tree.canonical_type(node) == "long long")
end

local function test_a_macro_expansion_is_placed_where_it_was_used()
  local parent: tree.Node = { kind = "CallExpr", file = "core/a.c", line = 3, children = {} }
  local child: tree.Node = { kind = "CallExpr", file = "vendor/lua/src/lua.h", line = 9,
                             children = {}, parent = parent }
  local at = assert(tree.placed(child))
  assert(at.file == "core/a.c" and at.line == 3)
end

--- A function whose type begins with a system header's macro, `bool`,
--- begins in that header; it is still this tree's own, placed at its
--- name.
local function test_a_declaration_beginning_in_a_macro_is_placed_at_its_name()
  local decls = tree.parse(table.concat({
    "TranslationUnitDecl 0x1 <<invalid sloc>> <invalid sloc>",
    "|-FunctionDecl 0x2 <core/a.c:2:1, col:9> col:5 g 'int (void)'",
    "`-FunctionDecl 0x3 </usr/lib/include/stdbool.h:24:14, core/a.c:9:1> " ..
      "line:5:6 f 'bool (void)'",
  }, "\n"))
  assert(#decls == 2, "kept " .. #decls)
  assert(decls[2].file == "core/a.c" and decls[2].line == 5 and decls[2].col == 6,
    tostring(decls[2].file) .. ":" .. tostring(decls[2].line))
end
