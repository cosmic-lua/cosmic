--- Lexical value bindings and references for one source snapshot.
---
--- This is syntax analysis: binding identity comes from declarations and
--- lexical scopes, never from Teal type IDs. Type names and labels use other
--- namespaces and are deliberately absent from these results.
local source_mod = require("cosmic.ast.source")
local node_mod = require("cosmic.ast.node")
local binding_types = require("cosmic.ast._binding_types")
local binding_origin = require("cosmic.ast._binding_origin")
local tl = require("tl")

local type Snapshot = source_mod.Snapshot
local type Node = node_mod.Node
local type BindingKind = binding_types.BindingKind
local type BindingId = binding_types.BindingId
local type Scope = binding_types.Scope
local type Binding = binding_types.Binding
local type Reference = binding_types.Reference
local type Bindings = binding_types.Bindings
local type Origin = binding_types.Origin
local record State
  result: Bindings
  names: {integer: {string: BindingId}}
  seen_expr: {Node: boolean}
end
local function map_of(node: Node): {any: any}
  return node as {any: any} -- cast: parser nodes have kind-specific fields
end
local function array_of(node: Node): {any}
  return node as {any} -- cast: list nodes store children in their array part
end
local function as_node(value: any): Node | nil
  if value is {any: any} then
    local kind = value["kind"]
    if kind is string then
      return value as Node -- cast: runtime kind discriminates parser nodes
    end
  end
  return nil
end
local function node_field(node: Node, key: string): Node | nil
  local value = map_of(node)[key]
  return as_node(value)
end
local function node_array_field(node: Node, key: string): {Node}
  local value = map_of(node)[key]
  local out: {Node} = {}
  if value is {any: any} then
    for _, item in ipairs(value as {any}) do -- cast: parser's bare child array
      local child = as_node(item)
      if child then
        table.insert(out, child)
      end
    end
  end
  return out
end
local function new_scope(state: State, node: Node, parent_id: integer | nil): integer
  local id = #state.result.scopes + 1
  table.insert(state.result.scopes, {id = id, parent_id = parent_id, node = node})
  state.names[id] = {}
  return id
end
local function add_binding(state: State, scope_id: integer, node: Node,
    name: string, kind: BindingKind, is_implicit?: boolean,
    activation?: Node, activates_after?: boolean): Binding
  local id = #state.result.all + 1
  local binding: Binding = {
    id = id,
    name = name,
    kind = kind,
    declaration = node,
    activation = activation or node,
    activates_after = activates_after or false,
    scope_id = scope_id,
    is_import = false,
    is_implicit = is_implicit or false,
  }
  table.insert(state.result.all, binding)
  state.names[scope_id][name] = id
  state.result.binding_by_node[node] = id
  state.result.references_by_binding[id] = {}
  return binding
end
local function resolve(state: State, scope_id: integer, name: string): BindingId | nil
  local current: integer | nil = scope_id
  while current do
    local id = state.names[current][name]
    if id then
      return id
    end
    current = state.result.scopes[current].parent_id
  end
  return nil
end
local function add_reference(state: State, scope_id: integer, node: Node,
    is_write?: boolean)
  local name = node.tk
  if not name then
    return
  end
  local id = resolve(state, scope_id, name)
  if not id then
    state.result.unresolved[node] = true
    return
  end
  local ref: Reference = {
    node = node,
    binding_id = id,
    scope_id = scope_id,
    is_write = is_write or false,
  }
  table.insert(state.result.references, ref)
  table.insert(state.result.references_by_binding[id], ref)
  state.result.reference_by_node[node] = ref
  if ref.is_write then
    local binding = state.result.all[id]
    if binding.is_import then
      binding.origin = nil
      binding.origin_reason = "import binding is reassigned or mutated"
    end
  end
end

local process_block: function(State, Node, integer)
local process_function: function(State, Node, integer)
local visit_expression: function(State, Node | nil, integer, boolean)

