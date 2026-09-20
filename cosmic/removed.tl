--- Names cosmic's own runtime surface removes from the global
--- environment. Touching one directly raises the replacement below as
--- the error itself (`core/surface.c`'s own text, word for word) --
--- `cosmic docs os` (or any field below) answers the same thing
--- without waiting for a script to crash first.
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

local removed: Removed = {
  io = "io", os = "os", debug = "debug",
  dofile = "dofile", loadfile = "loadfile",
}

return removed
