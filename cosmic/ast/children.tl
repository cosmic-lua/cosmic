--- Deterministic grammar-owned child edges for Teal parser nodes.
local node_mod = require("cosmic.ast.node")
local type Node = node_mod.Node

local record Child
  node: Node
  role: string
end

local array_kinds: {string: string} = {
  statements = "statement", argument_list = "argument", literal_table = "item",
  variable_list = "variable", expression_list = "expression",
}

local known_kinds: {string: boolean} = {
  statements = true, argument_list = true, literal_table = true,
  variable_list = true, expression_list = true, op = true,
  literal_table_item = true, assignment = true, local_declaration = true,
  global_declaration = true, local_type = true, global_type = true, ["if"] = true,
  if_block = true, ["while"] = true, ["repeat"] = true, macroexp = true,
  ["function"] = true, local_function = true, global_function = true,
  record_function = true, local_macroexp = true, forin = true, fornum = true,
  ["return"] = true, ["do"] = true, paren = true, newtype = true,
  ["..."] = true, ["nil"] = true, cast = true, ["goto"] = true,
  ["break"] = true, label = true, number = true, string = true,
  boolean = true, integer = true, variable = true, identifier = true,
  type_identifier = true, argument = true,
}

local function is_known(node: Node): boolean
  return not not known_kinds[node.kind]
end

local function as_node(value: any): Node | nil
  if value is {any: any} then
    local kind = value["kind"]
    if kind is string then return value as Node end -- cast: parser discriminator
  end
  return nil
end

local function field(node: Node, name: string): any
  return (node as {any: any})[name] -- cast: grammar-owned parser field
end

local function append(out: {Child}, value: any, role: string)
  local child = as_node(value)
  if child then out[#out + 1] = {node = child, role = role} end
end

--- Return child syntax nodes in grammar order; unknown kinds are opaque.
local function children(node: Node): {Child}
  local out: {Child} = {}
  local array_role = array_kinds[node.kind]
  if array_role then
    for i, child in ipairs(node as {any}) do -- cast: grammar array node
      append(out, child, array_role .. "[" .. i .. "]")
    end
    return out
  end
  local kind = node.kind
  if kind == "op" then
    append(out, field(node, "e1"), "left")
    if field(node, "e2") ~= nil then
      local op = node.op
      append(out, field(node, "e2"),
        (op and (op.op == "as" or op.op == "is")) and "type_operand" or "right")
    end
  elseif kind == "literal_table_item" then
    append(out, field(node, "key"), "key"); append(out, field(node, "value"), "value")
  elseif kind == "assignment" or kind == "local_declaration"
  or kind == "global_declaration" then
    append(out, field(node, "vars"), "declarations")
    append(out, field(node, "exps"), "values")
  elseif kind == "local_type" or kind == "global_type" then
    append(out, field(node, "var"), "declaration_name")
    append(out, field(node, "value"), "type_value")
  elseif kind == "if" then
    local blocks = field(node, "if_blocks")
    if blocks is {any} then
      for i, block in ipairs(blocks) do append(out, block, "branch[" .. i .. "]") end
    end
  elseif kind == "if_block" then
    append(out, field(node, "exp"), "condition"); append(out, field(node, "body"), "body")
  elseif kind == "while" then
    append(out, field(node, "exp"), "condition"); append(out, field(node, "body"), "body")
  elseif kind == "repeat" then
    append(out, field(node, "body"), "body"); append(out, field(node, "exp"), "condition")
  elseif kind == "macroexp" then
    append(out, field(node, "args"), "parameters"); append(out, field(node, "exp"), "value")
  elseif kind == "function" then
    append(out, field(node, "args"), "parameters"); append(out, field(node, "body"), "body")
  elseif kind == "local_function" or kind == "global_function" then
    append(out, field(node, "name"), "declaration_name")
    append(out, field(node, "args"), "parameters"); append(out, field(node, "body"), "body")
  elseif kind == "record_function" then
    append(out, field(node, "fn_owner"), "owner")
    append(out, field(node, "name"), "declaration_name")
    append(out, field(node, "args"), "parameters"); append(out, field(node, "body"), "body")
  elseif kind == "local_macroexp" then
    append(out, field(node, "name"), "declaration_name")
    local macrodef = field(node, "macrodef")
    if macrodef is {any: any} then
      append(out, macrodef["args"], "parameters"); append(out, macrodef["exp"], "value")
    end
  elseif kind == "forin" then
    append(out, field(node, "vars"), "declarations")
    append(out, field(node, "exps"), "values"); append(out, field(node, "body"), "body")
  elseif kind == "fornum" then
    append(out, field(node, "var"), "declaration")
    append(out, field(node, "from"), "start"); append(out, field(node, "to"), "stop")
    append(out, field(node, "step"), "step"); append(out, field(node, "body"), "body")
  elseif kind == "return" then
    append(out, field(node, "exps"), "values")
  elseif kind == "do" then
    append(out, field(node, "body"), "body")
  elseif kind == "paren" then
    append(out, field(node, "e1"), "expression")
  end
  return out
end

local record ChildrenModule
  type Child = Child
  children: function(node: Node): {Child}
  is_known: function(node: Node): boolean
end

local M: ChildrenModule = {children = children, is_known = is_known}
return M
