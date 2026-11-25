--- The standard globals cosmic removes (`io`, `os`, `debug`, `dofile`,
--- `loadfile`) and the fields of `package` it removes (`path`, `cpath`,
--- `loadlib`, `searchpath`), and what to write instead of each. Using
--- one is refused at compile time (`unknown variable: os`, `invalid key
--- 'path' in record 'package'`), and a program that reaches for one, a
--- `require` of a removed library included, fails at run time; both
--- errors say what to use instead, naming the replacement for the very
--- field used (`os.getenv` is [`Env.get`]). `cosmic docs os` (or any
--- field below) prints the same thing directly.
--- Help on the language's other libraries is in the checked examples
--- that ordinary documentation search returns.
local record Removed
  --- unavailable; see cosmic.fs for byte/file operations and standard-stream
  --- descriptors, cosmic.stream to read or write a file in chunks, and
  --- cosmic.child for io.popen
  io: string
  --- unavailable; see cosmic.time, cosmic.env, cosmic.proc, cosmic.fs and
  --- cosmic.child. os.date is cosmic.time's calendar, in UTC or a zone
  --- (Time.local_zone() for the host's), and there is no os.setlocale
  --- equivalent
  os: string
  --- a traceback is cosmic.errors.trace, or cosmic.errors.trace_of for
  --- a coroutine's. The debug library's hooks, registry, locals,
  --- upvalues and getinfo are unavailable
  debug: string
  --- a module comes from require, and a file's bytes come from
  --- cosmic.fs.read
  dofile: string
  --- a module comes from require, and a file's bytes come from
  --- cosmic.fs.read
  loadfile: string
end

local record Module
  --- One field per removed global, named for it: what to write instead.
  fields: Removed
  --- The removed globals, the same five `fields` names. Each fails to
  --- resolve at compile time rather than when a running program reaches
  --- for it.
  order: {string}
  --- The removed fields of `package`, the same four names the dotted
  --- `package.` entries of `replacements` have.
  package_fields: {string}
  --- What to write instead of one removed field, by its dotted name
  --- (`os.getenv`), including the `require` that brings it in.
  replacements: {string:string}
  --- Where to look for a removed name, or a field of it `replacements`
  --- has no entry for.
  names: {string:string}
  --- What to write instead of `name` (`os`), or of its field `field` (`getenv`) when one is given: one
  --- line, the text a compile error and a run-time failure both show. For a name with no entry, it
  --- says only that the name is not available, or where to look.
  message: function(name: string, field?: string): string
end

local fs <const> = 'local Fs = require("cosmic.fs")'
local stream <const> = 'local Stream = require("cosmic.stream")'
local env <const> = 'local Env = require("cosmic.env")'
local proc <const> = 'local Proc = require("cosmic.proc")'
local time <const> = 'local Time = require("cosmic.time")'
local clock <const> = 'local Clock = require("cosmic.clock")'
local child <const> = 'local Child = require("cosmic.child")'
local errors <const> = 'local Errors = require("cosmic.errors")'
local string_ <const> = 'local String = require("cosmic.string")'
local no_search_path <const> = "there is no file search path: a module comes only " ..
  "from the database, by require(name), and a file's text comes from Fs.read(path) (" ..
  fs .. ")"
local replacements: {string:string} = {
  ["package.path"] = no_search_path,
  ["package.cpath"] = no_search_path,
  ["package.loadlib"] = "a C library cannot be loaded, and a module comes only " ..
    "from the database: use require(name)",
  ["package.searchpath"] = "there is no file search path to apply a template to: " ..
    "check one file with Fs.status(path) or Fs.stat(path) (" .. fs ..
    "), find a program on PATH with Proc.find(name) (" .. proc ..
    "), and load a module with require(name), which reads the database",
  ["io.write"] = "use Fs.put(Fs.stdout, text), which answers a result to discard on purpose: " ..
    "local _, _ = Fs.put(Fs.stdout, text) (" .. fs .. ")",
  ["io.stdout"] = "use Fs.stdout, a descriptor: Fs.put(Fs.stdout, text) (" .. fs .. ")",
  ["io.stderr"] = "use Fs.stderr, a descriptor: Fs.put(Fs.stderr, text), which answers a result to discard on " ..
    'purpose: local _, _ = Fs.put(Fs.stderr, text .. "\\n") (' .. fs .. "); a program's own complaints are " ..
    "Log.new(name):complain(text) of cosmic.log, which adds the name and the newline",
  ["io.stdin"] = "use Fs.stdin, a descriptor: Fs.take(Fs.stdin, count) (" .. fs .. ")",
  ["io.read"] = "use Fs.take(Fs.stdin, count) for standard input, or " ..
    "Fs.read(path) for a whole file (" .. fs .. ")",
  ["io.open"] = "use Fs.read(path) or Fs.write(path, data) for a whole file, " ..
    "or Fs.open_read(path) or Fs.open_write(path) for a descriptor (" .. fs ..
    "); Stream.open(path) and Stream.create(path) work in chunks (" .. stream .. ")",
  ["io.lines"] = "use Fs.read(path) and String.lines(text), which keeps blank lines (" .. fs .. "; " ..
    string_ .. "), or Stream.open(path) to read in chunks (" .. stream .. ")",
  ["io.close"] = "use Fs.close(fd) (" .. fs .. ")",
  ["io.output"] = "use Fs.put(Fs.stdout, text), or Fs.put(fd, text) for a " ..
    "descriptor from Fs.open_write(path) (" .. fs .. ")",
  ["io.input"] = "use Fs.take(Fs.stdin, count), or Fs.read(path) for a " ..
    "whole file (" .. fs .. ")",
  ["io.flush"] = "Fs.put writes straight to its descriptor, so there is " ..
    "nothing to flush (" .. fs .. ")",
  ["io.tmpfile"] = "use Fs.mkdtemp(prefix) for a private directory, then " ..
    "Fs.open_write(dir .. \"/name\") (" .. fs .. ")",
  ["io.popen"] = "use Child.run(argv, { timeout_ns = limit, stdout = \"capture\" }); argv is a " ..
    "list, run without a shell or a PATH search (" .. child .. ")",
  ["io.type"] = "a descriptor is a plain integer, and nothing tells an open one " ..
    "from a closed one or from any other integer: the number Fs.close frees " ..
    "may name the next file opened, so keep track of what was closed (" ..
    fs .. ")",
  ["os.getenv"] = "use Env.get(name) (" .. env .. ")",
  ["os.exit"] = "use Proc.exit(status) (" .. proc .. ")",
  ["os.time"] = "use Clock.now_ns(), the wall clock in nanoseconds since " ..
    "the epoch (// 1000000000 for seconds), or Time.from_civil(fields, zone) " ..
    "for a calendar date, which reads it as UTC unless given a zone " ..
    "(Time.local_zone() for local time, Time.zone(\"Europe/Paris\") for " ..
    "another) and refuses a field out of range (day 32) rather than " ..
    "normalizing it (" .. clock .. "; " .. time .. ")",
  ["os.clock"] = "use Clock.monotonic_ns() to measure elapsed time; there " ..
    "is no process CPU clock (" .. clock .. ")",
  ["os.difftime"] = "subtract two Clock.now_ns() readings (" .. clock .. ")",
  ["os.date"] = "use Time.civil(Clock.now_ns(), zone) for the calendar's " ..
    "fields -- UTC's without a zone, local time with Time.local_zone(), " ..
    "or Time.zone(\"Europe/Paris\")'s -- or Time.format_rfc3339(ns, zone) " ..
    "for text; there is no strftime (" .. clock .. "; " .. time .. ")",
  ["os.remove"] = "use Fs.remove(path) (" .. fs .. ")",
  ["os.rename"] = "use Fs.rename(from, to) (" .. fs .. ")",
  ["os.tmpname"] = "use Fs.mkdtemp(prefix), which makes a private " ..
    "directory rather than naming a file (" .. fs .. ")",
  ["os.execute"] = "use Child.run(argv, { timeout_ns = limit }); argv is a list, run without a " ..
    "shell or a PATH search (" .. child .. ")",
  ["os.setlocale"] = "cosmic runs in the C locale, and there is no way to " ..
    "change it",
  ["debug.traceback"] = "use Errors.trace(message, level) for the running " ..
    "coroutine's stack, or Errors.trace_of(co, message) for another's, which " ..
    "for one that raised is where it raised (" .. errors .. ")",
  ["debug.getinfo"] = "there is no replacement: nothing answers a caller's file " ..
    "or line or a function's source as values, but Errors.trace(message, level) " ..
    "writes them into a traceback as text (" .. errors .. ")",
  ["debug.getmetatable"] = "use getmetatable(value); it answers a table's or a " ..
    "string's metatable, but its `__metatable` field in place of one that sets it, " ..
    "and there is no way past that field",
  ["debug.setmetatable"] = "use setmetatable(table, metatable); it sets a table's " ..
    "alone, refuses one whose metatable has a `__metatable` field, and there is no " ..
    "way to set the metatable of a number, function, boolean or nil value",
  ["debug.gethook"] = "there is no replacement: a program installs no hook",
  ["debug.sethook"] = "there is no replacement: a program installs no hook",
  ["debug.getlocal"] = "there is no replacement: a running function's locals " ..
    "cannot be read",
  ["debug.setlocal"] = "there is no replacement: a running function's locals " ..
    "cannot be set",
  ["debug.getupvalue"] = "there is no replacement: a function's upvalues cannot " ..
    "be read",
  ["debug.setupvalue"] = "there is no replacement: a function's upvalues cannot " ..
    "be set",
  ["debug.upvalueid"] = "there is no replacement: a function's upvalues cannot " ..
    "be told apart",
  ["debug.upvaluejoin"] = "there is no replacement: a function's upvalues cannot " ..
    "be shared with another's",
  ["debug.getregistry"] = "there is no replacement: the registry is not reachable",
  ["debug.getuservalue"] = "there is no replacement: a userdata's user values " ..
    "cannot be read",
  ["debug.setuservalue"] = "there is no replacement: a userdata's user values " ..
    "cannot be set",
  ["debug.setcstacklimit"] = "there is no replacement: the C stack limit cannot " ..
    "be changed",
  ["debug.debug"] = "there is no replacement: there is no interactive debugger",
}
local names: {string:string} = {
  io = "files are cosmic.fs, the standard streams are Fs.stdout, " ..
    "Fs.stderr and Fs.stdin, chunked reads and writes are cosmic.stream, " ..
    "and io.popen is cosmic.child",
  os = "time is cosmic.time, the environment is cosmic.env, processes " ..
    "are cosmic.proc and cosmic.child, and files are cosmic.fs",
  debug = "a traceback is Errors.trace, or Errors.trace_of for a coroutine's (" ..
    errors .. "); hooks, locals, upvalues and debug.getinfo have no replacement",
  dofile = "Teal code is loaded by require(\"dotted.name\"), and a " ..
    "file's bytes are Fs.read(path) (" .. fs .. ")",
  loadfile = "Teal code is loaded by require(\"dotted.name\"), and a " ..
    "file's bytes are Fs.read(path) (" .. fs .. ")",
}

local module: Module = {
  fields = {
    io = "io", os = "os", debug = "debug",
    dofile = "dofile", loadfile = "loadfile",
  },
  order = { "io", "os", "debug", "dofile", "loadfile" },
  package_fields = { "path", "cpath", "loadlib", "searchpath" },
  replacements = replacements,
  names = names,
  message = function(name: string, field?: string): string
    local dotted = if field ~= nil then name .. "." .. field else name end
    local instead = if field ~= nil then replacements[dotted] else nil end
    if instead ~= nil then
      return dotted .. " is not available: " .. instead
    end
    local where = names[name]
    if where == nil then
      return dotted .. " is not available"
    end
    return dotted .. " is not available: " .. where
  end,
}

return module
