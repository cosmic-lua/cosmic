--- Cross-module source snapshot contract regressions.
local source = require("cosmic.ast.source")
local walk = require("cosmic.ast.walk")
local edit = require("cosmic.edit")

local type Snapshot = source.Snapshot
local type Node = source.Node

local function parse(code: string, name?: string): Snapshot
  local snapshot, err = source.parse(code, name or "source_contract.tl")
  assert(snapshot, err)
  return snapshot
end

local function slice(snapshot: Snapshot, node: Node): string
  local range, err = source.range(snapshot, node)
  assert(range, err)
  return snapshot.source:sub(range.start_byte, range.end_byte - 1)
end

local function find_call(snapshot: Snapshot, callee: string): Node
  local found: Node | nil = nil
  walk.walk(snapshot.node, function(node: Node)
      local op = node.op
      local left = node.e1
      if node.kind == "op" and op and op.op == "@funcall"
      and left and left.kind == "variable" and left.tk == callee then
        found = node
      end
    end)
  assert(found, "missing call to " .. callee)
  return found
end

local function test_nested_call_ranges_include_their_own_delimiters()
  local snapshot = parse("return outer(inner((a + b)), pair())\n")
  assert(slice(snapshot, find_call(snapshot, "inner")) == "inner((a + b))")
  assert(slice(snapshot, find_call(snapshot, "pair")) == "pair()")
  assert(slice(snapshot, find_call(snapshot, "outer")) ==
    "outer(inner((a + b)), pair())")
end

local function test_if_branch_ranges_stop_before_sibling_or_end()
  local snapshot = parse([[
if ready then
  first()
else
  second()
end
]])
  local statement = snapshot.node[1]
  assert(statement.kind == "if")
  local branches = statement.if_blocks
  assert(branches and #branches == 2)
  assert(slice(snapshot, branches[1]) == "if ready then\n  first()")
  assert(slice(snapshot, branches[2]) == "else\n  second()")
end

local function test_paren_and_multi_return_ranges_are_exact()
  local snapshot = parse("local x = (a + b)\nreturn x, a, b\n")
  local paren: Node | nil = nil
  local returned: Node | nil = nil
  walk.walk(snapshot.node, function(node: Node)
      if node.kind == "paren" then paren = node end
      if node.kind == "return" then returned = node end
    end)
  assert(paren)
  assert(slice(snapshot, paren) == "(a + b)")
  assert(returned)
  assert(slice(snapshot, returned) == "return x, a, b")
end

local function test_ranges_slice_original_crlf_utf8_strings_and_comments()
  local code = "-- café\r\nlocal text = \"é\" -- tail\r\n"
  .. "return wrap(\r\n  text -- naïve\r\n)\r\n"
  local snapshot = parse(code)
  assert(slice(snapshot, snapshot.node) == code, "root must own every original byte")
  assert(slice(snapshot, snapshot.node[1]) == "local text = \"é\"")
  assert(slice(snapshot, find_call(snapshot, "wrap")) ==
    "wrap(\r\n  text -- naïve\r\n)")
  local string_node: Node | nil = nil
  walk.walk(snapshot.node, function(node: Node)
      if node.kind == "string" then string_node = node end
    end)
  assert(string_node)
  assert(slice(snapshot, string_node) == "\"é\"")
end

local function test_range_bytes_owns_empty_insertions_including_eof()
  local snapshot = parse("return 1\n")
  local first, first_err = source.range_bytes(snapshot, 1, 1)
  assert(first, first_err)
  local eof, eof_err = source.range_bytes(snapshot,
    #snapshot.source + 1, #snapshot.source + 1)
  assert(eof, eof_err)
  assert(first.start_byte == first.end_byte)
  assert(eof.start_byte == eof.end_byte)
  local first_edit, edit_err = edit.replace(snapshot, first, "-- head\n")
  assert(first_edit, edit_err)
  local eof_edit, eof_edit_err = edit.replace(snapshot, eof, "-- eof\n")
  assert(eof_edit, eof_edit_err)
  local result, apply_err = edit.apply(snapshot, {
      edit.fix("insert boundaries", "safe", {first_edit, eof_edit}),
    })
  assert(result, apply_err)
  assert(result.code == "-- head\nreturn 1\n-- eof\n")
end

local function test_foreign_nodes_and_ranges_refuse_even_for_same_revision_id()
  local code = "local value = 1\nreturn value\n"
  local first = parse(code, "same.tl")
  local second = parse(code, "same.tl")
  assert(first ~= second and first.id == second.id)

  local foreign_node_range, node_err = source.range(second, first.node[1])
  assert(foreign_node_range == nil and node_err:match("foreign"), tostring(node_err))

  local owned, range_err = source.range_bytes(first, 1, 1)
  assert(owned, range_err)
  local foreign_edit, edit_err = edit.replace(second, owned, "-- foreign\n")
  assert(foreign_edit == nil and edit_err:match("owned"), tostring(edit_err))

  local bad, bad_err = source.range_bytes(first, 0, 1)
  assert(bad == nil and bad_err:match("bounds"), tostring(bad_err))
end
