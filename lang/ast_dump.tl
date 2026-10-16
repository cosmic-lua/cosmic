--- A tree as text, one S-expression: the form tests assert and a person
--- reads. `(Binary "+" (Name "a") (Integer 1))` is `a + 1`.
---
--- A node is its kind and then its fields in the order [`lang.ast`]'s
--- `fields` lists them. A string is quoted, a number written as it is, a
--- list is `[a b]` (a list of lists `[[a b] [c]]`) and a `true` is written as
--- the field's name (`mut`), except in a `value`, which is `true` or `false`.
--- A field that is nil, false or an empty list is `_`, and the `_`s that end
--- a node are left out.
local Ast = require("lang.ast")

local record Dump
  --- `node` as one line.
  dump: function(node: Ast.Node): string
  --- A list of nodes (a block's statements, say) as one line.
  list: function(nodes: {Ast.Node}): string
end

local function quoted(text: string): string
  return (string.format("%q", text):gsub("\\\n", "\\n"))
end

local write: function(value: any, name: string, out: {string})

--- Whether `field` is an empty list, which writes as `_` like a field that is not there.
local function is_blank(field: any, name: string): boolean
  if field == nil or (field == false and name ~= "value") then
    return true
  end
  return field is {string: any} and field.kind == nil and next(field) == nil
end

local function write_list(list: any, name: string, out: {string})
  out[#out + 1] = "["
  if list is {any} then
    for i, item in ipairs(list) do
      if i > 1 then out[#out + 1] = " " end
      write(item, name, out)
    end
  end
  out[#out + 1] = "]"
end

local function write_node(node: {string: any}, kind: string, out: {string})
  out[#out + 1] = "(" .. kind
  local names = Ast.fields[kind]
  local used = #out
  for i = 1, #names do
    local field = node[names[i]]
    out[#out + 1] = " "
    if is_blank(field, names[i]) then
      out[#out + 1] = "_"
    else
      write(field, names[i], out)
      used = #out
    end
  end
  for i = #out, used + 1, -1 do
    out[i] = nil
  end
  out[#out + 1] = ")"
end

write = function(value: any, name: string, out: {string})
  if value is string then
    out[#out + 1] = quoted(value)
  elseif value is boolean then
    out[#out + 1] = name == "value" and tostring(value) or name
  elseif value is number then
    out[#out + 1] = tostring(value)
  elseif value is {string: any} then
    local kind = value.kind
    if kind is string then
      write_node(value, kind, out)
    else
      write_list(value, name, out)
    end
  end
end

function Dump.dump(node: Ast.Node): string
  local out: {string} = {}
  write(node, "", out)
  return table.concat(out)
end

function Dump.list(nodes: {Ast.Node}): string
  local out: {string} = {}
  write(nodes, "", out)
  return table.concat(out)
end

return Dump
