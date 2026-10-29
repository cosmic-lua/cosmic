--- Whether a scope build is consistent with its tree, whatever the source and
--- the errors in it: the check that [`lang.scopes`] resolves the names of a
--- chunk the way Lua's scoping says, as [`lang.parser_cover`] checks the tree
--- is a tree over its tokens.
---
--- It does not walk scopes. It reads the tokens: a binding is in scope for the
--- tokens from `from` to `to`, and the binding a name uses is the one of its
--- name, in scope at the name, that begins last. So every name resolves to a
--- binding declared before it in an enclosing scope, or is a recorded global,
--- and the sets of reads, writes, captures and globals agree with the names of
--- the tree. Every binding of the tree has a [`Var`](lang.scopes) and every error has a code, a message
--- and a fix, lies at the token it names and comes in source order.
local Ast = require("lang.ast")
local Lexer = require("lang.lexer")
local Scopes = require("lang.scopes")

local record Cover
  --- Whether `scoped`, the result of [`Scopes.build`] on `chunk` with the globals `declared`, is
  --- consistent with the tree, or `false` and the first way it is not.
  check: function(chunk: Ast.Chunk, scoped: Scopes.Scoped, declared: {string: Scopes.Global}): boolean, string
end

local function base_of(node: Ast.Node): Ast.Base
  return node
end

--- What one pass over the tree finds.
local record Found
  names: mut {Ast.Name}
  types: mut {Ast.TypeName}
  bindings: mut {Ast.Binding}
  --- The ids of the names a function statement path holds that are no uses.
  members: mut {integer: boolean}
  --- The ids of the function statements written with a colon.
  colons: mut {Ast.Function}
  functions: mut {integer: boolean}
end

