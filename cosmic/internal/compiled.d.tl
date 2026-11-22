--- The loader of the Lua the compiler writes, the one loader that reads the class forms of patch/lua/: `{ ... } @ C`,
--- a table with the class `C` as its metatable, and `@v`, the metatable of `v` whatever its `__metatable` says. The
--- global `load` refuses the mode that reads them, so a chunk of text a program loads cannot spell either. Only the
--- modules that load what the compiler wrote may require this one (the tree check `requirers`), and a program outside
--- the tree is refused its `require` ([`build.project_refusals`]).
--- @kind binding

local record compiled
  --- The chunk `text` holds, named `name` (as `load`'s second argument) and with `env` as its environment, or nil and
  --- Lua's message where it does not load. Text alone: a binary chunk is refused.
  load: function(text: string, name: string, env: {string: any}): ((function(...: any): any...)?, string?)
  load: function<V>(text: string, name: string, env: {string: V}): ((function(...: any): any...)?, string?)
end

return compiled
