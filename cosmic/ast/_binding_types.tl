--- Shared records for lexical binding analysis.
local source = require("cosmic.ast.source")
local node_mod = require("cosmic.ast.node")

local type Snapshot = source.Snapshot
local type Node = node_mod.Node

local enum BindingKind
  "local"
  "local_function"
  "parameter"
  "loop"
  "self"
  "environment"
  "global_function"
end

local type BindingId = integer

local record Scope
  id: integer
  parent_id: integer | nil
  node: Node
end

local record Binding
  id: BindingId
  name: string
  kind: BindingKind
  declaration: Node
  activation: Node
  activates_after: boolean
  scope_id: integer
  origin: string | nil
  origin_reason: string | nil
  is_import: boolean
  is_implicit: boolean
end

local record Reference
  node: Node
  binding_id: BindingId
  scope_id: integer
  is_write: boolean
end

local record Bindings
  snapshot: Snapshot
  all: {Binding}
  scopes: {Scope}
  references: {Reference}
  binding_by_node: {Node: BindingId}
  reference_by_node: {Node: Reference}
  references_by_binding: {BindingId: {Reference}}
  unresolved: {Node: boolean}
  unsupported: {Node: string}
end

local record Origin
  module: string | nil
  reason: string | nil
  proven: boolean
end

local record BindingTypes
  type BindingKind = BindingKind
  type BindingId = BindingId
  type Scope = Scope
  type Binding = Binding
  type Reference = Reference
  type Bindings = Bindings
  type Origin = Origin
end

return {} as BindingTypes -- cast: type-only module has no runtime fields
