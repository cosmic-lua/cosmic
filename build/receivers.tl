--- Uses of a record's own fields, found through the type the checker
--- gave the value they are read from: `w:add_file(...)` or `w.add_file`
--- where `w` is a `Zip.ZipWriter` is a use of `ZipWriter.add_file` in
--- `cosmic.zip`, whatever `w` is called and however it was made.
---
--- `build.positions.references_of` answers the other half from syntax
--- alone -- `Fs.read` through a `require` alias -- and needs no
--- checker; this needs one, so it runs where a module is compiled
--- (`build.importer`'s `generate`) and its rows are kept with the
--- compile, under the same key, since what a value's type is depends
--- on every module the source imports and not only on its own bytes.
---
--- The checker's own type reporter is the hook: with `report_types` on,
--- tl calls `store_type(y, x, type)` for every node it checks. The
--- reporter installed here keeps, by position, the types that resolve
--- to a record or interface for this module's own questions, and every
--- type as tl gave it for `build.contracts`, rather than serializing
--- them the way tl's own reporter does. A
--- receiver resolves to a symbol only when its record is one some
--- module's type declares, nested under the module's own record
--- (`Zip.ZipWriter`, `Stream.Reader`): a record a file keeps to
--- itself has no row in `docs` to be a use of, and the module's own
--- record is the syntactic half's to answer.

local ast = require("build.ast")
local type compiler = require("build.compiler")

local record receivers
  --- One use of a record's field: `member` is the field's canonical
  --- path within `module` (`"ZipWriter.add_file"`), the same shape
  --- `build.positions.Reference` gives a module member.
  record Reference
    module: string
    member: string
    line: integer
  end

  --- What one compile run has learned: the types the checker stored
  --- for the module it is checking now, and which record belongs to
  --- which module, filled in as the run's environment learns modules.
  record State
    types: {integer: Type}
    --- Every type the checker stored for the module it is checking
    --- now, by position: `build.contracts` reads values' types from it.
    every: {integer: Type}
    --- The function types among them, kept apart: a node that starts
    --- where a callee does and is checked after it (the block a call
    --- opens, a table item) stores a type of its own there, which must
    --- not hide the callee's. `build.contracts` reads callees from it.
    callees: {integer: Type}
    owners: {integer: Owner}
    walked: {string: boolean}
  end

  --- The part of a tl type object read here. Every other field tl
  --- keeps on one is left undeclared.
  record Type
    typename: string
    typeid: integer
    --- A nominal's type declaration, once resolved.
    found: Type | nil
    --- A nominal's resolved definition, when it has no declaration.
    resolved: Type | nil
    --- A typedecl's definition.
    def: Type | nil
    is_alias: boolean | nil
    --- A generic's type under its type arguments.
    t: Type | nil
    tuple: {Type} | nil
    fields: {string: Type} | nil
    field_order: {string} | nil
    --- A record's or interface's interfaces, every one it inherits
    --- from included, once the checker has expanded them.
    interface_list: {Type} | nil
    --- A function's parameters and results, tuples.
    args: Type | nil
    rets: Type | nil
    --- A tuple whose last member repeats (`...: T`).
    is_va: boolean | nil
    --- A function's count of required parameters.
    min_arity: integer | nil
    --- A union's alternatives.
    types: {Type} | nil
  end

  record Owner
    module: string
    path: string
  end
end

--- A position as one integer key, the one every table in `State` is
--- keyed by: columns never reach 2^20.
function receivers.position(y: integer, x: integer): integer
  return (y << 20) | x
end
local position = receivers.position

--- The record or interface a type is, looking through declarations,
--- nominals, generics and a one-value tuple; nil for any other type.
local function record_of(t: receivers.Type | nil): receivers.Type | nil
  local at = t
  for _ = 1, 8 do
    if at == nil then
      return nil
    end
    local name = at.typename
    if name == "record" or name == "interface" then
      return at
    elseif name == "nominal" then
      at = at.found or at.resolved
    elseif name == "typedecl" then
      at = at.def
    elseif name == "generic" then
      at = at.t
    elseif name == "tuple" then
      local members = at.tuple
      if members == nil or #members ~= 1 then
        return nil
      end
      at = members[1]
    else
      return nil
    end
  end
  return nil
end

--- The interface under `t` that declares its field `name`, when `t`
--- inherits it rather than declaring it itself: the deepest one, since
--- an interface that extends another carries its fields too. nil when
--- no interface of `t` has the field.
local function declaring(t: receivers.Type, name: string,
                         seen: {receivers.Type: boolean}): receivers.Type | nil
  local list = t.interface_list
  if list == nil or seen[t] then
    return nil
  end
  seen[t] = true
  for _, listed in ipairs(list) do
    local iface = record_of(listed)
    if iface ~= nil then
      local fields = iface.fields
      if fields ~= nil and fields[name] ~= nil then
        local deeper = declaring(iface, name, seen)
        if deeper ~= nil then
          return deeper
        end
        return iface
      end
    end
  end
  return nil
end

--- A reporter for tl's checker that keeps, for the module being
--- checked (the one `gen` names `""`), each record-typed node's type by
--- position. Every other call tl makes on a reporter or a collector is
--- answered and ignored.
local function reporter_for(state: receivers.State): any
  local function ignore() end
  local ignoring = {
    store_type = ignore,
    reserve_symbol_list_slot = ignore,
    add_to_symbol_list = ignore,
    begin_symbol_list_scope = ignore,
    rollback_symbol_list_scope = ignore,
    end_symbol_list_scope = ignore,
  }
  local keeping = {
    store_type = function(y: integer, x: integer, typ: any)
      if y == nil or x == nil or typ == nil then
        return
      end
      local t = typ as receivers.Type -- cast: tl's type object
      -- A list of expressions starts where its first one does and is
      -- checked after it: its tuple does not hide that one's type.
      local at = position(y, x)
      if t.typename ~= "tuple" or state.every[at] == nil then
        state.every[at] = t
      end
      -- A position holds one callee, the last function type stored
      -- there. A chained call (`make()()`) does not collide: the outer
      -- callee is the inner call, at its own `(`, and `make` is at its
      -- name. Two callees could share a position only if tl stamped two
      -- call targets on one token, which its parser never does; only a
      -- position reaches `store_type`, so a node key is not available.
      local name = t.typename
      if name == "function" or name == "generic" or name == "poly" then
        state.callees[at] = t
      end
      local found = record_of(t)
      if found ~= nil then
        state.types[at] = found
      end
    end,
    reserve_symbol_list_slot = ignore,
    add_to_symbol_list = ignore,
    begin_symbol_list_scope = ignore,
    rollback_symbol_list_scope = ignore,
    end_symbol_list_scope = ignore,
  }
  return {
    get_collector = function(_self: any, filename: string): any
      if filename == "" then
        state.types = {}
        state.every = {}
        state.callees = {}
        return keeping
      end
      return ignoring
    end,
    store_result = ignore,
    set_ref = ignore,
    add_field = ignore,
  }
end

--- The record `path` names inside `module`'s own record, as the
--- checker holds it in `env` (`"cosmic.log"`, `"Logger"`); nil when
--- `env` has not loaded the module or it declares no such record.
function receivers.record_named(env: compiler.Env, module: string,
                                path: string): receivers.Type | nil
  local at = record_of(env.modules[module] as receivers.Type) -- cast: tl's type object
  for name in path:gmatch("[^.]+") do
    local fields = at ~= nil and at.fields or nil
    if fields == nil then return nil end
    at = record_of(fields[name])
  end
  return at
end

--- Turns the checker's type reporting on for `env`, answering into a
--- fresh state that `references` then reads.
function receivers.install(env: compiler.Env): receivers.State
  local state: receivers.State = { types = {}, every = {}, callees = {}, owners = {}, walked = {} }
  env.report_types = true
  env.reporter = reporter_for(state)
  return state
end

--- Records every record declared under `t` as owned by `module` at
--- its dotted path; the module's own record (path `""`) is not kept.
local function walk_owners(state: receivers.State, module: string, t: receivers.Type,
                           path: string, seen: {integer: boolean})
  local found = record_of(t)
  if found == nil or found.typeid == nil or seen[found.typeid] then
    return
  end
  seen[found.typeid] = true
  if path ~= "" and state.owners[found.typeid] == nil then
    state.owners[found.typeid] = { module = module, path = path }
  end
  local fields, order = found.fields, found.field_order
  if fields == nil or order == nil then
    return
  end
  for _, name in ipairs(order) do
    local field = fields[name]
    if field ~= nil and field.typename == "typedecl" and not field.is_alias then
      walk_owners(state, module, field, path == "" and name or path .. "." .. name, seen)
    end
  end
end

--- Every `x.f` read and `x:f(...)` call in `node` (the chunk the
--- checker just saw) whose `x` the checker typed as a record some
--- module in `env` declares, as that record's field; an assignment's
--- own target is a definition, not a use. In source order, once each.
function receivers.references(state: receivers.State, env: compiler.Env,
                              node: any): {receivers.Reference}
  for name, t in pairs(env.modules) do
    if not state.walked[name] then
      state.walked[name] = true
      walk_owners(state, name, t as receivers.Type, "", {}) -- cast: tl's type object
    end
  end
  local out: {receivers.Reference} = {}
  if node == nil then
    return out
  end
  local types, owners = state.types, state.owners
  -- A chunk that holds no value of a known record has nothing to walk
  -- for.
  local any_owned = false
  for _, t in pairs(types) do
    if owners[t.typeid] ~= nil then
      any_owned = true
      break
    end
  end
  if not any_owned then
    state.types = {}
    return out
  end
  local targets: {ast.Node: boolean} = {}
  local seen: {string: boolean} = {}
  local visited: {ast.Node: boolean} = {}
  local visit: function(n: ast.Node)

  -- Every node below `value` when it is a node or a bare array of
  -- them; a checker's type or fact carries no `kind` and is passed by.
  local function descend(value: {any: any})
    local kind = value["kind"]
    if kind is string then
      visit(value as ast.Node) -- cast: a node of tl's checked AST
      return
    end
    for _, child in ipairs(value as {any}) do -- cast: a bare array of nodes
      if child is {any: any} then
        local map = child as {any: any} -- cast: an element of that array
        local child_kind = map["kind"]
        if child_kind is string then
          visit(child as ast.Node) -- cast: a node of tl's checked AST
        end
      end
    end
  end

  local function consider(n: ast.Node)
    if n.kind == "assignment" and n.vars ~= nil then
      for _, var in ipairs(n.vars) do
        targets[var] = true
      end
      return
    end
    if n.kind ~= "op" or n.op == nil or targets[n] then
      return
    end
    local op = n.op.op
    if op ~= "." and op ~= ":" then
      return
    end
    local e1, e2 = n.e1, n.e2
    if e1 == nil or e2 == nil or e2.tk == nil or e1.y == nil or e1.x == nil then
      return
    end
    local typed = types[position(e1.y, e1.x)]
    if typed == nil then
      return
    end
    local owner = owners[typed.typeid]
    if owner == nil then
      return
    end
    -- A field the record inherits is a use of the interface that
    -- declares it (`Writer.write`, not `Collector.write`), when some
    -- module's type declares that interface.
    local from = declaring(typed, e2.tk, {})
    local inherited = from ~= nil and owners[from.typeid] or nil
    if inherited ~= nil then
      owner = inherited
    end
    local member = owner.path .. "." .. e2.tk
    local id = owner.module .. "\n" .. member .. "\n" .. e2.y
    if not seen[id] then
      seen[id] = true
      out[#out + 1] = { module = owner.module, member = member, line = e2.y }
    end
  end

  -- Depth first, a node before what it holds, so an assignment has
  -- marked its targets before they are reached. `if_parent` and
  -- `fn_owner` point back up the tree and are not followed.
  visit = function(n: ast.Node)
    if visited[n] then
      return
    end
    visited[n] = true
    consider(n)
    for key, value in pairs(n as {any: any}) do -- cast: every field of the node
      if value is {any: any} and key ~= "if_parent" and key ~= "fn_owner"
         and key ~= "expected" and key ~= "known" then
        descend(value as {any: any}) -- cast: narrowed just above
      end
    end
  end

  visit(node as ast.Node) -- cast: tl's checked AST
  table.sort(out, function(p: receivers.Reference, q: receivers.Reference): boolean
    if p.line ~= q.line then
      return p.line < q.line
    end
    if p.module ~= q.module then
      return p.module < q.module
    end
    return p.member < q.member
  end)
  state.types = {}
  return out
end

return receivers
