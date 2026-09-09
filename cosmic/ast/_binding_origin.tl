--- Proven module-origin queries over lexical binding results.
local binding_types = require("cosmic.ast._binding_types")
local node_mod = require("cosmic.ast.node")

local type Bindings = binding_types.Bindings
local type Binding = binding_types.Binding
local type BindingId = binding_types.BindingId
local type Origin = binding_types.Origin
local type Node = node_mod.Node

local function binding_of(bindings: Bindings, node: Node): Binding | nil
  local id = bindings.binding_by_node[node]
  if not id then
    local ref = bindings.reference_by_node[node]
    id = ref and ref.binding_id or nil
  end
  return id and bindings.all[id] or nil
end

local function import_origin(bindings: Bindings, id: BindingId): string | nil
  local binding = bindings.all[id]
  return binding and binding.origin or nil
end

local function origin_of(bindings: Bindings, node: Node): Origin
  local current: Node | nil = node
  local binding: Binding | nil = nil
  while current do
    binding = binding_of(bindings, current)
    if binding then
      break
    end
    local op = current.op
    if op and (op.op == "." or op.op == "@index" or op.op == "@funcall"
      or op.op == "@method") then
      current = current.e1
    else
      current = nil
    end
  end
  if not binding then
    return {proven = false, reason = "node is not a resolved local binding"}
  end
  if binding.origin then
    return {proven = true, module = binding.origin}
  end
  return {
    proven = false,
    reason = binding.origin_reason or "binding is not a proven direct import",
  }
end

local function is_from(bindings: Bindings, node: Node,
    module: string): boolean | nil, string
  local origin = origin_of(bindings, node)
  if not origin.proven then
    return nil, origin.reason
  end
  return origin.module == module, nil
end

local record OriginModule
  import_origin: function(Bindings, BindingId): string | nil
  origin_of: function(Bindings, Node): Origin
  is_from: function(Bindings, Node, string): boolean | nil, string
end

local M: OriginModule = {
  import_origin = import_origin,
  origin_of = origin_of,
  is_from = is_from,
}

return M