local SKIP_FIELDS: {string: boolean} = {
  kind = true, f = true, y = true, x = true, yend = true, xend = true,
  tk = true, op = true, if_parent = true, casttype = true, expected = true,
  typeargs = true, rets = true, decltype = true, decltuple = true,
  argtype = true, newtype = true, itemtype = true,
}

visit_expression = function(state: State, node: Node | nil, scope_id: integer,
    is_write: boolean)
  if not node then
    return
  end
  if node.kind == "variable" then
    add_reference(state, scope_id, node, is_write)
    return
  end
  if node.kind == "function" then
    process_function(state, node, scope_id)
    return
  end
  if node.kind == "macroexp" then
    state.result.unsupported[node] = "macro expression scopes are unsupported"
    return
  end
  if state.seen_expr[node] then
    return
  end
  state.seen_expr[node] = true
  for _, value in ipairs(array_of(node)) do
    local child = as_node(value)
    if child then
      visit_expression(state, child, scope_id, is_write)
    end
  end
  for key, child in pairs(map_of(node)) do
    if key is string and not SKIP_FIELDS[key] and child is {any: any} then
      local direct = as_node(child)
      if direct then
        visit_expression(state, direct, scope_id, is_write)
      else
        for _, item in ipairs(child as {any}) do -- cast: parser's bare child array
          local nested = as_node(item)
          if nested then
            visit_expression(state, nested, scope_id, is_write)
          end
        end
      end
    end
  end
end

local function mark_record_owner(state: State, owner: Node)
  state.result.unsupported[owner] = "record function owners are not value references"
  if owner.kind == "op" and owner.e1 then
    mark_record_owner(state, owner.e1)
  end
end

local function is_explicit_global(state: State, node: Node): boolean
  local previous: tl.Token | nil = nil
  for _, token in ipairs(state.result.snapshot.tokens) do
    if token.y == node.y and token.x == node.x then
      return previous ~= nil and previous.tk == "global"
    end
    previous = token
  end
  return false
end

local record RequireSite
  module: string | nil
end

local function direct_require(state: State, node: Node | nil,
    scope_id: integer): RequireSite | nil
  if not node or node.kind ~= "op" then
    return nil
  end
  local op = node.op
  local callee = node.e1
  local args = node.e2
  if not op or op.op ~= "@funcall" or not callee or callee.kind ~= "variable"
  or callee.tk ~= "require" or not args then
    return nil
  end
  -- A same-named lexical local is an ordinary function, not the loader.
  if state.result.reference_by_node[callee] then
    return nil
  end
  -- An unresolved name is only the standard global while the implicit root
  -- environment is in force. A lexical `_ENV` can supply a different value.
  local environment_id = resolve(state, scope_id, "_ENV")
  local environment = environment_id and state.result.all[environment_id] or nil
  if not environment or environment.kind ~= "environment" then
    return nil
  end
  local first_arg = as_node(array_of(args)[1])
  if first_arg and first_arg.kind == "string" then
    local conststr = first_arg.conststr
    if conststr then
      return {module = conststr}
    end
  end
  return {}
end

process_function = function(state: State, node: Node, outer_scope: integer)
  local body = node_field(node, "body")
  if not body then
    state.result.unsupported[node] = "function has no syntax body"
    return
  end
  local fn_scope = new_scope(state, body, outer_scope)
  if node.kind == "global_function" and is_explicit_global(state, node) then
    local name = node_field(node, "name")
    if name and name.tk then
      add_binding(state, fn_scope, name, name.tk, "global_function", true)
    end
  end
  local args = node_field(node, "args")
  if args then
    for _, value in ipairs(array_of(args)) do
      local param_node = as_node(value)
      if param_node then
        local name = param_node.tk
        if name and name ~= "..." then
          local is_self = param_node.kind == "identifier"
          and map_of(param_node)["is_self"] == true
          local kind: BindingKind = is_self and "self" or "parameter"
          add_binding(state, fn_scope, param_node, name, kind, is_self)
        end
      end
    end
  end
  process_block(state, body, fn_scope)
end

