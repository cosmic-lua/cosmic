--- The program's globals, for the one thing that needs them whole: the environment of a chunk built by `load`.

local record globals
  --- The table of the globals: `require` and `package` among them. A chunk that `load` builds with no environment gets
  --- neither, so a program that runs a chunk of Lua text hands it this table by name, and the code says so. Only the tool
  --- and its tests may require this module: a program outside the tree is refused its `require` ([`build.project_refusals`]),
  --- and the tree check `requirers` keeps the tree to the few files that run a program.
  table: function(): {string: any}
end

return globals
