--- The locals a module's main chunk holds, which [`build.tree_checks`]'s `main_locals` keeps under its limit. Lua gives a
--- function 200 local variables, and the main chunk of a module is one: a file at the limit builds alone and fails
--- once two changes that each add a top-level local are merged. So the check refuses a file well short of it.
---
--- Read off the tree of the new checker ([`lang.ast`]), the statements that stand directly in the chunk and take a
--- register in the Lua written for it: each name of a `local` statement, except a `<const>` bound to a literal, which
--- Lua folds into its uses; each `local function`; and each `local record` or `local class` that has a
--- `function Name.member` at the top level, which becomes a table. A `local type`, an enum, and a record with no such
--- function are types, and write no local.
local Ast = require("lang.ast")

local record MainLocals
  --- The count of main-chunk locals in the chunk `chunk` ([`build.syntax_node.parse`]).
  of_chunk: function(chunk: Ast.Chunk): integer
end

--- Whether `exp` is a literal Lua folds into the uses of a `<const>` bound to it.
local function folded(exp: Ast.Exp): boolean
  local kind = exp.kind
  return kind == "Integer" or kind == "Float" or kind == "String" or kind == "Boolean" or kind == "Nil"
end

--- The names `stat` binds in a register, if it is a `local` statement.
local function bound(stat: Ast.Local): integer
  local count = 0
  for index, binding in ipairs(stat.bindings) do
    local value = stat.values[index]
    if not (binding.attr == "const" and value ~= nil and folded(value)) then
      count = count + 1
    end
  end
  return count
end

function MainLocals.of_chunk(chunk: Ast.Chunk): integer
  local count = 0
  local tabled: mut {string: boolean} = {}
  for _, top in ipairs(chunk.body.stats) do
    if top.kind == "Function" then
      local root = top.path[1]
      if root ~= nil then
        tabled[root.text] = true
      end
    end
  end
  for _, top in ipairs(chunk.body.stats) do
    if top.kind == "Local" and top.scope == "local" then
      count = count + bound(top)
    elseif top.kind == "LocalFunction" then
      count = count + 1
    elseif (top.kind == "Record" or top.kind == "Class") and top.scope == "local" and tabled[top.name.name] == true then
      count = count + 1
    end
  end
  return count
end

return MainLocals