local function process_local(state: State, stmt: Node, scope_id: integer)
  local exps = node_field(stmt, "exps")
  visit_expression(state, exps, scope_id, false)
  local vars = node_field(stmt, "vars")
  if not vars then
    state.result.unsupported[stmt] = "local declaration has no variable list"
    return
  end
  local var_nodes = array_of(vars)
  local exp_nodes = exps and array_of(exps) or {}
  for i, item in ipairs(var_nodes) do
    local var = as_node(item)
    if var then
      if var.tk then
        local binding = add_binding(state, scope_id, var, var.tk, "local",
          false, stmt, true)
        local exp = as_node(exp_nodes[i])
        local require_site = exp and direct_require(state, exp, scope_id) or nil
        if require_site then
          binding.is_import = true
          if #var_nodes == #exp_nodes then
            binding.origin = require_site.module
            if not binding.origin then
              binding.origin_reason = "require module name is dynamic"
            end
          else
            binding.origin_reason = "require result has ambiguous multi-value binding"
          end
        end
      end
    end
  end
end

local function process_global(state: State, stmt: Node, scope_id: integer)
  visit_expression(state, node_field(stmt, "exps"), scope_id, false)
  local vars = node_field(stmt, "vars")
  if not vars then
    state.result.unsupported[stmt] = "global declaration has no variable list"
    return
  end
  for _, item in ipairs(array_of(vars)) do
    local var = as_node(item)
    if var then
      state.result.unsupported[var] = "global declarations are not local bindings"
    end
  end
end

local function process_loop(state: State, stmt: Node, scope_id: integer)
  if stmt.kind == "forin" then
    visit_expression(state, node_field(stmt, "exps"), scope_id, false)
  else
    visit_expression(state, node_field(stmt, "from"), scope_id, false)
    visit_expression(state, node_field(stmt, "to"), scope_id, false)
    visit_expression(state, node_field(stmt, "step"), scope_id, false)
  end
  local body = node_field(stmt, "body")
  if not body then
    state.result.unsupported[stmt] = "loop has no syntax body"
    return
  end
  local loop_scope = new_scope(state, body, scope_id)
  if stmt.kind == "forin" then
    local vars = node_field(stmt, "vars")
    if vars then
      for _, value in ipairs(array_of(vars)) do
        local var = as_node(value)
        if var and var.tk then
          add_binding(state, loop_scope, var, var.tk, "loop")
        end
      end
    end
  else
    local var = node_field(stmt, "var")
    if var and var.tk then
      add_binding(state, loop_scope, var, var.tk, "loop")
    end
  end
  process_block(state, body, loop_scope)
end

