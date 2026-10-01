--- The standard globals cosmic removes (`io`, `os`, `debug`, `dofile`,
--- `loadfile`) and what to write instead of each. Using one is refused
--- at compile time (`unknown variable: os`), and a chunk handed to
--- `load` that reaches for one fails at run time; both errors say
--- what to use instead, naming the replacement for the very field used
--- (`os.getenv` is [`Env.get`]). `cosmic docs os` (or any field below)
--- answers the same thing directly. `members` does the same at compile
--- time for a member a `cosmic.*` module no longer has, and `arguments`
--- for a boolean passed where a record is now taken. Help on the
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
  -- (put Json.null where the hole is, as decode's `null_value` does);
  -- and for the fields cosmic.archive's ExtractOptions lost:
  -- `unsupported` (an entry that cannot be extracted always fails the
  -- extraction; `filter` leaves its path out), `mtimes` (every file,
  -- directory and symlink gets its archived time) and `max_bytes` (no
  -- replacement; `max_entries` bounds the entries).
  -- Likewise for what cosmic.time's records lost: `Civil.nanosecond` and
  -- `Duration.nanoseconds` (both `ns` now), and the `zone` field of
  -- FormatOptions and AddOptions (the zone is an argument, right after the
  -- data: `format_rfc3339(ns, zone, opts)`, `add_calendar(ns, duration,
  -- zone, opts)`).
  -- Likewise for what cosmic.child's Handle lost: `close_stdin` (close the
  -- Writer `h.stdin_stream` answers, so the child reads end of file) and
  -- the `stdin` field (the descriptor `stdin = "pipe"` gave; that mode
  -- went too, and a start with it raises naming "stream"), the mode
  -- being a value, which `members` cannot key either.
  -- Likewise for the spans every record held in milliseconds or seconds:
  -- `timeout_ms` (Child.Options, Net.ListenOptions, Net.ConnectOptions,
  -- Net.ServeSpec and Http.Options), `grace_ms` (Net.ServeSpec),
  -- `connect_timeout_ms` and `low_speed_seconds` (Http.Options) are
  -- `timeout_ns`, `grace_ns`, `connect_timeout_ns` and `low_speed_ns`,
  -- each a count of nanoseconds written `Time.ms(n)` or `Time.seconds(n)`.
  -- A positional span whose name stays (Poll.delay, Poll.readable,
  -- Poll.writable, Poll.ready, `:join`, `:wait`, `:accept`,
  -- Child.wait_any, g:wait) changed its unit too, which no compile error
  -- can say: an integer is an integer.
  -- TODO: a whole module that left the library (cosmic.dataset, now
  -- build.dataset) has no entry: `members` names a member of a module
  -- that still loads, and a `require` of a module that is gone says only
  -- that it is not found. Key an entry by module name once the loader's
  -- error can look one up.
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
  --- What to write where a boolean is passed for a parameter that now
  --- takes a record, by the record's module and name
  --- ([`cosmic.sqlite.OpenOptions`]). The compiler says it after its
  --- `argument 2: got boolean, expected Sqlite.OpenOptions`.
  arguments: {string:string}
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
local streamed <const> = "the streaming coders are `cosmic codec`'s, not the library's; " ..
  "a program encodes a whole string with Codec.hex, Codec.base64 or " ..
  "Codec.base64url and decodes one with Codec.unhex, Codec.unbase64 or " ..
  "Codec.unbase64url (" .. codec .. ")"
local archive <const> = 'local Archive = require("cosmic.archive")'
local entry_kind <const> = "use Stream.EntryKind, the one enum every archive entry's kind is (" ..
  'local Stream = require("cosmic.stream")' .. ")"
