--- What a source declares each type to have, read off its syntax tree: the rows of `members` ([`build.work`]), which
--- `cosmic lsp`'s completion offers the members of another module from ([`build.lsp.completion`]) in place of the checker's
--- declarations of the module's stub.
---
--- A row is one member of a type, or the type itself (`name` ""), under `owner`, the dotted symbol of the type from the top
--- of the module as [`build.syntax_places`] spells it (`R`, `R.Inner`). The tree has no resolved types, so a member's
--- `type` is its type as written, on one line, with its comments left out: a function's is `function(` its parameters
--- `)` and `: ` its returns as written, and a method's parameters begin with its `self`. A type the text names ([`Ast.Node`])
--- is not looked up.
---
--- The `scope` says where the member is offered, as the checker finds a member read: "instance" of a value of the type,
--- "value" of the type used as a value (the table of its functions), "both". A class's fields and a record's function
--- fields that take a value of the record first, when no `function R.m` or `R.m = ` statement of the module gives the
--- table of its functions that name, belong to the instance alone; so does a class's `function R.f`, once more as a method
--- of its values when the class takes no type parameters, as the metatable of its values is.
local Ast = require("lang.ast")
local Lexer = require("lang.lexer")

local record Members
  --- One member of a type, or the type (`name` ""). The `kind` of a type is "record", "class", "interface" or "enum" and its
  --- `type` the interfaces it lists, joined by ", ". The `kind` of a member is "field", "method" (declared in a class),
  --- "function" (a `function R.f` statement of the module, which adds to `R`) or "value" (an enum's, with no `type`).
  record Found
    owner: string
    name: string
    kind: string
    scope: string
    type: string
  end

  --- Every type `chunk` declares, at its top level and in its `do` blocks, and the nested types, with their members. The
  --- functions `function R.f` add to a type last, so that a field or method of the same name stands before them.
  found: function(chunk: Ast.Chunk): {Found}
end

--- What a type declaration holds that its members are made of.
local record Declared
  name: Ast.Binding
  kind: string
  supers: {Ast.TypeName}
  members: {Ast.Member}
  values: {Ast.EnumValue}
  arity: integer
end

--- What the node `n` declares if it declares a record, class, interface or enum, nil for anything else.
local function declared(n: Ast.Node): Declared?
  if n.kind == "Record" then
    return { name = n.name, kind = "record", supers = n.supers, members = n.members, values = {}, arity = #n.typeparams }
  elseif n.kind == "Interface" then
    return { name = n.name, kind = "interface", supers = n.supers, members = n.members, values = {}, arity = #n.typeparams }
  elseif n.kind == "Class" then
    return { name = n.name, kind = "class", supers = n.supers, members = n.members, values = {}, arity = #n.typeparams }
  elseif n.kind == "Enum" then
    return { name = n.name, kind = "enum", supers = {}, members = {}, values = n.values, arity = 0 }
  end
  return nil
end

function Members.found(chunk: Ast.Chunk): {Members.Found}
  local tokens = chunk.tokens
  local out: mut {Members.Found} = {}

  --- The tokens `first` to `last` as one line: the spaces the text had between two of them are one space, and none where
  --- it had none.
  local function spell(first: integer, last: integer): string
    local parts: mut {string} = {}
    local stopped: integer? = nil
    for at = first, last do
      local gap = stopped
      if gap ~= nil and Lexer.offset(tokens, at) > gap then parts[#parts + 1] = " " end
      parts[#parts + 1] = Lexer.text(tokens, at)
      stopped = Lexer.stop(tokens, at)
    end
    return table.concat(parts)
  end

  --- A function's type: its parameters and the returns it lists, as written.
  local function function_type(params: {Ast.Param}, rets: Ast.Rets?): string
    local first, last = params[1], params[#params]
    local head = "function(" .. (if first ~= nil and last ~= nil then spell(first.first, last.last) else "" end) .. ")"
    if rets ~= nil then return head .. ": " .. spell(rets.first, rets.last) end
    return head
  end

  --- The names the statements at the top of the module give the table of a type's functions: `function R.m` and `R.m = `,
  --- by the type's name.
  local given: mut {string: mut {string: boolean}} = {}
  --- The top-level types by name, and the `function R.f` statements to add to them.
  local tops: mut {string: Declared} = {}
  for _, stat in ipairs(chunk.body.stats) do
    local held = declared(stat)
    if held ~= nil then tops[held.name.name] = held end
    local head: string? = nil
    local member: string? = nil
    if stat.kind == "Function" and #stat.path == 2 then
      head, member = stat.path[1].text, stat.path[2].text
    elseif stat.kind == "Assign" and #stat.targets == 1 then
      local target = stat.targets[1]
      if target.kind == "Field" and target.object.kind == "Name" then
        head, member = target.object.text, target.name
      end
    end
    if head ~= nil and member ~= nil then
      local names = given[head] or {}
      given[head] = names
      names[member] = true
    end
  end

  --- Whether the field of the record `held` at `symbol` is one every value holds: a function that takes a value of the
  --- record first, which the module's table of functions does not give.
  local function held_by_values(held: Declared, symbol: string, member: Ast.FieldDecl): boolean
    local t = member.type
    if held.kind ~= "record" or t.kind ~= "TypeFunction" then return false end
    local receiver = t.params[1]
    if receiver == nil or receiver.type.kind ~= "TypeName" then return false end
    local path = table.concat(receiver.type.path, ".")
    if path ~= symbol and path ~= held.name.name then return false end
    -- Only the module's own statements about a type declared at its top level are known.
    local names = given[held.name.name]
    if symbol ~= held.name.name or names == nil then return true end
    return names[member.name.name] ~= true
  end

  --- Adds a row.
  local function add(owner: string, name: string, kind: string, scope: string, text: string)
    out[#out + 1] = { owner = owner, name = name, kind = kind, scope = scope, type = text }
  end

  --- Adds the type `held` is at `symbol`, its members and the types nested in it.
  local function add_type(held: Declared, symbol: string)
    local supers: mut {string} = {}
    for _, super in ipairs(held.supers) do supers[#supers + 1] = spell(super.first, super.last) end
    add(symbol, "", held.kind, "both", table.concat(supers, ", "))
    for _, member in ipairs(held.members) do
      if member.kind == "FieldDecl" then
        local scope = "both"
        if held.kind == "class" or held_by_values(held, symbol, member) then scope = "instance" end
        add(symbol, member.name.name, "field", scope, spell(member.type.first, member.type.last))
      elseif member.kind == "Method" then
        add(symbol, member.name.name, "method", "both", function_type(member.params, member.rets))
      else
        local nested = declared(member)
        if nested ~= nil then add_type(nested, symbol .. "." .. nested.name.name) end
      end
    end
    for _, value in ipairs(held.values) do add(symbol, value.value, "value", "value", "") end
  end

  --- Adds the types of `stats`, and of the `do` blocks in them.
  local function add_types(stats: {Ast.Stat})
    for _, stat in ipairs(stats) do
      if stat.kind == "Do" then
        add_types(stat.body.stats)
      else
        local held = declared(stat)
        if held ~= nil then add_type(held, held.name.name) end
      end
    end
  end
  add_types(chunk.body.stats)

  for _, stat in ipairs(chunk.body.stats) do
    if stat.kind == "Function" and #stat.path == 2 then
      local object, name = stat.path[1], stat.path[2]
      local held = tops[object.text]
      if held ~= nil and (held.kind == "record" or held.kind == "class") then
        local text = function_type(stat.fn.params, stat.fn.rets)
        add(object.text, name.text, "function", "value", text)
        if held.kind == "class" and held.arity == 0 then
          add(object.text, name.text, "method", "instance", text)
        end
      end
    end
  end
  return out
end

return Members
