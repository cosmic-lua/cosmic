--- Names cosmic's own runtime surface removes from the global
--- environment, and what to write instead of each. `build.teal` strips
--- every one of these from the checker's own environment too, so
--- touching one is refused at compile time -- `unknown variable: os`,
--- `module not found: 'io'` -- and a program that reaches for one
--- anyway (a chunk handed to `load`) is stopped by `core/surface.c` at
--- run time. Both say the same thing, `message`'s own text, naming the
--- replacement for the very field used (`os.getenv` is `Env.get`), so
--- the two can never drift apart. `cosmic docs os` (or any field below)
--- answers the same thing directly, any time. `members` does the same
--- at compile time for a member a `cosmic.*` module no longer has.
--- Language-library help remains in the checked examples returned by ordinary
--- documentation search; this record inventories removed globals only.
local record Removed
  --- unavailable; see cosmic.fs for byte/file operations and standard-stream
  --- descriptors, cosmic.stream to read or write a file in chunks, and
  --- cosmic.child for io.popen
  io: string
  --- unavailable; see cosmic.time, cosmic.env, cosmic.proc, cosmic.fs and
  --- cosmic.child. There is no os.date, os.difftime or os.setlocale
  --- equivalent
  os: string
  --- a traceback is cosmic.errors.trace. The debug library and hooks,
  --- registry, locals/upvalues and debug.getinfo are unavailable
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
  --- What to write instead of one removed field, by its dotted name
  --- (`os.getenv`), including the `require` that brings it in.
  replacements: {string:string}
  --- Where to look for a removed name, or a field of it `replacements`
  --- has no entry for.
  names: {string:string}
  --- What to write instead of a member a `cosmic.*` module no longer
  --- has, by the module's name and the member's (`cosmic.hash.hex`):
  --- `build.teal` says it after the checker's `invalid key` for it, or,
  --- for a type the module no longer declares (`cosmic.zip.ZipReader`),
  --- after its `unknown type`.
  -- TODO: this is said only at compile time; a running program that
  -- reaches a removed member (a chunk handed to `load`) gets "attempt to
  -- call a nil value". Say it there too, as `core/surface.c` does for a
  -- removed global, once a module's record can answer a missing field.
  members: {string:string}
  message: function(name: string, field?: string): string
end

local fs <const> = 'local Fs = require("cosmic.fs")'
local stream <const> = 'local Stream = require("cosmic.stream")'
local env <const> = 'local Env = require("cosmic.env")'
local proc <const> = 'local Proc = require("cosmic.proc")'
local time <const> = 'local Time = require("cosmic.time")'
local child <const> = 'local Child = require("cosmic.child")'
local errors <const> = 'local Errors = require("cosmic.errors")'
local codec <const> = 'local Codec = require("cosmic.codec")'
local archive <const> = 'local Archive = require("cosmic.archive")'
local zip <const> = 'local Zip = require("cosmic.zip")'
local tar <const> = 'local Tar = require("cosmic.tar")'

