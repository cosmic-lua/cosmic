#!/usr/bin/env cosmic
local source_mod = require("cosmic.ast.source")
local children_mod = require("cosmic.ast.children")

local type Snapshot = source_mod.Snapshot
local type Node = source_mod.Node
local type Range = source_mod.Range

local function parse_ok(text: string, name: string, lang?: string): Snapshot
  local snapshot, err = source_mod.parse(text, name, lang)
  assert(snapshot, err)
  return snapshot
end

local function slice(snapshot: Snapshot, range: Range): string
  return snapshot.source:sub(range.start_byte, range.end_byte - 1)
end

local function node_range(snapshot: Snapshot, node: Node): Range
  local range, err = source_mod.range(snapshot, node)
  assert(range, err)
  return range
end

local function find_node(snapshot: Snapshot, kind: string,
    token?: string): Node | nil
  local found: Node | nil
  local function visit(node: Node)
    if not found and node.kind == kind and (not token or node.tk == token) then
      found = node
      return
    end
    for _, child in ipairs(children_mod.children(node)) do visit(child.node) end
  end
  visit(snapshot.node)
  return found
end

local function syntax_slice(snapshot: Snapshot, role: string): string | nil
  for _, syntax in ipairs(snapshot.types) do
    if syntax.role == role then return slice(snapshot, syntax.range) end
  end
  return nil
end

local function test_snapshot_identity_language_and_root_range()
  local one = parse_ok("local x = 1\n", "same.tl")
  local same = parse_ok("local x = 1\n", "same.tl")
  local renamed = parse_ok("local x = 1\n", "other.tl")
  local lua = parse_ok("local x = 1\n", "same.lua")
  assert(one.lang == "tl" and lua.lang == "lua")
  assert(one.id == same.id)
  assert(one.id ~= renamed.id and one.id ~= lua.id)
  assert(slice(one, node_range(one, one.node)) == one.source)
  assert(source_mod.parent(one, one.node) == nil)
  assert(source_mod.role(one, one.node) == "root")
end

local function test_empty_crlf_utf8_and_arbitrary_ranges()
  local empty = parse_ok("", "empty.tl")
  local root = node_range(empty, empty.node)
  assert(root.start_byte == 1 and root.end_byte == 1)
  local text = "local s = \"λ\"\r\nlocal t = [[α\nβ]]\n"
  local snapshot = parse_ok(text, "utf8.tl")
  assert(snapshot.line_starts[1] == 1)
  assert(snapshot.line_starts[2] == assert(text:find("\n", 1, true)) + 1)
  local utf8_node = assert(find_node(snapshot, "string", "\"λ\""))
  assert(slice(snapshot, node_range(snapshot, utf8_node)) == "\"λ\"")
  local insertion = assert(source_mod.range_bytes(snapshot, #text + 1, #text + 1))
  assert(snapshot.owned_ranges[insertion] and slice(snapshot, insertion) == "")
  local invalid, err = source_mod.range_bytes(snapshot, 0, 1)
  assert(not invalid and err ~= nil)
end

local function test_parent_roles_and_branch_backlinks()
  local snapshot = parse_ok(
    "if first then first_call() else else_call() end\n", "branches.tl")
  local if_node = snapshot.node[1]
  local blocks = assert(if_node.if_blocks)
  local first = blocks[1]
  local second = blocks[2]
  assert(source_mod.parent(snapshot, first) == if_node)
  assert(source_mod.role(snapshot, first) == "branch[1]")
  assert(source_mod.role(snapshot, second) == "branch[2]")
  assert(source_mod.parent(snapshot, first.body) == first)
  assert(source_mod.role(snapshot, first.body) == "body")
end

local function test_call_and_parenthesis_ranges_own_closing_delimiters()
  local snapshot = parse_ok("local x = f(a + (b))\n", "calls.tl")
  local declaration = snapshot.node[1]
  assert(slice(snapshot, node_range(snapshot, declaration)) ==
    "local x = f(a + (b))")
  local call = assert(find_node(snapshot, "op"))
  assert(slice(snapshot, node_range(snapshot, call)) == "f(a + (b))")
  local paren = assert(find_node(snapshot, "paren"))
  assert(slice(snapshot, node_range(snapshot, paren)) == "(b)")
end

local function test_type_attribute_and_generic_ranges_use_original_token_tape()
  local text = "local x <const>: (Map<List<string>>) = nil\n"
  local snapshot = parse_ok(text, "types.tl")
  assert(syntax_slice(snapshot, "declaration_types") == "(Map<List<string>>)")
  assert(syntax_slice(snapshot, "declared_type") == "Map<List<string>>")
  assert(#snapshot.attributes == 1)
  assert(snapshot.attributes[1].name == "const")
  assert(slice(snapshot, snapshot.attributes[1].range) == "<const>")
  local saw_outer, saw_inner = false, false
  for _, generic in ipairs(snapshot.generics) do
    local got = slice(snapshot, generic.range)
    if got == "<List<string>>" then saw_outer = true end
    if got == "<string>" then saw_inner = true end
  end
  assert(saw_outer and saw_inner)
  local shifts = 0
  for _, token in ipairs(snapshot.tokens) do
    if token.tk == ">>" then shifts = shifts + 1 end
  end
  assert(shifts == 1, "snapshot token tape was mutated by generic parsing")
end

local function test_function_returns_and_record_fields_are_type_syntax()
  local fn = parse_ok(table.concat({
        "local function f<T>(a: function<X>(x: X): (T, string)):",
        "  (Map<List<T>>)",
        "  return nil",
        "end",
      }, "\n"), "function_types.tl")
  assert(syntax_slice(fn, "return_types") == "(Map<List<T>>)")
  assert(syntax_slice(fn, "parameter_type") ==
    "function<X>(x: X): (T, string)")
  local saw_parameters = false
  for _, generic in ipairs(fn.generics) do
    if slice(fn, generic.range) == "<T>" then saw_parameters = true end
  end
  assert(saw_parameters)

  local record_snapshot = parse_ok(table.concat({
        "local record R<T>",
        "  field: (Map<List<T>>)",
        "end",
      }, "\n"), "record.tl")
  local saw_field = false
  for _, syntax in ipairs(record_snapshot.types) do
    local field_role = syntax.role:match("%.field%[field%]$") ~= nil
    local exact_range = slice(record_snapshot, syntax.range) == "(Map<List<T>>)"
    if field_role and exact_range then saw_field = true end
  end
  assert(saw_field, "record field type was not indexed")
end

local function test_parse_issues_are_structured_and_foreign_nodes_are_refused()
  local result = source_mod.inspect("if x then", "broken.tl")
  assert(not result.snapshot and #result.issues > 0)
  assert(result.issues[1].phase == "parse")
  assert(result.issues[1].line > 0 and result.issues[1].column > 0)
  local snapshot = parse_ok("local x = 1\n", "foreign.tl")
  local other = parse_ok("local x = 1\n", "other.tl")
  local range, err = source_mod.range(snapshot, other.node[1])
  assert(not range and err ~= nil)
end
