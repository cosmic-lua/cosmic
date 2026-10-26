--- Loads a module by a name the program gets at run time: the module it is asked to run, which no file of the program
--- names.
---
--- The build follows a `require` by a literal name alone and refuses one by a computed name (`computed_require`), so a
--- module loaded here is no edge: it is not carried into a built program, held in a test's closure or covered by a key.
--- The caller makes it available by another route (the store the tool runs on, the closure a worker is given). The tree
--- check `requirers` refuses a `require` of this module from any module but the tool's entry ([`build.dispatch`]) and
--- the test worker ([`build.test_worker`]), so no alias of it elsewhere matters; any other module requires what it needs
--- by a literal name, or picks from a table of such requires.
local Globals = require("cosmic.internal.globals")

local record LoadModule
  --- What `require` answers for `name`, raising as it does, so a worker that holds `require` to a closure holds this to
  --- it.
  load: function(name: string): any
end

function LoadModule.load(name: string): any
  local chunk = assert(load("return require((...))", "=load_module", "t", Globals.table()))
  local value: any = chunk(name)
  return value
end

return LoadModule
