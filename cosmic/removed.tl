--- Names cosmic's own runtime surface removes from the global
--- environment. `build.teal` strips every one of these from the
--- checker's own environment too, so touching one is refused at
--- compile time -- `unknown variable: os`, `module not found: 'io'` --
--- with a pointer at the matching field below appended to the message
--- (see `build.importer`'s `with_docs_hint`), rather than left to
--- surface only once a built program actually runs and reaches
--- `core/surface.c`'s own replacement text. `cosmic docs os` (or any
--- field below) answers the same thing directly, any time.
local record Removed
  --- files are cosmic.fs, and the standard streams are
  --- cosmic.fs.stdout, .stderr and .stdin
  io: string
  --- time is cosmic.time, the environment is cosmic.env, and
  --- processes are cosmic.proc
  os: string
  --- a traceback is cosmic.errors.trace
  debug: string
  --- a module comes from require, and a file's bytes come from
  --- cosmic.fs.read
  dofile: string
  --- a module comes from require, and a file's bytes come from
  --- cosmic.fs.read
  loadfile: string
end

local record Module
  fields: Removed
  --- The same names `build.teal` strips from the checker's own
  --- environment, so each one fails to resolve at compile time instead
  --- of at the moment a running program reaches for it -- see
  --- `build.teal`'s `environment_for`. Order does not matter to the
  --- stripping; this is the one list so it is written only once.
  order: {string}
end

local module: Module = {
  fields = {
    io = "io", os = "os", debug = "debug",
    dofile = "dofile", loadfile = "loadfile",
  },
  order = { "io", "os", "debug", "dofile", "loadfile" },
}

return module
