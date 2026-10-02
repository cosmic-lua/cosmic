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

local type Stack = {{string: string}}

local function binding(stack: Stack, name: string): string | nil
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
local function required_name(call: ast.Node): string | nil
  if call.kind ~= "op" or call.op == nil or call.op.op ~= "@funcall" then
    return nil
  end
  local callee, args = call.e1, call.e2
  if callee == nil or callee.kind ~= "variable" or callee.tk ~= "require"
     or args == nil or #args ~= 1 or args[1].kind ~= "string" then
    return nil
  end
  return args[1].conststr
end

--- The module a statement binds its one name to, when it is `local
--- name = require("m")` or `local type name = require("m")`: the one
--- import form whose identity is sure. "" for any other.
local function alias_of(stmt: ast.Node): string
  local value: ast.Node | nil = nil
  if stmt.kind == "local_type" then
    value = stmt.value
  elseif stmt.vars ~= nil and #stmt.vars == 1 and stmt.exps ~= nil and #stmt.exps == 1 then
    value = stmt.exps[1]
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
local function block_end(block: ast.Node | nil, outer: integer): integer
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
                     member: function(module: string, name: string, line: integer) | nil): {scopes.Binding}
  local out: {scopes.Binding} = {}
  local stack: Stack = { {} }
  local ends: {integer} = { math.maxinteger }
  local function open(block: ast.Node | nil)
    ends[#ends + 1] = block_end(block, ends[#ends])
    stack[#stack + 1] = {}
  end
  local function close()
    ends[#ends] = nil
    stack[#stack] = nil
  end
  local function declare(name: string | nil, module: string, from: integer, head: integer,
                         annotated?: boolean): scopes.Binding | nil
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
    if n.kind == "function" then
      process_function(n)
      return
    end
    if member ~= nil and n.kind == "op" and n.op ~= nil and n.op.op == "." and n.e1 ~= nil
       and n.e2 ~= nil and n.e2.tk ~= nil then
      -- `alias.member`, or a member read straight off the module a
      -- literal `require` names: `require("build.test").run`.
      local module: string | nil = nil
      if n.e1.kind == "variable" and n.e1.tk ~= nil then
        module = binding(stack, n.e1.tk)
      elseif not bound(stack, "require") then
        module = required_name(n.e1)
      end
      if module ~= nil then
        member(module, n.e2.tk, n.e1.y)
      end
    end
    for _, child in ipairs(ast.children(n, back_up)) do
      walk_expression(child)
    end
  end

  --- A function, or a macroexp, whose body is one expression.
  process_function = function(fn: ast.Node)
    if fn.body ~= nil then open(fn.body) else open(fn) end
    if fn.args ~= nil then
      for _, parameter in ipairs(fn.args) do
        declare(parameter.tk, "", at(parameter), 0)
      end
    end
    if fn.body ~= nil then
      process_block(fn.body)
    elseif fn.exp ~= nil then
      walk_expression(fn.exp)
    end
    close()
  end

  process_block = function(block: ast.Node)
    -- A local's scope starts past its statement, where the next one
    -- starts, or at the end of the block for its last.
    local pending: {scopes.Binding} = {}
    for _, stmt in ipairs(block) do
      for _, each in ipairs(pending) do each.from = head_of(stmt) end
      pending = {}
      if stmt.kind == "local_declaration" then
        if stmt.exps ~= nil then
          walk_expression(stmt.exps)
        end
        if stmt.vars ~= nil then
          -- A `require` a local or a parameter shadows is no import. A
          -- `local type`'s is read by the compiler whatever is in scope.
          local module = bound(stack, "require") and "" or alias_of(stmt)
          local declared = stmt.decltuple ~= nil and stmt.decltuple.tuple or nil
          for index, var in ipairs(stmt.vars) do
            local made = declare(var.tk, module, math.maxinteger, head_of(stmt),
              declared ~= nil and declared[index] ~= nil)
            if made ~= nil then pending[#pending + 1] = made end
          end
        end
      elseif stmt.kind == "local_type" then
        declare(stmt.var ~= nil and stmt.var.tk or nil, alias_of(stmt),
          stmt.var ~= nil and at(stmt.var) or head_of(stmt), head_of(stmt))
      elseif stmt.kind == "local_function" then
        declare(stmt.name ~= nil and stmt.name.tk or nil, "",
          stmt.name ~= nil and at(stmt.name) or head_of(stmt), head_of(stmt))
        process_function(stmt)
      elseif stmt.kind == "local_macroexp" then
        declare(stmt.name ~= nil and stmt.name.tk or nil, "",
          stmt.name ~= nil and at(stmt.name) or head_of(stmt), head_of(stmt))
        if stmt.macrodef ~= nil then process_function(stmt.macrodef) end
      elseif stmt.kind == "record_function" or stmt.kind == "global_function" then
        process_function(stmt)
      elseif stmt.kind == "assignment" then
        if stmt.exps ~= nil then
          walk_expression(stmt.exps)
        end
        if stmt.vars ~= nil then
          for _, var in ipairs(stmt.vars) do
            if var.kind == "variable" and var.tk ~= nil then
              invalidate(stack, var.tk)
            end
          end
        end
      elseif stmt.kind == "if" and stmt.if_blocks ~= nil then
        for _, branch in ipairs(stmt.if_blocks) do
          if branch.exp ~= nil then walk_expression(branch.exp) end
          open(branch.body)
          if branch.body ~= nil then process_block(branch.body) end
          close()
        end
      elseif stmt.kind == "fornum" or stmt.kind == "forin" then
        if stmt.from ~= nil then walk_expression(stmt.from) end
        if stmt.to ~= nil then walk_expression(stmt.to) end
        if stmt.step ~= nil then walk_expression(stmt.step) end
        if stmt.exps ~= nil then walk_expression(stmt.exps) end
        open(stmt.body)
        if stmt.var ~= nil then
          declare(stmt.var.tk, "", at(stmt.var), 0)
        end
        if stmt.vars ~= nil then
          for _, var in ipairs(stmt.vars) do
            declare(var.tk, "", at(var), 0)
          end
        end
        if stmt.body ~= nil then process_block(stmt.body) end
        close()
      elseif stmt.kind == "repeat" then
        -- Lua keeps the repeat body's locals in scope through `until`.
        open(stmt.body)
        if stmt.body ~= nil then process_block(stmt.body) end
        if stmt.exp ~= nil then walk_expression(stmt.exp) end
        close()
      elseif stmt.kind == "while" or stmt.kind == "do" then
        if stmt.exp ~= nil then walk_expression(stmt.exp) end
        open(stmt.body)
        if stmt.body ~= nil then process_block(stmt.body) end
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
  local out: {string: string} = {}
  local from: {string: integer} = {}
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
