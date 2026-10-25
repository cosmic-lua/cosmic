--- The scopes of a Teal chunk: the names each block binds and where
--- they are in scope, walked once, for [`build.analyzer`]'s references
--- through an alias and [`build.link_text`]'s names a comment sees. It
--- requires nothing of the analyzer's own, so what reaches link_text
--- (the writer's identity, [`build.work`]) does not reach the analyzer.

local ast = require("build.ast")

local record scopes
  --- A name a block binds, and the places it is in scope, from
  --- [`position`] `from` to `to`, as Lua has it: from past the statement
  --- that declares it (from its name, for a function's or a type's,
  --- which its own body sees; from itself, for a parameter or a loop's
  --- variable) to the end of the block that binds it (`math.maxinteger`
  --- for the chunk's own).
  record Binding
    name: string
    --- The module a `local name = require("m")` binds it to; "" for
    --- any other binding.
    module: string
    from: integer
    to: integer
    --- The start of the line the statement that declares it starts
    --- on, where a doc comment above that statement stands
    --- ([`in_scope`]'s `heading`); 0 for a parameter or a loop's
    --- variable.
    head: integer
    --- Whether the chunk's own block binds it.
    top: boolean
    --- Whether its declaration gives it a type of its own (`local B: T
    --- = require("m")`), which a type written `B.X` names instead of the
    --- module's.
    annotated: boolean
  end
end

--- The field that points back up the tree, never followed.
local back_up: {string: boolean} = { if_parent = true }

--- The kinds of expression that hold no node, which a walk need not
--- look inside.
local leaves: {string: boolean} = {
  variable = true, string = true, number = true, integer = true, boolean = true,
  ["nil"] = true, ["..."] = true,
}

local type Stack = {{string: string}}

local function binding(stack: Stack, name: string): string?
  for index = #stack, 1, -1 do
    local value = stack[index][name]
    if value ~= nil then
      return value ~= "" and value or nil
    end
  end
  return nil
end

--- Whether any scope binds `name`, to an import or to anything else.
local function bound(stack: Stack, name: string): boolean
  for index = #stack, 1, -1 do
    if stack[index][name] ~= nil then
      return true
    end
  end
  return false
end

--- Assignment changes the nearest lexical binding. An import binding never
--- becomes definite again through ordinary assignment: propagation through
--- arbitrary values would require checker identities, so uncertainty is
--- represented by omitting later edges.
local function invalidate(stack: Stack, name: string)
  for index = #stack, 1, -1 do
    if stack[index][name] ~= nil then
      stack[index][name] = ""
      return
    end
  end
end

--- The module `call` names when it is `require("<module>")`, a call
--- of `require` on one string literal; nil for any other expression.
local function required_name(call: ast.Node): string?
  local op = call.op
  if call.kind ~= "op" or op == nil or op.op ~= "@funcall" then
    return nil
  end
  local callee, args = call.e1, call.e2
  if callee == nil or callee.kind ~= "variable" or callee.tk ~= "require" or
      args == nil or #args ~= 1 or args[1].kind ~= "string" then
    return nil
  end
  return args[1].conststr
end

--- The module a statement binds its one name to, when it is `local
--- name = require("m")` or `local type name = require("m")`: the one
--- import form whose identity is sure. "" for any other.
local function alias_of(stmt: ast.Node): string
  local value: ast.Node? = nil
  local vars, exps = stmt.vars, stmt.exps
  if stmt.kind == "local_type" then
    value = stmt.value
  elseif vars ~= nil and #vars == 1 and exps ~= nil and #exps == 1 then
    value = exps[1]
  end
  return value ~= nil and required_name(value) or ""
end

--- A place in the source as one integer, ordered as the places are:
--- columns stay below 2^20.
function scopes.position(y: integer, x: integer): integer
  return y * 1048576 + x
end

--- Where `block`, a `statements` node, ends, as a position: its
--- terminator's (`end`, `else`, `until`), or `outer` when the parser
--- stamped none.
local function block_end(block: ast.Node?, outer: integer): integer
  local y, x = block ~= nil and block.yend or nil, block ~= nil and block.xend or nil
  if y == nil or x == nil then return outer end
  return scopes.position(y, x)
end

--- The scopes of `parsed`, walked once: every name a block binds, as
--- [`Binding`]s in the order the walk meets them, and, with `member`,
--- each `alias.member` whose `alias` still resolves to a lexical direct
--- require binding and each `require("module").member` while `require`
--- is not shadowed, handed to it with the line it is on. Parameters,
--- locals and loop variables shadow bindings; reassignment in any
--- possibly-executed branch invalidates the outer alias for `member`.
function scopes.walk(parsed: ast.Parsed,
                     member: (function(module: string, name: string, line: integer))?): {scopes.Binding}
  local out: {scopes.Binding} = {}
  local stack: Stack = { {} }
  local ends: {integer} = { math.maxinteger }
  local function open(block: ast.Node?)
    ends[#ends + 1] = block_end(block, ends[#ends])
    stack[#stack + 1] = {}
  end
  local function close()
    ends[#ends] = nil
    stack[#stack] = nil
  end
  local function declare(name: string?, module: string, from: integer, head: integer,
                         annotated?: boolean): scopes.Binding?
    if name == nil then return nil end
    stack[#stack][name] = module
    local made: scopes.Binding = { name = name, module = module, from = from, to = ends[#ends],
      head = head, top = #ends == 1, annotated = annotated == true }
    out[#out + 1] = made
    return made
  end
  --- Where a doc comment above `stmt` stands: the start of its line,
  --- whose first token the lexer hands the comments above it (the node
  --- of a `local type` sits at its name, past that token).
  local function head_of(stmt: ast.Node): integer
    return scopes.position(stmt.y, 0)
  end
  --- Where `node`, a name, starts.
  local function at(node: ast.Node): integer
    return scopes.position(node.y, node.x)
  end
  local process_block: function(ast.Node)
  local process_function: function(ast.Node)
  local walk_expression: function(ast.Node)

  walk_expression = function(n: ast.Node)
    if leaves[n.kind] then return end
    if n.kind == "function" then
      process_function(n)
      return
    end
    local receiver, field = n.e1, n.e2
    local read = field ~= nil and field.tk or nil
    local op = n.op
    if member ~= nil and n.kind == "op" and op ~= nil and op.op == "." and receiver ~= nil and
        read ~= nil then
      -- `alias.member`, or a member read straight off the module a
      -- literal `require` names: `require("build.test").run`.
      local module: string? = nil
      local alias = receiver.tk
      if receiver.kind == "variable" and alias ~= nil then
        module = binding(stack, alias)
      elseif not bound(stack, "require") then
        module = required_name(receiver)
      end
      if module ~= nil then
        member(module, read, receiver.y)
      end
    end
    ast.each_child_node(n, back_up, walk_expression)
  end

  --- A function, or a macroexp, whose body is one expression.
  process_function = function(fn: ast.Node)
    local body = fn.body
    if body ~= nil then open(body) else open(fn) end
    local args = fn.args
    if args ~= nil then
      for _, parameter in ipairs(args) do
        declare(parameter.tk, "", at(parameter), 0)
      end
    end
    local fn_body, fn_exp = fn.body, fn.exp
    if fn_body ~= nil then
      process_block(fn_body)
    elseif fn_exp ~= nil then
      walk_expression(fn_exp)
    end
    close()
  end

  process_block = function(block: ast.Node)
    -- A local's scope starts past its statement, where the next one
    -- starts, or at the end of the block for its last.
    local pending: mut {scopes.Binding} = {}
    for _, stmt in ipairs(block) do
      for _, each in ipairs(pending) do each.from = head_of(stmt) end
      pending = {}
      local if_blocks = stmt.if_blocks
      if stmt.kind == "local_declaration" then
        local exps = stmt.exps
        if exps ~= nil then
          walk_expression(exps)
        end
        local vars = stmt.vars
        if vars ~= nil then
          -- A `require` a local or a parameter shadows is no import. A
          -- `local type`'s is read by the compiler whatever is in scope.
          local module = if bound(stack, "require") then "" else alias_of(stmt) end
          local decltuple = stmt.decltuple
          local declared = decltuple ~= nil and decltuple.tuple or nil
          for index, var in ipairs(vars) do
            local made = declare(var.tk, module, math.maxinteger, head_of(stmt),
              declared ~= nil and declared[index] ~= nil)
            if made ~= nil then pending[#pending + 1] = made end
          end
        end
      elseif stmt.kind == "local_type" then
        local stmt_var = stmt.var
        declare(stmt_var ~= nil and stmt_var.tk or nil, alias_of(stmt),
          stmt_var ~= nil and at(stmt_var) or head_of(stmt), head_of(stmt))
      elseif stmt.kind == "local_function" then
        local name = stmt.name
        declare(name ~= nil and name.tk or nil, "",
          name ~= nil and at(name) or head_of(stmt), head_of(stmt))
        process_function(stmt)
      elseif stmt.kind == "local_macroexp" then
        local name = stmt.name
        declare(name ~= nil and name.tk or nil, "",
          name ~= nil and at(name) or head_of(stmt), head_of(stmt))
        local macrodef = stmt.macrodef
        if macrodef ~= nil then process_function(macrodef) end
      elseif stmt.kind == "record_function" or stmt.kind == "global_function" then
        process_function(stmt)
      elseif stmt.kind == "assignment" then
        local exps = stmt.exps
        if exps ~= nil then
          walk_expression(exps)
        end
        local stmt_vars = stmt.vars
        if stmt_vars ~= nil then
          for _, var in ipairs(stmt_vars) do
            local tk = var.tk
            if var.kind == "variable" and tk ~= nil then
              invalidate(stack, tk)
            end
          end
        end
      elseif stmt.kind == "if" and if_blocks ~= nil then
        for _, branch in ipairs(if_blocks) do
          local exp = branch.exp
          if exp ~= nil then walk_expression(exp) end
          open(branch.body)
          local body = branch.body
          if body ~= nil then process_block(body) end
          close()
        end
      elseif stmt.kind == "fornum" or stmt.kind == "forin" then
        local from = stmt.from
        if from ~= nil then walk_expression(from) end
        local to = stmt.to
        if to ~= nil then walk_expression(to) end
        local step = stmt.step
        if step ~= nil then walk_expression(step) end
        local exps = stmt.exps
        if exps ~= nil then walk_expression(exps) end
        open(stmt.body)
        local stmt_var = stmt.var
        if stmt_var ~= nil then
          declare(stmt_var.tk, "", at(stmt_var), 0)
        end
        local stmt_vars = stmt.vars
        if stmt_vars ~= nil then
          for _, var in ipairs(stmt_vars) do
            declare(var.tk, "", at(var), 0)
          end
        end
        local body = stmt.body
        if body ~= nil then process_block(body) end
        close()
      elseif stmt.kind == "repeat" then
        -- Lua keeps the repeat body's locals in scope through `until`.
        open(stmt.body)
        local body = stmt.body
        if body ~= nil then process_block(body) end
        local exp = stmt.exp
        if exp ~= nil then walk_expression(exp) end
        close()
      elseif stmt.kind == "while" or stmt.kind == "do" then
        local exp = stmt.exp
        if exp ~= nil then walk_expression(exp) end
        open(stmt.body)
        local body = stmt.body
        if body ~= nil then process_block(body) end
        close()
      else
        -- A statement that binds nothing of a scope's (a call, a
        -- `return`, a global's declaration, a `goto`): what a function
        -- among its expressions binds is still that function's.
        walk_expression(stmt)
      end
    end
    for _, each in ipairs(pending) do each.from = ends[#ends] end
  end
  process_block(parsed.node)
  return out
end

--- Every name `parsed` binds -- each local, `local function`, `local`
--- type, macroexp, parameter and loop variable, at any depth, a
--- function's in any expression of any statement -- with where its
--- scope starts and ends, in the order of one walk of its scopes. Ask
--- it once of a file and [`in_scope`] of it for each place.
function scopes.bindings_of(parsed: ast.Parsed): {scopes.Binding}
  return scopes.walk(parsed, nil)
end

--- The names `bindings` ([`bindings_of`]) holds in scope at line `y`,
--- column `x`, each with the module it is an alias of, or "": the
--- innermost binding of each, as Lua reads it there. With `heading`,
--- the place is a doc comment's above a statement starting on line
--- `y`, which sees the names that statement declares too.
function scopes.in_scope(bindings: {scopes.Binding}, y: integer, x: integer,
                         heading: boolean): {string: string}
  local at = scopes.position(y, x)
  local line = scopes.position(y, 0)
  local out: mut {string: string} = {}
  local from: mut {string: integer} = {}
  for _, each in ipairs(bindings) do
    local seen = each.from <= at or heading and each.head == line
    if seen and at <= each.to and (from[each.name] == nil or each.from >= from[each.name]) then
      out[each.name] = each.module
      from[each.name] = each.from
    end
  end
  return out
end

return scopes