local function process_statement(state: State, stmt: Node, scope_id: integer)
  if stmt.kind == "local_declaration" then
    process_local(state, stmt, scope_id)
  elseif stmt.kind == "global_declaration" then
    process_global(state, stmt, scope_id)
  elseif stmt.kind == "local_function" then
    local name = node_field(stmt, "name")
    if name and name.tk then
      add_binding(state, scope_id, name, name.tk, "local_function")
    else
      state.result.unsupported[stmt] = "local function has no declaration name"
    end
    process_function(state, stmt, scope_id)
  elseif stmt.kind == "global_function" or stmt.kind == "record_function" then
    if stmt.kind == "global_function" then
      local name = node_field(stmt, "name")
      if name then
        if is_explicit_global(state, stmt) then
          state.result.unsupported[name] = "global declarations are not local bindings"
        else
          add_reference(state, scope_id, name, true)
        end
      end
    else
      local owner = node_field(stmt, "fn_owner")
      if owner then
        mark_record_owner(state, owner)
      end
    end
    process_function(state, stmt, scope_id)
  elseif stmt.kind == "local_macroexp" then
    state.result.unsupported[stmt] = "macro expression scopes are unsupported"
  elseif stmt.kind == "forin" or stmt.kind == "fornum" then
    process_loop(state, stmt, scope_id)
  elseif stmt.kind == "repeat" then
    local body = node_field(stmt, "body")
    if body then
      local repeat_scope = new_scope(state, body, scope_id)
      process_block(state, body, repeat_scope)
      visit_expression(state, node_field(stmt, "exp"), repeat_scope, false)
    end
  elseif stmt.kind == "while" then
    visit_expression(state, node_field(stmt, "exp"), scope_id, false)
    local body = node_field(stmt, "body")
    if body then
      local body_scope = new_scope(state, body, scope_id)
      process_block(state, body, body_scope)
    end
  elseif stmt.kind == "do" then
    local body = node_field(stmt, "body")
    if body then
      local body_scope = new_scope(state, body, scope_id)
      process_block(state, body, body_scope)
    end
  elseif stmt.kind == "if" then
    for _, branch in ipairs(node_array_field(stmt, "if_blocks")) do
      visit_expression(state, node_field(branch, "exp"), scope_id, false)
      local body = node_field(branch, "body")
      if body then
        local body_scope = new_scope(state, body, scope_id)
        process_block(state, body, body_scope)
      end
    end
  elseif stmt.kind == "assignment" then
    visit_expression(state, node_field(stmt, "vars"), scope_id, true)
    visit_expression(state, node_field(stmt, "exps"), scope_id, false)
  elseif stmt.kind == "local_type" or stmt.kind == "global_type"
  or stmt.kind == "label" or stmt.kind == "goto" then
    state.result.unsupported[stmt] = "type names and labels are outside value bindings"
    local type_name = node_field(stmt, "var")
    if type_name then
      state.result.unsupported[type_name] =
      "type names and labels are outside value bindings"
    end
  else
    visit_expression(state, stmt, scope_id, false)
  end
end

process_block = function(state: State, block: Node, scope_id: integer)
  for _, item in ipairs(array_of(block)) do
    local stmt = as_node(item)
    if stmt then
      process_statement(state, stmt, scope_id)
    end
  end
end

--- Analyze lexical value declarations and references in `snapshot`.
--- @param snapshot Snapshot Parsed source snapshot
--- @return Bindings|nil Binding result
--- @return string error Invalid snapshot error
local function analyze(snapshot: Snapshot): Bindings | nil, string
  if not snapshot.node or snapshot.node.kind ~= "statements" then
    return nil, "bindings require a source snapshot with a statements root"
  end
  local result: Bindings = {
    snapshot = snapshot,
    all = {}, scopes = {}, references = {}, binding_by_node = {},
    reference_by_node = {}, references_by_binding = {}, unresolved = {},
    unsupported = {},
  }
  local state: State = {result = result, names = {}, seen_expr = {}}
  local root_scope = new_scope(state, snapshot.node, nil)
  add_binding(state, root_scope, snapshot.node, "_ENV", "environment", true)
  process_block(state, snapshot.node, root_scope)
  return result, nil
end

--- Return the binding declared by or referenced at `node`.
local function binding_of(bindings: Bindings, node: Node): Binding | nil
  local id = bindings.binding_by_node[node]
  if not id then
    local ref = bindings.reference_by_node[node]
    id = ref and ref.binding_id or nil
  end
  return id and bindings.all[id] or nil
end

--- Return every resolved reference to `id`, in source traversal order.
local function references_of(bindings: Bindings, id: BindingId): {Reference}
  return bindings.references_by_binding[id] or {}
end

local record BindingsModule
  type BindingKind = BindingKind
  type BindingId = BindingId
  type Scope = Scope
  type Binding = Binding
  type Reference = Reference
  type Bindings = Bindings
  type Origin = Origin
  analyze: function(Snapshot): Bindings | nil, string
  binding_of: function(Bindings, Node): Binding | nil
  references_of: function(Bindings, BindingId): {Reference}
  import_origin: function(Bindings, BindingId): string | nil
  origin_of: function(Bindings, Node): Origin
  is_from: function(Bindings, Node, string): boolean | nil, string
end

local M: BindingsModule = {
  analyze = analyze,
  binding_of = binding_of,
  references_of = references_of,
  import_origin = binding_origin.import_origin,
  origin_of = binding_origin.origin_of,
  is_from = binding_origin.is_from,
}

return M