local zip <const> = 'local Zip = require("cosmic.zip")'
local string_ <const> = 'local String = require("cosmic.string")'
local tar <const> = 'local Tar = require("cosmic.tar")'
local hash <const> = 'local Hash = require("cosmic.hash")'
local sqlite <const> = 'local Sqlite = require("cosmic.sqlite")'
local json <const> = 'local Json = require("cosmic.json")'
local csv <const> = 'local Csv = require("cosmic.csv")'
local shape <const> = 'local Shape = require("cosmic.shape")'
local sys <const> = 'local sys = require("cosmic.sys")'
local cli <const> = 'local Cli = require("cosmic.cli")'
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
      "or Time.zone(\"Europe/Paris\")'s -- or Time.format_rfc3339(ns, zone) " ..
      "for text; there is no strftime (" .. time .. ")",
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
    ["cosmic.hash.Mac"] = "use Hash.Hasher, which Hash.hmac_hasher answers as " ..
      "Hash.hasher does (" .. hash .. ")",
    ["cosmic.json.lines"] = "use Stream.lines(reader) and Json.decode(line) on each " ..
      "line it reads, skipping a blank one (" .. stream .. "; " .. json .. ")",
    ["cosmic.json.Lines"] = "use Stream.Lines, what Stream.lines(reader) answers, " ..
      "and Json.decode(line) on each line (" .. stream .. "; " .. json .. ")",
    ["cosmic.json.write_line"] = "use writer:write(assert(Json.encode(value)) .. \"\\n\") on a " ..
      "Stream.Writer (" .. json .. ")",
    ["cosmic.json.encode_lines"] = "use Json.encode(value) for each value, joined by " ..
      "\"\\n\" and ended by one (" .. json .. ")",
    ["cosmic.json.parse_path"] = "moved to build.json_query, which only `cosmic json` " ..
      "and `cosmic sql --at` call; a script indexes the value Json.decode answers " ..
      "directly, `doc.users[1].name` for `$.users[1].name` (" .. json .. ")",
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
    ["cosmic.json.get"] = "moved to build.json_query, which only `cosmic json` and " ..
      "`cosmic sql --at` call; a script indexes the table Json.decode_object or " ..
      "Json.decode_array answers directly, `doc.users[1].name`, and finds a missing " ..
      "key as nil (" .. json .. ")",
    ["cosmic.json.entries"] = "moved to build.json_query, which only `cosmic json` and " ..
      "`cosmic sql --at` call; Json.decode_object answers the outermost object as a " ..
      "map to loop over with pairs; `value is {string: any}` narrows a field to a " ..
      "table, and Json.is_array(value) tells an array from an object (" ..
      json .. ")",
    ["cosmic.json.items"] = "moved to build.json_query, which only `cosmic json` and " ..
      "`cosmic sql --at` call; Json.decode_array answers the outermost array as a " ..
      "list to loop over with ipairs; `value is {any}` narrows a field to a table, " ..
      "and Json.is_array(value) tells an array from an object (" ..
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
    ["cosmic.csv.rows"] = "use Csv.table(text, opts) and its rows field, the table per record " ..
      "that Csv.rows answered (" .. csv .. ")",
    ["cosmic.csv.encode"] = "write each record's fields joined by the delimiter, a field that " ..
      "holds the delimiter, a quote or a line break in quotes with each quote doubled, " ..
      "and a line feed after the record; also quote a field that begins with the byte order " ..
      "mark (a reader drops one there) and the empty only field of a record (else the " ..
      "record is a blank line); there is no writer in the library",
    ["cosmic.shape.failures"] = "use Shape.into(value, spec), which answers the first " ..
      "failure; a config whose author wants every mistake runs again after fixing each (" ..
      shape .. ")",
    ["cosmic.shape.Failure"] = "Shape.into(value, spec) answers the first failure as one " ..
      "message, its path first (`$.rows[2].id: expected string, got integer`) (" .. shape .. ")",
    ["cosmic.shape.either"] = "use Shape.one_of(...) for literal alternatives, or call " ..
      "Shape.into once for each form the value may take and keep the first that answers " ..
      "a value (" .. shape .. ")",
    ["cosmic.codec.encoder"] = streamed,
    ["cosmic.codec.decoder"] = streamed,
    ["cosmic.codec.Coder"] = streamed,
    ["cosmic.codec.Name"] = streamed,
    ["cosmic.zip.list"] = "use Archive.list(path) (" .. archive .. "), or " ..
      "Zip.open(path) and then reader:entries() (" .. zip .. ")",
    ["cosmic.zip.ZipReader"] = "use Zip.Reader, the same record renamed (" .. zip .. ")",
    ["cosmic.zip.ZipWriter"] = "use Zip.Writer, the same record renamed (" .. zip .. ")",
    ["cosmic.tar.TarReader"] = "use Tar.Reader, the same record renamed (" .. tar .. ")",
    ["cosmic.tar.TarWriter"] = "use Tar.Writer, the same record renamed (" .. tar .. ")",
    ["cosmic.archive.ArchiveReader"] = "use Archive.Reader, the same record renamed (" ..
      archive .. ")",
    ["cosmic.archive.Kind"] = entry_kind,
    ["cosmic.tar.Kind"] = entry_kind,
    ["cosmic.zip.Kind"] = entry_kind,
    ["cosmic.tar.EntryOptions"] = "use Stream.EntryOptions, which Tar.Writer's add_file, " ..
      "add_dir and add_symlink take and Zip's EntryOptions extends (" .. stream .. ")",
    ["cosmic.archive.Unsupported"] = "an entry Archive.extract cannot extract (a hard " ..
      "link, a device, a FIFO, a sparse file) always fails it, naming the entry; " ..
      "leave its path out with ExtractOptions.filter (" .. archive .. ")",
    ["cosmic.stream.Codec"] = "use Stream.Transform, the interface Stream.transform, " ..
      "Stream.transform_writer and Stream.run take, which Compress.Stream " ..
      "satisfies (" .. stream .. ")",
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
    ["cosmic.sys.pipe"] = "use Child.start(argv, { stdin = \"stream\" }) and " ..
      "h.stdin_stream, or stdout = \"capture\" (" .. child .. ")",
    ["cosmic.sys.Pipe"] = "use Child.start(argv, { stdin = \"stream\" }) and " ..
      "h.stdin_stream, or stdout = \"capture\" (" .. child .. ")",
    ["cosmic.sys.ignore_sigpipe"] = "Child.start(argv, { stdin = \"stream\" }), or " ..
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
    ["cosmic.time.Change"] = "use Time.Duration, which Time.add_calendar takes: " ..
      "years, months, days and an exact part in `ns` (" .. time .. ")",
    ["cosmic.time.CivilOptions"] = "use Time.AddOptions, the one record Time.from_civil " ..
      "and Time.add_calendar take (" .. time .. ")",
    ["cosmic.time.days_between"] = "use Time.between(from, to, zone), whose Duration " ..
      "holds the whole years, months and days between two moments; the days between " ..
      "two dates alone are (Time.parse_date(Time.format_date(to, zone)) - " ..
      "Time.parse_date(Time.format_date(from, zone))) // Time.hours(24) (" .. time .. ")",
    ["cosmic.time.months_between"] = "use Time.between(from, to, zone): its years * 12 " ..
      "+ months are the whole months (" .. time .. ")",
    ["cosmic.time.parse_input"] = "moved to build.time, which only `cosmic time` calls; " ..
      "`cosmic time convert <text>` reads what a person typed, and a script reads " ..
      "RFC 3339 with Time.parse_rfc3339_zoned, a date with Time.parse_date(text, zone) and " ..
      "a local time with Time.from_civil(fields, zone, opts) (" .. time .. ")",
    ["cosmic.time.zone_from_posix"] = "use Time.local_zone({ tz = tz }), which reads a " ..
      "POSIX TZ string when the binary carries no zone of that name; Time.zone(name) " ..
      "answers one it does (" .. time .. ")",
    ["cosmic.sqlite.cell"] = "use Sqlite.rows(db, sql, values), whose rows carry typed cells, " ..
      "or Sqlite.query(db, sql, values) to read them one at a time (" .. sqlite .. ")",
    ["cosmic.sqlite.exec"] = "use db:exec(sql), the method on the handle Sqlite.open " ..
      "answers (" .. sqlite .. ")",
    ["cosmic.sqlite.close"] = "use db:close(), the method on the handle Sqlite.open " ..
      "answers (" .. sqlite .. ")",
    ["cosmic.sqlite.changes"] = "use db:changes(), the method on the handle Sqlite.open " ..
      "answers (" .. sqlite .. ")",
    ["cosmic.sqlite.last_insert_rowid"] = "use db:last_insert_rowid(), the method on " ..
      "the handle Sqlite.open answers (" .. sqlite .. ")",
    ["cosmic.coverage.snapshot"] = "a program's hits are what Coverage.stop(session) answers; " ..
      "a test reads the open window through build.coverage_hits",
    ["cosmic.coverage.native_entries"] = "read each C function's first line from " ..
      "Coverage.native_functions(); a test reads them through build.coverage_hits",
    ["cosmic.test.fields"] = "the build checks a `needs` declaration's fields; declare " ..
      "needs with Test.needs { ... } and let `cosmic test` refuse a bad one",
    ["cosmic.test.any_host_refusal"] = "the build refuses `network = true`; declare " ..
      "loopback addresses 127.a.b.c in Test.needs and let `cosmic test` refuse a bad one",
    ["cosmic.test.network_trouble"] = "the build refuses a `network` that is no loopback " ..
      "address 127.a.b.c; declare it in Test.needs and let `cosmic test` check it",
    ["cosmic.test.lua_trouble"] = "the build refuses a `lua` beside tool, store, system or " ..
      "caches; declare Test.needs and let `cosmic test` refuse a bad one",
    ["cosmic.cli.options"] = "use Cli.verbs[verb].spec, the options of the verb's " ..
      "Flags.Command (" .. cli .. ")",
    ["cosmic.cli.usage"] = "use Cli.verbs[verb].usage, which follows the verb's name " ..
      "rather than beginning with `cosmic` (" .. cli .. ")",
    ["cosmic.cli.summary"] = "use Cli.verbs[verb].about, the verb's Flags.Command " ..
      "description (" .. cli .. ")",
  },
  -- TODO: a call that still passes Flags.help its old arguments (the usage
  -- line, the spec, what the command does) gets only `argument 1: got
  -- string, expected Flags.Command`, with no hint: `arguments` answers a
  -- boolean given for a record. Say `Flags.help({ spec = spec, about =
  -- about, usage = <what follows the program's name> }, program)` once
  -- [`build.teal`]'s `replacement` also reads a string given for a record.
  -- TODO: a call that still passes Sqlite.open's old third argument gets
  -- only the arity error (`wrong number of arguments ... at most 2`), with
  -- no hint: the message names no callee. Say `{ immutable = true }` for
  -- `false, true` once the checker carries a hint for an arity error that
  -- names the callee.
  arguments = {
    ["cosmic.sqlite.OpenOptions"] = "Sqlite.open(path, opts) takes a table: " ..
      "{ writable = true } for the old `true`, and nothing for `false` (" ..
      sqlite .. ")",
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