local function survey(chunk: Ast.Chunk): Found
  local found: Found = { names = {}, types = {}, bindings = {}, members = {}, colons = {}, functions = { [chunk.id] = true } }
  local parents: mut {integer: Ast.Node} = {}
  local stack: mut {Ast.Node} = { chunk }
  while #stack > 0 do
    local node = stack[#stack]
    stack[#stack] = nil
    if (node.kind == "Name") then
      found.names[#found.names + 1] = node
    elseif (node.kind == "TypeName") then
      found.types[#found.types + 1] = node
    elseif (node.kind == "Binding") then
      local parent = parents[node.id]
      local parent_kind = if parent ~= nil then parent.kind else "" end
      if parent_kind ~= "FieldDecl" and parent_kind ~= "Method" and node.name ~= "" then
        found.bindings[#found.bindings + 1] = node
      end
    elseif (node.kind == "Function") then
      local path = node.path
      for i, name in ipairs(path) do
        if #path ~= 2 or i > 1 then
          found.members[name.id] = true
        end
      end
      if #path == 2 and chunk.tokens.text[assert(path[2]).first - 1] == ":" then
        found.colons[#found.colons + 1] = node
      end
    elseif node.kind == "Fn" or node.kind == "Method" then
      found.functions[base_of(node).id] = true
    end
    local children: mut {Ast.Node} = {}
    Ast.children(node, function(child: Ast.Node)
      children[#children + 1] = child
      parents[base_of(child).id] = node
    end)
    for i = #children, 1, -1 do
      stack[#stack + 1] = children[i]
    end
  end
  return found
end

function Cover.check(chunk: Ast.Chunk, scoped: Scopes.Scoped, declared: {string: Scopes.Global}): boolean, string
  local tokens = chunk.tokens
  local found = survey(chunk)
  local vars = scoped.vars
  local expected_vars = #found.bindings + #found.colons
  local seen_vars = 0
  for _ in pairs(vars) do
    seen_vars = seen_vars + 1
  end
  if seen_vars ~= expected_vars or #scoped.list ~= expected_vars then
    return false, "the tree has " .. tostring(expected_vars) .. " bindings and the result " .. tostring(seen_vars) .. " variables and " .. tostring(#scoped.list) .. " in its list"
  end
  for _, b in ipairs(found.bindings) do
    local v = vars[b.id]
    if v == nil or v.name ~= b.name or v.declared ~= b.first then
      return false, "the binding `" .. b.name .. "` at token " .. tostring(b.first) .. " has no variable of its name and place"
    end
  end
  local by_name: mut {string: {Scopes.Var}} = {}
  for _, v in ipairs(scoped.list) do
    if vars[v.id] ~= v then
      return false, "the variable `" .. v.name .. "` is not under its id"
    end
    if v.from > v.to or v.declared < 1 or v.declared > #tokens.kind or v.depth < 1 or found.functions[v.owner] ~= true then
      return false, "the variable `" .. v.name .. "` has a range or an owner that does not exist"
    end
    if v.assigned ~= (#v.writes > 0) then
      return false, "the variable `" .. v.name .. "` at token " .. tostring(v.declared) .. " is assigned only if it has writes"
    end
    local copies = v.copies
    if copies ~= nil and (vars[copies] == nil or vars[copies].name ~= v.name) then
      return false, "the variable `" .. v.name .. "` copies a variable of another name"
    end
    local held = by_name[v.name] or {}
    held[#held + 1] = v
    by_name[v.name] = held
  end
  -- Which variable each use is listed under, and whether it is a read.
  local listed_under: mut {integer: integer} = {}
  local is_read: mut {integer: boolean} = {}
  local listed = 0
  for _, v in ipairs(scoped.list) do
    for _, id in ipairs(v.reads) do
      listed = listed + 1
      if listed_under[id] ~= nil then
        return false, "the use " .. tostring(id) .. " is listed twice"
      end
      listed_under[id], is_read[id] = v.id, true
    end
    for _, id in ipairs(v.writes) do
      listed = listed + 1
      if listed_under[id] ~= nil then
        return false, "the use " .. tostring(id) .. " is listed twice"
      end
      listed_under[id] = v.id
    end
  end
  local resolved_count = 0
  for _, n in ipairs(found.names) do
    if found.members[n.id] ~= true then
      local at = n.first
      local best: Scopes.Var? = nil
      for _, v in ipairs(by_name[n.text] or {}) do
        if v.from <= at and at <= v.to and (best == nil or v.from > best.from or (v.from == best.from and v.declared > best.declared)) then
          best = v
        end
      end
      local id = scoped.resolved[n.id]
      local place = "the name `" .. n.text .. "` at " .. tokens.y[at] .. ":" .. tostring(Lexer.x(tokens, at))
      if best ~= nil then
        if n.binding ~= best.id or id ~= best.id then
          return false, place .. " is not bound to the variable declared at token " .. tostring(best.declared)
        end
        if listed_under[n.id] ~= best.id then
          return false, place .. " is in neither the reads nor the writes of its variable"
        end
        resolved_count = resolved_count + 1
      else
        if n.binding ~= nil or id ~= nil or scoped.globals[n.text] == nil then
          return false, place .. " is bound to no variable and is not a recorded global"
        end
      end
    elseif n.binding ~= nil or scoped.resolved[n.id] ~= nil then
      return false, "the member name `" .. n.text .. "` at token " .. tostring(n.first) .. " is bound"
    end
  end
  for _, v in ipairs(scoped.list) do
    local caught = 0
    for _, c in ipairs(v.captures) do
      if c.fn == v.owner or found.functions[c.fn] ~= true then
        return false, "`" .. v.name .. "` is captured by " .. tostring(c.fn) .. ", which is not a function inside its own"
      end
      for _, id in ipairs(c.uses) do
        caught = caught + 1
        if is_read[id] ~= true or listed_under[id] ~= v.id then
          return false, "a capture of `" .. v.name .. "` holds a use that is not a read of it"
        end
      end
    end
    if caught > #v.reads then
      return false, "`" .. v.name .. "` is captured more often than it is read"
    end
  end
  if listed ~= resolved_count then
    return false, "the variables hold " .. tostring(listed) .. " uses and " .. tostring(resolved_count) .. " names resolved"
  end
  for _, t in ipairs(found.types) do
    local head = t.path[1]
    local id = scoped.resolved[t.id]
    if id ~= nil then
      local v = vars[id]
      if v == nil or v.name ~= head then
        return false, "the type name `" .. tostring(head) .. "` at token " .. tostring(t.first) .. " resolved to a variable of another name"
      end
    end
  end
  local at = 0
  local errors = scoped.errors
  local by_offset: mut {integer: integer} = {}
  if #errors > 0 then
    for i, offset in ipairs(tokens.offset) do
      by_offset[offset] = i
    end
  end
  for _, e in ipairs(errors) do
    local t = by_offset[e.offset]
    if t == nil or e.msg == "" or e.fix == "" or tokens.y[t] ~= e.y or Lexer.x(tokens, t) ~= e.x or e.offset < at then
      return false, e.code .. " error at " .. tostring(e.y) .. ":" .. tostring(e.x) .. " has no message or fix, or is out of place or order"
    end
    at = e.offset
  end
  for name, held in pairs(scoped.globals) do
    if declared[name] == nil and Scopes.primitives[name] == nil then
      local reported = false
      for _, e in ipairs(errors) do
        reported = reported or e.code == "unknown_variable" or e.code == "unknown_type"
      end
      if not reported then
        return false, "the global `" .. name .. "` is declared nowhere and no error says so"
      end
    end
    if #held == 0 then
      return false, "the global `" .. name .. "` has no use"
    end
  end
  return true, ""
end

return Cover
