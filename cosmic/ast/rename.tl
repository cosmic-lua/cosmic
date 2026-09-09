--- Safe, snapshot-owned local rename planning.
---
--- A plan contains the declaration and every lexically resolved reference in
--- one atomic fix. It refuses names that collide in the declaration scope or
--- would capture a reference in a nested scope.
local source = require("cosmic.ast.source")
local bindings_mod = require("cosmic.ast.bindings")
local edit = require("cosmic.edit")
local node_mod = require("cosmic.ast.node")

local type Node = node_mod.Node
local type Bindings = bindings_mod.Bindings
local type Binding = bindings_mod.Binding
local type BindingId = bindings_mod.BindingId
local type Fix = edit.Fix

local RESERVED: {string: boolean} = {
  ["and"] = true, ["break"] = true, ["do"] = true, ["else"] = true,
  ["elseif"] = true, ["end"] = true, ["false"] = true, ["for"] = true,
  ["function"] = true, ["goto"] = true, ["if"] = true, ["in"] = true,
  ["local"] = true, ["nil"] = true, ["not"] = true, ["or"] = true,
  ["repeat"] = true, ["return"] = true, ["then"] = true, ["true"] = true,
  ["until"] = true, ["while"] = true,
  -- Teal's contextual declaration/type words can change the parse at a
  -- declaration or statement boundary even though the lexer calls them names.
  ["as"] = true, ["enum"] = true, ["global"] = true, ["interface"] = true,
  ["is"] = true, ["macroexp"] = true, ["metamethod"] = true,
  ["record"] = true, ["type"] = true,
}

local function valid_name(name: string): boolean
  return name:match("^[A-Za-z_][A-Za-z0-9_]*$") ~= nil and not RESERVED[name]
end

local function binding_named(bindings: Bindings, scope_id: integer,
    name: string, except_id: BindingId): Binding | nil
  for _, candidate in ipairs(bindings.all) do
    if candidate.id ~= except_id and candidate.scope_id == scope_id
    and candidate.name == name then
      return candidate
    end
  end
  return nil
end

local function is_active_at(bindings: Bindings, candidate: Binding,
    node: Node): boolean
  local activation = source.range(bindings.snapshot, candidate.activation)
  local use = source.range(bindings.snapshot, node)
  if not activation or not use then
    return true
  end
  if candidate.activates_after then
    return activation.end_byte <= use.start_byte
  end
  return activation.start_byte <= use.start_byte
end

local function check_collisions(bindings: Bindings, binding: Binding,
    new_name: string): string | nil
  local collision = binding_named(bindings, binding.scope_id, new_name, binding.id)
  if collision then
    return string.format("cannot rename '%s' to '%s': that name is already bound"
      .. " in the declaration scope", binding.name, new_name)
  end

  for _, ref in ipairs(bindings_mod.references_of(bindings, binding.id)) do
    local scope_id: integer | nil = ref.scope_id
    local reached_declaration_scope = false
    while scope_id do
      local capture = binding_named(bindings, scope_id, new_name, binding.id)
      if capture and is_active_at(bindings, capture, ref.node) then
        return string.format("cannot rename '%s' to '%s': reference at %d:%d"
          .. " would be captured", binding.name, new_name, ref.node.y, ref.node.x)
      end
      if scope_id == binding.scope_id then
        reached_declaration_scope = true
        break
      end
      local scope = bindings.scopes[scope_id]
      scope_id = scope and scope.parent_id or nil
    end
    if not reached_declaration_scope then
      return "cannot rename: binding analysis produced a reference outside its scope"
    end
  end
  return nil
end

local function add_name_edit(bindings: Bindings, node: Node, old_name: string,
    new_name: string, edits: {edit.Edit}): string | nil
  local range, range_err = source.range(bindings.snapshot, node)
  if not range then
    return "cannot rename unsupported or synthetic declaration/reference: "
    .. (range_err or "source range unavailable")
  end
  local actual = bindings.snapshot.source:sub(range.start_byte, range.end_byte - 1)
  if actual ~= old_name then
    return string.format("cannot rename: expected identifier '%s' at %d:%d, found '%s'",
      old_name, node.y, node.x, actual)
  end
  local replacement, edit_err = edit.replace(bindings.snapshot, range, new_name)
  if not replacement then
    return edit_err
  end
  table.insert(edits, replacement)
  return nil
end

--- Plan one atomic rename of a lexical local declaration and all references.
--- @param bindings Bindings Result for the current snapshot
--- @param id BindingId Declaration identity returned by bindings analysis
--- @param new_name string New identifier spelling
--- @return Fix|nil Safe edit group, or nil on refusal
--- @return string error Refusal reason
local function plan(bindings: Bindings, id: BindingId,
    new_name: string): Fix | nil, string
  local binding = bindings.all[id]
  if not binding then
    return nil, "cannot rename: unknown binding id"
  end
  if binding.is_implicit or binding.kind == "environment" or binding.kind == "self" then
    return nil, "cannot rename an implicit binding"
  end
  if binding.name == "_ENV" or new_name == "_ENV" then
    return nil, "cannot safely rename _ENV with lexical references alone"
  end
  if new_name == binding.name then
    return nil, "cannot rename: new name is unchanged"
  end
  if not valid_name(new_name) then
    return nil, "cannot rename: new name is not a safe identifier"
  end

  local collision_err = check_collisions(bindings, binding, new_name)
  if collision_err then
    return nil, collision_err
  end

  -- A record-function owner inhabits Teal's type namespace. Its parser shape is
  -- also used for dotted function definitions, so do not guess that a matching
  -- spelling is a value reference in a dialect we have not proved here.
  for node, reason in pairs(bindings.unsupported) do
    if reason == "macro expression scopes are unsupported" then
      return nil, "cannot rename in a file with unsupported macro expression scopes"
    elseif reason == "record function owners are not value references"
    and node.tk == binding.name then
      return nil, "cannot rename: a same-named record function owner is unsupported"
    end
  end

  local edits: {edit.Edit} = {}
  local declaration_err = add_name_edit(bindings, binding.declaration,
    binding.name, new_name, edits)
  if declaration_err then
    return nil, declaration_err
  end
  for _, ref in ipairs(bindings_mod.references_of(bindings, binding.id)) do
    local ref_err = add_name_edit(bindings, ref.node, binding.name, new_name, edits)
    if ref_err then
      return nil, ref_err
    end
  end

  return {
    title = string.format("Rename '%s' to '%s'", binding.name, new_name),
    applicability = "safe",
    edits = edits,
  }, nil
end

--- Plan a rename from a declaration/reference node, with explicit refusals for
--- type-name and label/goto syntax that does not belong to the value namespace.
local function plan_node(bindings: Bindings, node: Node,
    new_name: string): Fix | nil, string
  local unsupported = bindings.unsupported[node]
  if unsupported then
    return nil, "cannot rename this syntax: " .. unsupported
  end
  local binding = bindings_mod.binding_of(bindings, node)
  if not binding then
    return nil, "cannot rename: node is not a resolved local value"
  end
  return plan(bindings, binding.id, new_name)
end

local record RenameModule
  plan: function(Bindings, BindingId, string): Fix | nil, string
  plan_node: function(Bindings, Node, string): Fix | nil, string
end

local M: RenameModule = {
  plan = plan,
  plan_node = plan_node,
}

return M
