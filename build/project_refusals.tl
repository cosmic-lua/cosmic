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
---   that could supply them (a call or `...`: wrap a call in parentheses to pass its first value).
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
