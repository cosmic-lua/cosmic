--- The standard globals cosmic removes (`io`, `os`, `debug`, `dofile`,
--- `loadfile`) and what to write instead of each. Using one is refused
--- at compile time (`unknown variable: os`), and a chunk handed to
--- `load` that reaches for one fails at run time; both errors say
--- what to use instead, naming the replacement for the very field used
--- (`os.getenv` is [`Env.get`]). `cosmic docs os` (or any field below)
--- answers the same thing directly. `members` does the same at compile
--- time for a member a `cosmic.*` module no longer has. Help on the
--- language's other libraries is in the checked examples that ordinary
--- documentation search returns.
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
  --- One field per removed global, named for it: what to write instead.
  fields: Removed
  --- The removed globals, the same five `fields` names. Each fails to
  --- resolve at compile time rather than when a running program reaches
  --- for it.
  order: {string}
  --- What to write instead of one removed field, by its dotted name
  --- (`os.getenv`), including the `require` that brings it in.
  replacements: {string:string}
  --- Where to look for a removed name, or a field of it `replacements`
  --- has no entry for.
  names: {string:string}
  -- TODO: a field removed from a record a caller builds as a table
  -- literal (cosmic.archive's ExtractOptions.strip, replaced by
  -- strip_prefix and strip_components) has no entry: the checker says only `unknown
  -- field strip`, without the record it was checked against, so
  -- [`build.teal`]'s `replacement` cannot look one up. Key entries by
  -- record (`cosmic.archive.ExtractOptions.strip`) once that message
  -- names its record. The same holds for the fields `cosmic.json`'s
  -- EncodeOptions lost: `sorted` (keys are always in byte order),
  -- `indent` (`pretty` indents two spaces), `ascii` (no replacement),
  -- `nan_as_null` (write Json.null for the number) and `sparse_as_null`
  -- (put Json.null where the hole is, as decode's `null_value` does).
  -- TODO: this is said only at compile time; a running program that
  -- reaches a removed member (a chunk handed to `load`) gets "attempt to
  -- call a nil value". Say it there too, as [`core/surface.c`] does for a
  -- removed global, once a module's record can answer a missing field.

  --- What to write instead of a member a `cosmic.*` module no longer
  --- has, by the module's name and the member's (`cosmic.hash.hex`).
  --- The compiler says it after its `invalid key` for the member, or,
  --- for a type the module no longer declares (`cosmic.zip.ZipReader`),
  --- after its `unknown type`.
  members: {string:string}
  --- What to write instead of `name`, or of its field `field`.
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
local string_ <const> = 'local String = require("cosmic.string")'
local tar <const> = 'local Tar = require("cosmic.tar")'
local hash <const> = 'local Hash = require("cosmic.hash")'
local sqlite <const> = 'local Sqlite = require("cosmic.sqlite")'
local json <const> = 'local Json = require("cosmic.json")'
local sys <const> = 'local sys = require("cosmic.sys")'
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
    ["io.popen"] = "use Child.run(argv, { stdout = \"capture\" }); argv is a " ..
      "list, run without a shell or a PATH search (" .. child .. ")",
    ["os.getenv"] = "use Env.get(name) (" .. env .. ")",
    ["os.exit"] = "use Proc.exit(status) (" .. proc .. ")",
    ["os.time"] = "use Time.now_ns(), the wall clock in nanoseconds since " ..
      "the epoch (// 1000000000 for seconds), or Time.from_civil(fields, zone) " ..
      "for a calendar date, which reads it as UTC unless given a zone " ..
      "(Time.local_zone() for local time, Time.zone(\"Europe/Paris\") for " ..
      "another) and refuses a field out of range (day 32) rather than " ..
      "normalizing it (" .. time .. ")",
    ["os.clock"] = "use Time.monotonic_ns() to measure elapsed time; there " ..
      "is no process CPU clock (" .. time .. ")",
    ["os.difftime"] = "subtract two Time.now_ns() readings (" .. time .. ")",
    ["os.date"] = "use Time.civil(Time.now_ns(), zone) for the calendar's " ..
      "fields -- UTC's without a zone, local time with Time.local_zone(), " ..
      "or Time.zone(\"Europe/Paris\")'s -- or Time.format_rfc3339(ns, " ..
      "{ zone = zone }) for text; there is no strftime (" .. time .. ")",
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
    ["cosmic.json.lines"] = "use Stream.lines(reader) and Json.decode(line) on each " ..
      "line it reads, skipping a blank one (" .. stream .. "; " .. json .. ")",
    ["cosmic.json.Lines"] = "use Stream.Lines, what Stream.lines(reader) answers, " ..
      "and Json.decode(line) on each line (" .. stream .. "; " .. json .. ")",
    ["cosmic.json.write_line"] = "use writer:write(assert(Json.encode(value)) .. \"\\n\") on a " ..
      "Stream.Writer (" .. json .. ")",
    ["cosmic.json.encode_lines"] = "use Json.encode(value) for each value, joined by " ..
      "\"\\n\" and ended by one (" .. json .. ")",
    ["cosmic.json.parse_path"] = "moved to build.json_query, which only `cosmic json` " ..
      "and `cosmic sql --at` call; a script's path is a list of keys and indexes, " ..
      "`{ \"users\", 1, \"name\" }` for `$.users[1].name`, which Json.get takes (" .. json .. ")",
    ["cosmic.json.parse_pattern"] = "moved to build.json_query, which only `cosmic json` " ..
      "calls; `cosmic json '$..id' file` lists the values a pattern matches",
    ["cosmic.json.spell_pattern"] = "moved to build.json_query, which only `cosmic json` calls",
    ["cosmic.json.select"] = "moved to build.json_query, which only `cosmic json` calls; " ..
      "`cosmic json '$..id' file` lists the values a pattern matches, and a script " ..
      "walks the value Json.decode answers (" .. json .. ")",
    ["cosmic.json.flatten"] = "moved to build.json_query, which only `cosmic json` calls; " ..
      "`cosmic json --flat file` prints every leaf as a `path = value` line",
    ["cosmic.json.flat_line"] = "moved to build.json_query, which only `cosmic json` calls; " ..
      "`cosmic json --flat file` prints every leaf as a `path = value` line",
    ["cosmic.json.describe"] = "moved to build.json_query, which only `cosmic json` calls; " ..
      "`cosmic json --shape file` prints a document's shape",
    ["cosmic.json.child_path"] = "moved to build.json_query, which only `cosmic json` " ..
      "calls; spell a path by concatenating its steps, Json.quote(key) for a key that is no word (" ..
      json .. ")",
    ["cosmic.json.Step"] = "moved to build.json_query, with parse_pattern, which only " ..
      "`cosmic json` calls",
    ["cosmic.json.StepKind"] = "moved to build.json_query, with parse_pattern, which only " ..
      "`cosmic json` calls",
    ["cosmic.json.Located"] = "moved to build.json_query, with select and flatten, which " ..
      "only `cosmic json` calls",
    ["cosmic.json.WalkOptions"] = "moved to build.json_query, with select and flatten, " ..
      "which only `cosmic json` calls",
    ["cosmic.json.DescribeOptions"] = "moved to build.json_query, with describe, which " ..
      "only `cosmic json` calls",
    ["cosmic.zip.list"] = "use Archive.list(path) (" .. archive .. "), or " ..
      "Zip.open(path) and then reader:entries() (" .. zip .. ")",
    ["cosmic.zip.ZipReader"] = "use Zip.Reader, the same record renamed (" .. zip .. ")",
    ["cosmic.zip.ZipWriter"] = "use Zip.Writer, the same record renamed (" .. zip .. ")",
    ["cosmic.tar.TarReader"] = "use Tar.Reader, the same record renamed (" .. tar .. ")",
    ["cosmic.tar.TarWriter"] = "use Tar.Writer, the same record renamed (" .. tar .. ")",
    ["cosmic.archive.ArchiveReader"] = "use Archive.Reader, the same record renamed (" ..
      archive .. ")",
    ["cosmic.sys.spawn"] = "use Child.start(argv, opts), or Child.run(argv, opts) to " ..
      "run it to its end (" .. child .. ")",
    ["cosmic.sys.waitpid"] = "use h:wait() or h:try_wait() on the handle Child.start " ..
      "answers, or Child.wait_any(handles); only a handle reaps its child (" .. child .. ")",
    ["cosmic.sys.subreaper"] = "Child.start makes this process a subreaper the first " ..
      "time it starts a child in its own group (" .. child .. ")",
    ["cosmic.sys.landlock_ruleset"] = "there is no public way to hold a child to a " ..
      "ruleset yet; start one with Child.start(argv, opts) (" .. child .. ")",
    ["cosmic.sys.Sandbox"] = "there is no public way to hold a child to a ruleset, " ..
      "a pledge, an unveiled filesystem or no network yet; start one with " ..
      "Child.start(argv, opts) (" .. child .. ")",
    ["cosmic.sys.Unveil"] = "there is no public way to unveil a child's filesystem " ..
      "yet; start one with Child.start(argv, opts) (" .. child .. ")",
    ["cosmic.sys.ChildStatus"] = "use Child.Result, what h:wait() answers (" .. child .. ")",
    ["cosmic.sys.pipe"] = "use Child.start(argv, { stdin = \"pipe\" }) and h.stdin, " ..
      "or stdout = \"capture\" (" .. child .. ")",
    ["cosmic.sys.Pipe"] = "use Child.start(argv, { stdin = \"pipe\" }) and h.stdin, " ..
      "or stdout = \"capture\" (" .. child .. ")",
    ["cosmic.sys.ignore_sigpipe"] = "Child.start(argv, { stdin = \"pipe\" }), or " ..
      "{ input = bytes }, ignores SIGPIPE for this process, so a write to a child " ..
      "that has gone fails with EPIPE instead (" .. child .. ")",
    ["cosmic.sys.guard_child_signals"] = "use Child.guard(), and hold it in a " ..
      "<close> variable: local g <close> = assert(Child.guard()) (" .. child .. ")",
    ["cosmic.sys.cancelled_child_signal"] = "use g:take() on the guard Child.guard() " ..
      "answers, or g:cancelled() for the last signal caught (" .. child .. ")",
    ["cosmic.sys.unguard_child_signals"] = "use g:release() on the guard Child.guard() " ..
      "answers to keep the signal caught, or g:close() to deliver it again (" ..
      child .. ")",
    ["cosmic.sys.relaunch"] = "use Proc.relaunch() (" .. proc .. ")",
    ["cosmic.sys.Relaunch"] = "use Proc.Relaunch, what Proc.relaunch() answers (" ..
      proc .. ")",
    ["cosmic.sys.digest"] = "use Hash.digest(algorithm, data) (" .. hash .. ")",
    ["cosmic.sys.hmac"] = "use Hash.hmac(algorithm, key, data) (" .. hash .. ")",
    ["cosmic.sys.utimens"] = "use sys.utimensat(path, atime_s, atime_ns, mtime_s, " ..
      "mtime_ns), which takes each time as seconds and nanoseconds and leaves one " ..
      "whose seconds are nil as it is (" .. sys .. "), or Fs.set_mtime(path, " ..
      "seconds, ns) (" .. fs .. ")",
    ["cosmic.sys.EBUSY"] = "compare sys.errno_name(errno) with \"EBUSY\", the errno's " ..
      "name on every system (" .. sys .. ")",
    ["cosmic.sqlite.exec"] = "use db:exec(sql), the method on the handle Sqlite.open " ..
      "answers (" .. sqlite .. ")",
    ["cosmic.sqlite.close"] = "use db:close(), the method on the handle Sqlite.open " ..
      "answers (" .. sqlite .. ")",
    ["cosmic.sqlite.changes"] = "use db:changes(), the method on the handle Sqlite.open " ..
      "answers (" .. sqlite .. ")",
    ["cosmic.sqlite.last_insert_rowid"] = "use db:last_insert_rowid(), the method on " ..
      "the handle Sqlite.open answers (" .. sqlite .. ")",
  },
}

--- What to write instead of `name` (`os`), or of its field `field`
--- (`getenv`) when one is given: one line, the text a compile error
--- and a run-time failure both show. For a name with no entry, it says
--- only that the name is not available, or where to look.
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
