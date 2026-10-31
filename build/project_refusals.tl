--- What a project's program may not say, because it would reach what the tool keeps from it.
---
--- A program outside cosmic's own tree (`cosmic -e`, a standalone file, a project's modules and tests) is checked by the
--- checker and run as the Lua it wrote. The tool's own modules that a project must not hold are reachable, in a checked
--- program, by four ways the types do not close: a `require` of the modules under `cosmic.internal` (the raw bindings
--- and the globals of the host), a `require` by a name or through an alias that this check cannot read, `package`
--- (the table of loaded modules and the searchers, which hand out the core's raw tables), and `load` with a mode other
--- than text, which with an environment of its own loads bytecode no checker read. So a project says none of them:
---
--- - `require` is called with one literal name, as `require("m")` or `pcall(require, "m")`, and that name is
---   not under `cosmic.internal`;
--- - `package`, `debug`, `loadfile`, `dofile`, `_G` and `_ENV` are not used (the last two hold every global under a name this check
---   cannot read: `_G.load`, `_G["load"]`, `local g = _G`);
--- - `load` is called with a mode that is the literal `"t"`, or with no mode and so no environment, and no final argument
---   that could supply them (a call or `...`: wrap a call in parentheses to pass its first value);
--- - the store module ([`cosmic.store`]) is used by its fields (`local Store = require("cosmic.store")`, then [`Store.alone`]): not
---   passed, aliased or stored, and [`Store.attach`] and [`Store.seal`] are called where they are written, never read as values.
---   `Store.attach(path, { unchecked_bytecode = true })` says the option as a literal table, and [`Store.seal`] is given no
---   options but a literal table of fields none of which is `extra`. The store loads the bytecode of a database it is
---   handed as it finds it, which nothing checks, so the gate is here: a checked program cannot attach a database of its
---   own making, or seal bytecode of its own, without this check seeing it. It is a gate on checked code and not a
---   boundary against code that is not checked, which can call the public functions itself.
---
--- `debug` is declared by lang/stdlib.d.tl, but [`build.withheld`] takes it (with `io`, `os`, `dofile` and `loadfile`) out of the
--- globals of every program, the tree's included, and the core replaces it at run time with a stand-in whose every field
--- raises (core/surface.c), so a use of it is also an undeclared name. It is refused by name too, so that it stays closed
--- should a declaration of it ever reach a project.
---
--- Cosmic's own tree is not held to this: the tool itself is made of modules that do all of these. The tree is told from a
--- project by the structure of the root ([`build.tree`]'s `standing`: a root with `core/`, `build/` and build/importer.tl is
--- the tree, the same trust root as the reservation of `cosmic.*` to it), which is how [`build.pipeline`] chooses the options of a
--- build (`project` is set for any other root, for `-e` and for a standalone file), so the check runs when the build says
--- `project` and a tree check ([`build.tree_checks`]'s `package_readers` and `text_loaders`) holds the tree itself.
---
--- This is a check of the program the checker read, not a wall: it holds a program that is checked, and a program
--- no checker read (a binary chunk) is held by the runtime alone.
---
--- TODO: close these in the core as well, so that a chunk no checker read cannot reach them, once the core carries a gate
--- on `require` and on `load` of its own (core/boot.c); this check then reports in the words of the checker what the core
--- refuses at run time.
local Ast = require("lang.ast")
local Node = require("build.syntax_node")
local Scopes = require("lang.scopes")

local record ProjectRefusals
  --- Each place in `chunk` (the parse of the file `file`, `scoped` its names resolved) that says what a project may not, as
  --- `<file>:<line>:<column>: <what>`, in source order. A name that is declared by the program itself (`local package`) is
  --- no use of the global and is not told.
  check: function(file: string, chunk: Ast.Chunk, scoped: Scopes.Scoped): {string}
  --- The same places, each as its line, column and what is told, for a caller that lays them out itself.
  places: function(chunk: Ast.Chunk, scoped: Scopes.Scoped): {ProjectRefusals.Place}
  record Place
    y: integer
    x: integer
    text: string
  end
end

--- The prefix of the modules a project may not require: the tool's own, which are not its interface.
local INTERNAL <const> = "cosmic.internal"

--- The module whose loader reads bytecode no checker read, and the fields of it that reach that loader.
local STORE <const> = "cosmic.store"
local GATED: {string: boolean} = { attach = true, seal = true }

--- The globals that are refused whole, with what is told of them.
local whole: {string: string} = {
  package = "`package` holds the loaded modules and the searchers that hand out the core's raw tables: require a module " ..
    "by a literal name instead",
  _G = "`_G` is the table of the globals, which holds `load`, `require` and `package` under any name: use the globals by their names",
  _ENV = "`_ENV` is the table of the globals, which holds `load`, `require` and `package` under any name: use the globals by their names",
  debug = "`debug` reads the registry, the upvalues and the metatables of the core's own functions, which hand out what the " ..
    "types keep from a project: use the library's modules instead",
  loadfile = "`loadfile` reads a chunk no checker read: require a module by a literal name instead",
  dofile = "`dofile` runs a chunk no checker read: require a module by a literal name instead",
}

--- Whether `name` is a module under `cosmic.internal`, however its dots are written.
local function internal(name: string): boolean
  local dotted = (name:gsub("[/\\]", "."))
  return dotted == INTERNAL or dotted:sub(1, #INTERNAL + 1) == INTERNAL .. "."
end

--- Whether `exp` is a string naming the store module, however its dots are written.
local function names_store(exp: Ast.Exp?): boolean
  return exp ~= nil and exp.kind == "String" and (exp.value:gsub("[/\\]", ".")) == STORE
end

--- Whether `table` is a literal table of named fields, as `attach` is given its option.
local function flagged(table_exp: Ast.Exp?): boolean
  if table_exp == nil or table_exp.kind ~= "Table" then
    return false
  end
  local found = false
  for _, item in ipairs(table_exp.items) do
    if item.kind ~= "Named" then
      return false
    end
    if item.name == "unchecked_bytecode" and item.value.kind == "Boolean" and item.value.value then
      found = true
    end
  end
  return found
end

--- Whether `exp` is a literal table of named fields none of which is `extra`, as `seal` is given its options.
local function without_extra(exp: Ast.Exp?): boolean
  if exp == nil or exp.kind ~= "Table" then
    return false
  end
  for _, item in ipairs(exp.items) do
    if item.kind ~= "Named" or item.name == "extra" then
      return false
    end
  end
  return true
end

--- Tells each use of the store module that reaches its loader other than by its fields, and each call of `attach` and `seal`
--- that does not say what it takes. `watched` is the ids of the names of the watched globals.
local function store_uses(chunk: Ast.Chunk, scoped: Scopes.Scoped, watched: {integer: string}, say: function(Ast.Node, string))
  local function is_global(callee: Ast.Exp, name: string): boolean
    return callee.kind == "Name" and watched[callee.id] == name
  end
  --- How many results precede the store module among the values of `exp`: 0 for `require("cosmic.store")`, 1 for
  --- `pcall(require, "cosmic.store")`, nil for any other.
  local function yields(exp: Ast.Exp): integer?
    if exp.kind ~= "Call" then
      return nil
    end
    if is_global(exp.callee, "require") and #exp.args == 1 and names_store(exp.args[1]) then
      return 0
    end
    local first = exp.args[1]
    if is_global(exp.callee, "pcall") and #exp.args == 2 and first ~= nil and is_global(first, "require") and
        names_store(exp.args[2]) then
      return 1
    end
    return nil
  end
  -- The locals that hold the module, and the calls that give it to one.
  local holders: mut {integer: boolean} = {}
  local bound: mut {integer: boolean} = {}
  local any = false
  Node.walk(chunk, function(node: Ast.Node)
    if node.kind == "Local" then
      for at, value in ipairs(node.values) do
        local before = yields(value)
        if before ~= nil then
          local binding: Ast.Binding? = node.bindings[at]
          if before == 1 then
            binding = nil
            if at == #node.values then
              binding = node.bindings[at + 1]
            end
          end
          if binding ~= nil then
            holders[binding.id] = true
            any = true
          end
          bound[value.id] = true
        end
      end
    end
  end)
  if not any and next(bound) == nil then
    -- no local holds it; a call of it still may be written inline
    local inline = false
    Node.walk(chunk, function(node: Ast.Node)
      if node.kind == "Call" and yields(node) ~= nil then
        inline = true
      end
    end)
    if not inline then
      return
    end
  end
  local parents = Node.parents(chunk)
  local function by_value(node: Ast.Node)
    say(node, "the store module is used as a value, which may reach `" .. STORE .. "`'s `attach` and `seal` by a name this " ..
        "check cannot read: use it by its fields (`Store.alone(...)`), and `attach` and `seal` as calls where they are written")
  end
  --- The call of the gated field `name` written at `field`, which must be the callee of a call that says what it takes.
  local function gated(field: Ast.Node, name: string)
    local call = parents[Node.base(field).id]
    if call == nil or call.kind ~= "Call" or call.callee ~= field then
      say(field, "`" .. STORE .. "`'s `" .. name .. "` is used as a value, which loads bytecode no checker read by a name " ..
          "this check cannot read: call it where it is written")
    elseif name == "attach" then
      if #call.args ~= 2 or not flagged(call.args[2]) then
        say(call, "`attach` loads the bytecode of a database as it finds it, which nothing checks: a project does not " ..
            "attach one, or says so as `attach(path, { unchecked_bytecode = true })` with the option as a literal table")
      end
    else
      local count = #call.args
      local last = call.args[count]
      local opts = call.args[3]
      if (opts ~= nil and not without_extra(opts)) or
          (count < 3 and last ~= nil and (last.kind == "Call" or last.kind == "MethodCall" or last.kind == "Vararg")) then
        say(call, "`seal` carries bytecode no checker read when it is given an `extra`: a project gives it its options as a " ..
            "literal table of fields none of which is `extra`")
      end
    end
  end
  --- The store module is written at `node`: only its fields are used.
  local function judge(node: Ast.Node)
    local parent = parents[Node.base(node).id]
    if parent ~= nil then
      if parent.kind == "Field" and parent.object == node then
        if GATED[parent.name] == true then
          gated(parent, parent.name)
        end
        return
      elseif parent.kind == "Index" and parent.object == node then
        local key = parent.key
        if key.kind ~= "String" then
          by_value(parent)
        elseif GATED[key.value] == true then
          gated(parent, key.value)
        end
        return
      elseif parent.kind == "MethodCall" and parent.object == node then
        if GATED[parent.name] == true then
          by_value(node)
        end
        return
      end
    end
    by_value(node)
  end
  Node.walk(chunk, function(node: Ast.Node)
    if node.kind == "Call" then
      if yields(node) ~= nil and bound[node.id] ~= true then
        judge(node)
      end
    elseif node.kind == "Name" then
      local var = scoped.resolved[node.id]
      if var ~= nil and holders[var] == true then
        judge(node)
      end
    end
  end)
end

function ProjectRefusals.places(chunk: Ast.Chunk, scoped: Scopes.Scoped): {ProjectRefusals.Place}
  local watched: mut {integer: string} = {}
  local any = false
  for _, name in ipairs({ "package", "debug", "loadfile", "dofile", "_G", "_ENV", "require", "load", "pcall" }) do
    for _, id in ipairs(scoped.globals[name] or {}) do
      watched[id] = name
      any = true
    end
  end
  if not any then
    return {}
  end
  local out: mut {ProjectRefusals.Place} = {}
  local spoken: mut {integer: boolean} = {}
  local function say(node: Ast.Node, text: string)
    local at = Node.span(chunk, node)
    table.insert(out, { y = at.y, x = at.x, text = text })
  end
  --- `callee` is the global `name` and so is called here: the use is judged by the call, not as a name.
  local function is_global(callee: Ast.Exp, name: string): boolean
    return callee.kind == "Name" and watched[callee.id] == name
  end
  --- A `require` named by `literal`, called at `node`.
  local function required(node: Ast.Node, literal: Ast.Exp?)
    if literal == nil or literal.kind ~= "String" then
      say(node, "`require` takes one literal module name here: a name that is computed is a module the build cannot see")
    elseif internal(literal.value) then
      say(node, "`" .. literal.value .. "` is not a module a project may require: " .. INTERNAL ..
          " holds the tool's own, which are not its interface")
    end
  end
  Node.walk(chunk, function(node: Ast.Node)
    if node.kind == "Call" then
      local callee = node.callee
      if is_global(callee, "require") then
        spoken[callee.id] = true
        if #node.args ~= 1 then
          say(node, "`require` takes one literal module name here")
        else
          required(node, node.args[1])
        end
      elseif is_global(callee, "pcall") then
        local first = node.args[1]
        if first ~= nil and is_global(first, "require") then
          spoken[first.id] = true
          if #node.args ~= 2 then
            say(node, "`pcall(require, ...)` takes one literal module name here")
          else
            required(node, node.args[2])
          end
        end
      elseif is_global(callee, "load") then
        spoken[callee.id] = true
        local count = #node.args
        local mode = node.args[3]
        local last = node.args[count]
        if count >= 3 and not (mode ~= nil and mode.kind == "String" and mode.value == "t") then
          say(node, "`load` takes the mode `\"t\"` here, as a literal: a chunk of bytecode no checker read is not one a project loads")
        elseif count < 3 and last ~= nil and (last.kind == "Call" or last.kind == "MethodCall" or last.kind == "Vararg") then
          say(node, "`load` is given a last argument that may supply a mode and an environment: wrap a call in parentheses " ..
              "(`load((f()))`) to pass its first value alone")
        end
      end
    elseif node.kind == "Name" then
      local name = watched[node.id]
      if name ~= nil and spoken[node.id] ~= true then
        local why = whole[name]
        if why ~= nil then
          say(node, why)
        elseif name == "require" or name == "load" then
          say(node, "`" .. name .. "` is used as a value, which may call it by a name this check cannot read: call it " ..
              "directly (`require` as `require(\"m\")` or `pcall(require, \"m\")`)")
        end
      end
    end
  end)
  store_uses(chunk, scoped, watched, say)
  return out
end

function ProjectRefusals.check(file: string, chunk: Ast.Chunk, scoped: Scopes.Scoped): {string}
  local out: mut {string} = {}
  for _, at in ipairs(ProjectRefusals.places(chunk, scoped)) do
    out[#out + 1] = file .. ":" .. tostring(at.y) .. ":" .. tostring(at.x) .. ": " .. at.text
  end
  return out
end

return ProjectRefusals