local module: Module = {
  fields = {
    io = "io", os = "os", debug = "debug",
    dofile = "dofile", loadfile = "loadfile",
  },
  order = { "io", "os", "debug", "dofile", "loadfile" },
  replacements = {
    ["io.write"] = "use Fs.put(Fs.stdout, text) (" .. fs .. ")",
    ["io.stdout"] = "use Fs.stdout, a descriptor: Fs.put(Fs.stdout, text) (" .. fs .. ")",
    ["io.stderr"] = "use Fs.stderr, a descriptor: Fs.put(Fs.stderr, text) (" .. fs .. ")",
    ["io.stdin"] = "use Fs.stdin, a descriptor: Fs.take(Fs.stdin, count) (" .. fs .. ")",
    ["io.read"] = "use Fs.take(Fs.stdin, count) for standard input, or " ..
      "Fs.read(path) for a whole file (" .. fs .. ")",
    ["io.open"] = "use Fs.read(path) or Fs.write(path, data) for a whole file, " ..
      "or Fs.open_read(path) or Fs.open_write(path) for a descriptor (" .. fs ..
      "); Stream.open(path) and Stream.create(path) work in chunks (" .. stream .. ")",
    ["io.lines"] = "use Fs.read(path) and text:gmatch(\"[^\\n]+\") (" .. fs ..
      "), or Stream.open(path) to read in chunks (" .. stream .. ")",
    ["io.close"] = "use Fs.close(fd) (" .. fs .. ")",
    ["io.output"] = "use Fs.put(Fs.stdout, text), or Fs.put(fd, text) for a " ..
      "descriptor from Fs.open_write(path) (" .. fs .. ")",
    ["io.input"] = "use Fs.take(Fs.stdin, count), or Fs.read(path) for a " ..
      "whole file (" .. fs .. ")",
    ["io.flush"] = "Fs.put writes straight to its descriptor, so there is " ..
      "nothing to flush (" .. fs .. ")",
    ["io.tmpfile"] = "use Fs.mkdtemp(prefix) for a private directory, then " ..
      "Fs.open_write(dir .. \"/name\") (" .. fs .. ")",
    ["io.popen"] = "use Child.run(argv, { stdout = \"capture\" }); argv is a " ..
      "list, run without a shell or a PATH search (" .. child .. ")",
    ["os.getenv"] = "use Env.get(name) (" .. env .. ")",
    ["os.exit"] = "use Proc.exit(status) (" .. proc .. ")",
    ["os.time"] = "use Time.now_ns(), the wall clock in nanoseconds since " ..
      "the epoch (// 1000000000 for seconds) (" .. time .. ")",
    ["os.clock"] = "use Time.monotonic_ns() to measure elapsed time; there " ..
      "is no process CPU clock (" .. time .. ")",
    ["os.difftime"] = "subtract two Time.now_ns() readings (" .. time .. ")",
    ["os.date"] = "there is no calendar API yet; Time.now_ns() is the wall " ..
      "clock in nanoseconds since the epoch, but nothing formats it as a " ..
      "date (" .. time .. ")",
    ["os.remove"] = "use Fs.remove(path) (" .. fs .. ")",
    ["os.rename"] = "use Fs.rename(from, to) (" .. fs .. ")",
    ["os.tmpname"] = "use Fs.mkdtemp(prefix), which makes a private " ..
      "directory rather than naming a file (" .. fs .. ")",
    ["os.execute"] = "use Child.run(argv); argv is a list, run without a " ..
      "shell or a PATH search (" .. child .. ")",
    ["os.setlocale"] = "cosmic runs in the C locale, and there is no way to " ..
      "change it",
    ["debug.traceback"] = "use Errors.trace(message, level) (" .. errors .. ")",
  },
  names = {
    io = "files are cosmic.fs, the standard streams are Fs.stdout, " ..
      "Fs.stderr and Fs.stdin, chunked reads and writes are cosmic.stream, " ..
      "and io.popen is cosmic.child",
    os = "time is cosmic.time, the environment is cosmic.env, processes " ..
      "are cosmic.proc and cosmic.child, and files are cosmic.fs",
    debug = "a traceback is cosmic.errors.trace; hooks, locals, upvalues " ..
      "and debug.getinfo have no replacement",
    dofile = "Teal code is loaded by require(\"dotted.name\"), and a " ..
      "file's bytes are Fs.read(path) (" .. fs .. ")",
    loadfile = "Teal code is loaded by require(\"dotted.name\"), and a " ..
      "file's bytes are Fs.read(path) (" .. fs .. ")",
  },
  members = {
    ["cosmic.hash.hex"] = "use Codec.hex(digest) (" .. codec .. ")",
    ["cosmic.zip.list"] = "use Archive.list(path) (" .. archive .. "), or " ..
      "Zip.open(path) and then reader:entries() (" .. zip .. ")",
    ["cosmic.zip.ZipReader"] = "use Zip.Reader, the same record renamed (" .. zip .. ")",
    ["cosmic.zip.ZipWriter"] = "use Zip.Writer, the same record renamed (" .. zip .. ")",
    ["cosmic.tar.TarReader"] = "use Tar.Reader, the same record renamed (" .. tar .. ")",
    ["cosmic.tar.TarWriter"] = "use Tar.Writer, the same record renamed (" .. tar .. ")",
    ["cosmic.archive.ArchiveReader"] = "use Archive.Reader, the same record renamed (" ..
      archive .. ")",
  },
}

--- What to write instead of `name` (`os`), or of its field `field`
--- (`getenv`) when one is given: one line, the same for a compile
--- refused by `build.teal` and for `core/surface.c` stopping a running
--- program, which both call this.
function module.message(name: string, field?: string): string
  local dotted = field ~= nil and name .. "." .. field or name
  local instead = field ~= nil and module.replacements[dotted] or nil
  if instead ~= nil then
    return dotted .. " is not available: " .. instead
  end
  local where = module.names[name]
  if where == nil then
    return dotted .. " is not available"
  end
  return dotted .. " is not available: " .. where
end

return module
