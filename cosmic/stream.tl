--- Pull and push byte streams: the small abstraction `tar`, `zip` and
--- `archive` are built on, so they can walk an archive or a compressed
--- body in bounded memory, one chunk at a time, without caring whether
--- the bytes come from a string, a descriptor, or a decompressor.
---
--- A Reader's `read` returns a non-empty chunk of at most `max_bytes` bytes
--- -- or, when `max_bytes` is omitted, of whatever size suits that Reader
--- (the rest of a string, 64 KiB of a file) -- or nil and `""` at end
--- of file, or nil and an error. An error is sticky: every later
--- `read` returns the same error rather than a false end of file.
--- A Writer's `write` takes one chunk at a time; `close` commits what
--- was written, `abort` discards it where that means anything (a
--- [`Stream.create`] file is never renamed into place), and a `write`
--- after either fails. Every constructor here gives `close` (and each
--- Writer `abort`), even where it does nothing, and each is safe to
--- call more than once, so a caller never has to ask which kind it
--- holds. [`Stream.lines`] reads a Reader a line at a time.

local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Poll = require("cosmic.poll")
local String = require("cosmic.string")
local sys = require("cosmic.sys")
local Time = require("cosmic.time")

-- The raw declaration holds the interface. A declaration may require only
-- declarations, and Teal's interface conformance is nominal: the raw
-- Stream must say `is Transform` where it is declared.
local type raw_compress = require("cosmic.internal.compress")

local record Stream
  interface Reader
    --- The next chunk of at most `max_bytes` bytes, or nil and `""` at the
    --- end, or nil and an error; see the module's description.
    -- TODO: a `max_bytes` below 1 answers nil and "", a false end of
    -- the stream, from Stream.from_string's and Stream.prepend's Readers
    -- (so from a Lines' `rest` holding bytes read ahead); raise on it in
    -- every Reader here instead, as Stream.lines does on its own.
    read: function(Reader, max_bytes?: integer): string | nil, string
    --- Releases what the Reader holds. Safe to call more than once.
    close: function(Reader): boolean, string
    --- Present only on a Reader that can move forward without reading
    --- (one over a regular file): skips `n` bytes, failing when that
    --- would pass the end of the file. A caller checks for it and
    --- falls back to reading and discarding.
    skip: function(Reader, n: integer): boolean, string
  end

  interface Writer
    --- Takes one chunk; false and why when it cannot.
    write: function(Writer, string): boolean, string
    --- Commits what was written. Safe to call more than once.
    close: function(Writer): boolean, string
    --- Discards what was written, where that means anything. Safe to
    --- call more than once.
    abort: function(Writer): boolean, string
  end

  --- What [`Stream.create`] returns: a Writer that can also `sync`.
  interface FileWriter is Writer
    --- Flushes what was written to storage, so that the rename `close`
    --- makes cannot reach it before the data does.
    sync: function(FileWriter): boolean, string
  end

  --- How [`Stream.from_fd`] and [`Stream.to_fd`] wait for a descriptor
  --- that has nothing to read or no room to write. `timeout_ns` and
  --- `wait` need `nonblocking`: a blocking descriptor cannot be
  --- waited on in pieces, so asking for either raises.
  record FdOptions
    --- That the descriptor is in non-blocking mode (the caller set
    --- `O_NONBLOCK`): a read that finds nothing, or a write that finds
    --- no room, waits for the descriptor instead of failing, through
    --- [`Poll.wait`], so in a task of [`Poll.run`] the other tasks run
    --- meanwhile.
    nonblocking: boolean
    --- The longest one `read` or one `write` waits in all, in
    --- nanoseconds, from its call; nil for no limit. A call that runs
    --- out of it fails with [`Poll.TIMEOUT`], and the stream stays
    --- usable: a read took nothing, and a write says how much it wrote
    --- (`written` of [`Stream.FdWriter`]). A value outside what [`Poll.checked_ns`]
    --- allows raises.
    timeout_ns: integer
    --- Waits in place of [`Poll.wait`], for a caller that waits on more
    --- than this descriptor (a supervisor servicing other pipes
    --- meanwhile). It is called with the descriptor, the events wanted
    --- ([`sys.POLLIN`] or [`sys.POLLOUT`]) and the time left in
    --- nanoseconds, nil for no limit, and answers true once the
    --- descriptor may be ready (the read or write tries again, and
    --- waits again if it was not), or false and why: [`Poll.TIMEOUT`]
    --- or [`Poll.CANCELLED`] end the call and leave the stream usable,
    --- any other why ends the stream for good.
    wait: function(integer, integer, integer | nil): boolean, string
  end

  --- What [`Stream.to_fd`] answers: a Writer that counts what the
  --- descriptor took.
  interface FdWriter is Writer
    --- How many bytes the descriptor has taken from this Writer in all,
    --- those of a write that then failed included: after a write that
    --- fails with [`Poll.TIMEOUT`], the difference from before it is
    --- how much of that write went, and `data:sub(went + 1)` what is
    --- left to write.
    written: function(FdWriter): integer
  end

  --- An in-memory Writer that also hands back everything written to it.
  interface Collector is Writer
    --- Everything written so far.
    result: function(Collector): string
  end

  --- A Writer that digests everything written to it.
  interface Hashing is Writer
    --- The raw digest of everything written so far, or nil and why
    --- the hasher could not finish; the Writer takes no more writes
    --- afterward, and asking again answers the same.
    digest: function(Hashing): string | nil, string
  end

  --- What [`Stream.transform_writer`] takes beyond its two arguments.
  record TransformWriterOptions
    --- How many writes' output to hold back; 0 or nil for none. With
    --- `hold = n`, the output of a `write` reaches the underlying
    --- Writer only once `n` later writes have been transformed without
    --- failing, or at `close`, which commits all that is held with the
    --- codec's last output and writes nothing of it when the codec
    --- refuses. So a stream of at most `n` writes that the codec
    --- refuses writes nothing at all, and a longer one may have
    --- written the output of every write but its last `n`.
    ---
    --- The guarantee is in the caller's writes, not in bytes: a caller
    --- that wants a window of input bytes held back must chunk its
    --- writes to that size (as `cosmic codec` does with
    --- [`Stream.read_up_to`]), since a short write holds as much of the
    --- window as a long one. A write's output is held whole, whatever
    --- it expands to and whether or not it is empty.
    ---
    --- An empty write differs: with `hold` it is skipped, no write and
    --- the codec not called, whereas without `hold` `write("")` still
    --- calls `update("")`. A negative or non-integer `hold` raises.
    hold: integer
  end

  --- The lines of a Reader, one at a time: see [`Stream.lines`].
  interface Lines
    --- The next line, without its "\n", and ""; nil and "" after the
    --- last; nil and why when the Reader failed or a line ran past the
    --- limit, the same again on every later read.
    read: function(Lines): string | nil, string
    --- An iterator for a `for` loop over the lines still to come. It
    --- ends at the last one or at a failure, which `failure` then says.
    each: function(Lines): function(): string
    --- Why the lines ended early, or "" when they have not: after an
    --- `each` loop, "" means every line was read.
    failure: function(Lines): string
    --- The rest of the stream as a Reader, for a protocol that turns
    --- from lines to bytes (a head, then a body): the bytes these lines
    --- read ahead past the last line given, then whatever the Reader
    --- has after them. Closing it closes the Reader, as
    --- [`Stream.prepend`]'s does. It ends the lines: a later `read`,
    --- `each` or `rest` raises, since a line read past it would take
    --- bytes the Reader had already given. After a failure it answers
    --- that failure on every read, and after the end, the end.
    rest: function(Lines): Reader
  end

  --- A format writer's hold on the Writer it writes to: see
  --- [`Stream.sticky`].
  interface Sticky
    --- Writes `data` to the Writer, failing as `fail` does when it
    --- cannot.
    put: function(Sticky, data: string): boolean, string
    --- Keeps `trouble` as the failure, or "<name>: write failed" when it
    --- is "", and aborts the Writer, the first time; false and the
    --- failure kept, every time.
    fail: function(Sticky, trouble: string): boolean, string
    --- True and "" while more may be written; false and the failure,
    --- or "<name>: the writer is closed" once `close` or `abort` ran.
    usable: function(Sticky): boolean, string
    --- Puts `trailer` and closes the Writer, once: false and the
    --- failure kept when there is one, and true and "" when it is
    --- already closed.
    close: function(Sticky, trailer: string): boolean, string
    --- Aborts the Writer unless it is closed or failed already.
    abort: function(Sticky): boolean, string
  end

  --- One incremental transform, a chunk at a time: what
  --- [`Stream.transform`], [`Stream.transform_writer`] and
  --- [`Stream.run`] drive. [`cosmic.compress`]'s inflaters, deflaters
  --- and decoders are Transforms, and so are `cosmic codec`'s coders.
  --- Every call answers `value, ""` on success and `nil, error` on
  --- failure.
  ---
  --- `update(chunk)` feeds `chunk` and answers the output that is
  --- ready, possibly "". On bad input it answers `nil` and why, and
  --- the Transform is finished.
  ---
  --- `finish()` says no more input follows and answers what is left,
  --- or `nil` and why when the input ended where it could not (a
  --- compressed stream cut short). A driver calls it once, after the
  --- last `update`.
  ---
  --- `pending()` is present only on a Transform that can hold output
  --- back, as a decoder does to bound what one call returns however
  --- far its input expands: it says whether some is held, which
  --- `update("")` then gives out. A driver drains it, calling
  --- `update("")` while `pending()` answers true, before it feeds
  --- more input or calls `finish`; where there is no `pending`,
  --- nothing is ever held.
  type Transform = raw_compress.Transform

  --- What an archive entry is. A zip entry is only ever a "file", a
  --- "dir" or a "symlink".
  enum EntryKind
    "file"
    "dir"
    "symlink"
    --- A tar entry that names another entry of the archive as `linkpath`.
    "hardlink"
    --- Anything else: a device, a FIFO, a GNU sparse file (typeflag
    --- `S`, or pax `GNU.sparse.*` records), or a typeflag this module
    --- does not know. Its body, if any, is still skipped correctly.
    "other"
  end

  -- TODO: once `cosmic docs` lists the fields a record gets from an `is`
  -- parent, the pages of Tar.Entry, Zip.Entry, Archive.Entry and
  -- Archive.Reader should show path, kind, mode, size, mtime, linkpath and
  -- open (this interface's, with their docs) beside each record's own
  -- fields; today those two aliases list none and the records list only
  -- what they redeclare.
  --- One entry of a tar or a zip, as [`cosmic.archive`] walks both. The
  --- interface lives here, not there, because Teal's interface
  --- conformance is nominal: [`cosmic.tar`] and [`cosmic.zip`] each
  --- declare their entry `is` it, and [`cosmic.archive`] requires them
  --- both.
  interface ArchiveEntry
    --- The entry's path as the archive stores it.
    path: string
    --- What the entry is.
    kind: EntryKind
    --- The permission bits (the low 12); 0 for a zip entry whose tool
    --- recorded none.
    mode: integer
    --- The body's size in bytes, uncompressed. A zip symlink's body is its
    --- target, so its size is the target's length; a tar symlink's is 0.
    size: integer
    --- The modification time, in Unix epoch seconds.
    mtime: integer
    --- A symlink's or hardlink's target; "" otherwise.
    linkpath: string
    --- The entry's body. Read it before asking for the next entry: a
    --- tar body cannot be read after that, and no body can be read once
    --- the reader is closed. An entry from [`Archive.list`] cannot be
    --- opened at all.
    open: function(ArchiveEntry): Reader | nil, string
  end

  --- The entries of a tar or a zip, one at a time: what
  --- [`cosmic.tar`]'s and [`cosmic.zip`]'s readers are, and what
  --- [`Archive.open`] and [`Archive.open_stream`] answer.
  interface ArchiveReader
    --- The next entry, nil and "" at the end, or nil and an error. For
    --- a compressed tar, the end also runs the decompressor to the end
    --- of its stream, so a truncated or corrupt one fails here rather
    --- than passing as a complete archive.
    next: function(ArchiveReader): ArchiveEntry | nil, string
    --- Closes the file or stream the archive is read from.
    close: function(ArchiveReader): boolean, string
  end

  --- What [`ArchiveWriter`] may be told about an entry. Every field is
  --- optional. A zip's own options, [`Zip.EntryOptions`], add the `method`
  --- a body is stored by.
  interface EntryOptions
    --- The permission bits (the low 12 are written). Defaults to 0644
    --- for a file, 0755 for a directory and 0777 for a symlink.
    mode: integer
    --- Modification time in Unix epoch seconds; defaults to 0. Ignored
    --- (the archive's own zero) when the writer is `deterministic`.
    mtime: integer
    --- The body's size, for a file whose body is a [`Stream.Reader`]: required
    --- by a tar, whose header states it before the body, and optional
    --- for a zip. One that is no integer, or is negative, raises, whatever
    --- the body.
    size: integer
  end

  --- The writer a tar or a zip gives: [`cosmic.tar`]'s and
  --- [`cosmic.zip`]'s writers are one, so a caller that packs a tree
  --- writes it once. Once any call fails, the underlying [`Stream.Writer`] is
  --- aborted and every later call, `close` included, returns that
  --- failure: a half-written archive is never committed. A call after
  --- `close` fails too.
  interface ArchiveWriter
    --- Adds a regular file at `path` with `data` as its body. A
    --- [`Stream.Reader`] body is read to `opts.size` bytes (to its end, when
    --- the format allows no size), and is not closed. Returns `true,
    --- ""`, or `false` and why.
    add_file: function(ArchiveWriter, path: string, data: string | Reader, opts?: EntryOptions): boolean, string
    --- Adds a directory entry at `path`, to which a trailing `/` is
    --- added if missing. Returns `true, ""`, or `false` and why.
    add_dir: function(ArchiveWriter, path: string, opts?: EntryOptions): boolean, string
    --- Adds a symbolic link at `path` pointing at `target`. Returns
    --- `true, ""`, or `false` and why.
    add_symlink: function(ArchiveWriter, path: string, target: string, opts?: EntryOptions): boolean, string
    --- Writes the archive's end and closes the underlying [`Stream.Writer`],
    --- committing it. Returns `true, ""`, or `false` and why.
    close: function(ArchiveWriter): boolean, string
    --- Abandons the archive: aborts the underlying [`Stream.Writer`].
    abort: function(ArchiveWriter): boolean, string
  end
end

local chunk_size = 1 << 16

--- What a failure of this module answers, nil and `why` under the
--- module's name.
local function refuse(why: string): nil, string
  return nil, "stream: " .. why
end

local closed_reader <const> = "stream: the reader is closed"
local closed_writer <const> = "stream: the writer is closed"

-- How an object of this module is made. A Reader or Writer is a record of
-- its own, named for what it makes (`<Kind>Reader`, `<Kind>Writer`) and
-- implementing the public interface it answers, with its metatable the
-- snake-case name and `_mt` (`from_string_reader_mt`). Its methods are
-- defined once, on the record's own table, which an instance reaches
-- through `__index`; its state is in fields, so an object costs one table,
-- not a closure for each method. Teal limits how that is written, for good:
--
-- * A record's `is` clause (not the `is` operator) takes only interfaces,
--   so a public type that a record here implements is an interface
--   (FileWriter, FdWriter, Collector, Hashing, Lines and Sticky), whatever
--   fields it documents.
-- * An interface method's `self` is the interface, but `function Rec:m`
--   is checked against the record's own declaration, so a record
--   redeclares each method it defines as a field whose `self` is itself.
--   That redeclaration is in turn checked against the interface's, which
--   a `{string:any}` method table would not be.
-- * Each constructor builds its table into a local of the record's type
--   (`local r: Rec = setmetatable({ ... }, rec_mt)`), which is what checks
--   the literal's field names; a return type alone would not.
-- * Nothing catches a state field a constructor forgot, and a field read
--   while nil misses through `__index` on every access: a flag read on
--   every call (`closed`, `ended`) starts `false`, not nil.
-- * Only the interface's methods, and the documented extras (`written`,
--   `skip`, `each`, `digest`, `sync`), are declared on the record; a
--   helper is a `local function name(self: Rec, ...)` after it, so it is
--   no method an instance could be asked for.
-- * A method some instances lack is a field of those instances only
--   (`skip` on a Reader of a regular file), never of the shared table.

local record FromStringReader is Stream.Reader
  data: string
  at: integer
  closed: boolean
  read: function(FromStringReader, max_bytes?: integer): string | nil, string
  close: function(FromStringReader): boolean, string
  skip: function(FromStringReader, n: integer): boolean, string
end

local from_string_reader_mt: metatable<FromStringReader> = { __index = FromStringReader }

function FromStringReader:read(max_bytes?: integer): string | nil, string
  if self.closed then return nil, closed_reader end
  local data, at = self.data, self.at
  if at > #data then return nil, "" end
  local want = max_bytes or (#data - at + 1)
  if want <= 0 then return nil, "" end
  -- Clamped before it is added, so a huge `max_bytes` cannot wrap `stop`.
  if want > #data - at + 1 then want = #data - at + 1 end
  local stop = at + want - 1
  self.at = stop + 1
  return data:sub(at, stop), ""
end

function FromStringReader:close(): boolean, string
  self.closed = true
  return true, ""
end

function FromStringReader:skip(n: integer): boolean, string
  if self.closed then return false, closed_reader end
  if n < 0 then return false, "stream: skip of a negative count" end
  -- Compared this way round, so a huge `n` cannot wrap `at + n`.
  if n > #self.data + 1 - self.at then
    self.at = #self.data + 1
    return false, "stream: skip past the end of the data"
  end
  self.at = self.at + n
  return true, ""
end

--- A Reader over bytes already in memory.
function Stream.from_string(s: string): Stream.Reader
  local r: FromStringReader = setmetatable({ data = s, at = 1, closed = false }, from_string_reader_mt)
  return r
end

--- `opts` as [`Stream.from_fd`] and [`Stream.to_fd`] take them, checked,
--- raising at `level` above the caller of this function's caller.
local function fd_options(opts: Stream.FdOptions | nil, level: integer): Stream.FdOptions
  if opts == nil then return {} end
  Poll.checked_ns(opts.timeout_ns, "stream", "timeout_ns", level + 1)
  if (opts.timeout_ns ~= nil or opts.wait ~= nil) and not opts.nonblocking then
    error("stream: timeout_ns and wait need nonblocking = true: a blocking descriptor " ..
        "cannot be waited on in pieces", level + 1)
  end
  -- A copy, so a field set after this check cannot go past it.
  return { nonblocking = opts.nonblocking, timeout_ns = opts.timeout_ns, wait = opts.wait }
end

--- Waits for `fd` to have `events` until `deadline` (nil for no limit),
--- through the caller's `wait` or [`Poll.wait`].
local function wait_for(fd: integer, events: integer, opts: Stream.FdOptions,
                        deadline: integer | nil): boolean, string
  local left: integer = nil
  if deadline ~= nil then left = math.max(deadline - Time.monotonic_ns(), 0) end
  if opts.wait ~= nil then return opts.wait(fd, events, left) end
  return Poll.wait(fd, events, left)
end

--- Whether a failed wait leaves its stream as it was: a deadline or a
--- cancelled task took nothing, so the call may be made again.
local function resumable(why: string): boolean
  return why == Poll.TIMEOUT or why == Poll.CANCELLED
end

local record FdReader is Stream.Reader
  fd: integer
  -- Whether the descriptor is closed with the Reader, once and at the
  -- end of the file or at `close`, whichever comes first.
  owned: boolean
  released: boolean
  opts: Stream.FdOptions
  -- `ended` is a clean end of file (reads keep answering it); `closed`
  -- is an explicit close (reads fail); `failed` is a sticky error.
  ended: boolean
  closed: boolean
  failed: string
  -- The file's size, which `skip` checks the new position against; set
  -- with `skip`, only on a regular file.
  size: integer
  read: function(FdReader, max_bytes?: integer): string | nil, string
  close: function(FdReader): boolean, string
  skip: function(FdReader, n: integer): boolean, string
end

local fd_reader_mt: metatable<FdReader> = { __index = FdReader }

-- Closes the descriptor the Reader owns, once.
local function release(self: FdReader): boolean, string
  if self.released or not self.owned then return true, "" end
  self.released = true
  return Fs.close(self.fd)
end

function FdReader:read(max_bytes?: integer): string | nil, string
  if self.failed then return nil, self.failed end
  if self.closed then return nil, closed_reader end
  if self.ended then return nil, "" end
  local fd, opts = self.fd, self.opts
  local deadline: integer = nil
  if opts.timeout_ns ~= nil then deadline = Time.monotonic_ns() + opts.timeout_ns end
  while true do
    local data, trouble, errno = sys.read(fd, max_bytes or chunk_size)
    if data ~= nil then
      if #data > 0 then return data, "" end
      self.ended = true
      local _, _ = release(self)
      return nil, ""
    end
    if not (opts.nonblocking and (errno == sys.EAGAIN or errno == sys.EINTR)) then
      self.failed = trouble ~= "" and trouble or "stream: read failed"
      return nil, self.failed
    end
    local ready, why = wait_for(fd, sys.POLLIN, opts, deadline)
    if not ready then
      if resumable(why) then return nil, why end
      self.failed = why
      return nil, why
    end
  end
end

function FdReader:close(): boolean, string
  if self.closed then return true, "" end
  self.closed = true
  return release(self)
end

-- Only a regular file can seek, so only its Reader has a `skip` (a pipe or
-- socket reads and discards, which a caller tests for): it is set as a field
-- of that Reader, not put on the shared methods.
local function file_skip(self: FdReader, n: integer): boolean, string
  if self.failed then return false, self.failed end
  if self.closed then return false, closed_reader end
  if n == 0 then return true, "" end
  if self.ended then
    self.failed = "stream: skip past the end of the file"
    return false, self.failed
  end
  local at, trouble = sys.lseek(self.fd, n, sys.SEEK_CUR)
  if at == nil then
    self.failed = trouble
    return false, trouble
  end
  -- lseek happily moves past the end; the size says whether that
  -- skipped bytes the file never had. It is asked for again only
  -- when the one from opening says so, in case the file grew.
  if at > self.size then
    local now, _ = sys.fstat(self.fd)
    if now ~= nil then self.size = now.size end
    if at > self.size then
      self.failed = "stream: skip past the end of the file"
      return false, self.failed
    end
  end
  return true, ""
end

local function make_fd_reader(fd: integer, owned: boolean, opts: Stream.FdOptions): Stream.Reader
  local r: FdReader = setmetatable({ fd = fd, owned = owned, released = false, opts = opts,
    ended = false, closed = false }, fd_reader_mt)
  local st, _ = sys.fstat(fd)
  if st ~= nil and st.kind == "file" then
    r.size = st.size
    r.skip = file_skip
  end
  return r
end

--- A Reader over an already-open descriptor. The descriptor is not
--- closed at end of file or by `close`; use [`Stream.open`] for a
--- Reader that owns the file it reads. Over a regular file the Reader
--- can `skip`.
---
--- Over a descriptor in non-blocking mode, `opts.nonblocking` makes a
--- read that finds nothing wait for data, as [`Stream.FdOptions`] says,
--- and `opts.timeout_ns` bounds that wait: the read then fails with
--- [`Poll.TIMEOUT`], and may be called again. A deadline or a cancelled
--- task is the one failure that is not sticky.
---
---     local r = Stream.from_fd(fd, { nonblocking = true, timeout_ns = Time.ms(50) })
---     local chunk, why = r:read()
---     if chunk == nil and why == Poll.TIMEOUT then print("nothing for 50 ms") end
function Stream.from_fd(fd: integer, opts?: Stream.FdOptions): Stream.Reader
  return make_fd_reader(fd, false, fd_options(opts, 2))
end

--- A Reader over a file at `path`, which it closes at end of file or
--- at `close`, whichever comes first. Over a regular file it can
--- `skip`.
function Stream.open(path: string): Stream.Reader | nil, string
  local fd, trouble = Fs.open_read(path)
  if fd == nil then return nil, trouble end
  return make_fd_reader(fd, true, {}), ""
end

--- Whether `t` holds output back, which `update("")` gives out; a
--- Transform with no `pending` never does.
local function holds_output(t: Stream.Transform): boolean
  return t.pending ~= nil and t:pending()
end

local record TransformReader is Stream.Reader
  source: Stream.Reader
  codec: Stream.Transform
  -- `batch` holds the codec's last batch of output, and `at` is how
  -- far into it this reader has already given out -- an offset rather
  -- than shrinking `batch` on every read, since a codec can hand
  -- back megabytes at once and a caller that reads in small pieces
  -- (a tar header at a time, say) would otherwise re-copy the whole
  -- remaining batch on every read.
  batch: string
  at: integer
  at_eof: boolean
  finished: boolean
  failed: string
  closed: boolean
  read: function(TransformReader, max_bytes?: integer): string | nil, string
  close: function(TransformReader): boolean, string
end

local transform_reader_mt: metatable<TransformReader> = { __index = TransformReader }

-- One step of the codec: its next batch of output (possibly ""), or
-- nil and an error. A decoder hands back a bounded batch per call
-- and says `pending` while it still holds input it has not
-- expanded; that is drained with `update("")` before any more input
-- goes in, so memory stays bounded however far the input expands.
-- `finish` runs once, at the end of the source, when nothing is
-- pending, and so returns only the codec's small tail.
local function step(self: TransformReader): string | nil, string
  local codec = self.codec
  if holds_output(codec) then return codec:update("") end
  if self.at_eof then
    self.finished = true
    return codec:finish()
  end
  local chunk, trouble = self.source:read(chunk_size)
  if chunk == nil then
    if trouble ~= "" then return nil, trouble end
    self.at_eof = true
    return "", ""
  end
  return codec:update(chunk)
end

function TransformReader:read(max_bytes?: integer): string | nil, string
  if self.failed then return nil, self.failed end
  if self.closed then return nil, closed_reader end
  while self.at > #self.batch and not self.finished do
    local out, trouble = step(self)
    if out == nil then
      self.failed = trouble ~= "" and trouble or "stream: codec failed"
      self.batch, self.at = "", 1
      return nil, self.failed
    end
    self.batch, self.at = out, 1
  end
  local batch, at = self.batch, self.at
  if at > #batch then return nil, "" end
  local want = max_bytes or chunk_size
  local avail = #batch - at + 1
  if want >= avail then
    local piece = at == 1 and batch or batch:sub(at)
    self.batch, self.at = "", 1
    return piece, ""
  end
  self.at = at + want
  return batch:sub(at, at + want - 1), ""
end

function TransformReader:close(): boolean, string
  if self.closed then return true, "" end
  self.closed = true
  self.batch, self.at = "", 1
  return self.source:close()
end

--- A Reader that pipes another Reader through a [`Stream.Transform`]:
--- `reader`'s chunks go through `codec:update`, and `codec:finish` is
--- called once, at `reader`'s end of file, for whatever the codec was
--- still holding. A codec or `reader` error ends it, stickily.
function Stream.transform(reader: Stream.Reader, codec: Stream.Transform): Stream.Reader
  local r: TransformReader = setmetatable({ source = reader, codec = codec, batch = "", at = 1,
    at_eof = false, finished = false, closed = false }, transform_reader_mt)
  return r
end

local record LimitReader is Stream.Reader
  source: Stream.Reader
  left: integer
  closed: boolean
  read: function(LimitReader, max_bytes?: integer): string | nil, string
  close: function(LimitReader): boolean, string
end

local limit_reader_mt: metatable<LimitReader> = { __index = LimitReader }

function LimitReader:read(max_bytes?: integer): string | nil, string
  if self.closed then return nil, closed_reader end
  if self.left <= 0 then return nil, "" end
  local want = max_bytes or chunk_size
  if want > self.left then want = self.left end
  local chunk, trouble = self.source:read(want)
  if chunk == nil then return nil, trouble end
  self.left = self.left - #chunk
  return chunk, ""
end

function LimitReader:close(): boolean, string
  self.closed = true
  return true, ""
end

--- A Reader that yields at most `n` bytes of `reader`, then ends,
--- however much `reader` still has. Closing it does not close `reader`,
--- since the usual reason for a limit is more of `reader` still to come.
function Stream.limit(reader: Stream.Reader, n: integer): Stream.Reader
  local r: LimitReader = setmetatable({ source = reader, left = n, closed = false },
    limit_reader_mt)
  return r
end

local record PrependReader is Stream.Reader
  prefix: string
  source: Stream.Reader
  at: integer
  closed: boolean
  read: function(PrependReader, max_bytes?: integer): string | nil, string
  close: function(PrependReader): boolean, string
end

local prepend_reader_mt: metatable<PrependReader> = { __index = PrependReader }

function PrependReader:read(max_bytes?: integer): string | nil, string
  if self.closed then return nil, closed_reader end
  local prefix, at = self.prefix, self.at
  if at <= #prefix then
    local want = max_bytes or (#prefix - at + 1)
    if want <= 0 then return nil, "" end
    local chunk = prefix:sub(at, at + want - 1)
    self.at = at + #chunk
    return chunk, ""
  end
  return self.source:read(max_bytes)
end

function PrependReader:close(): boolean, string
  if self.closed then return true, "" end
  self.closed = true
  return self.source:close()
end

--- A Reader that yields `prefix` first and then whatever `reader` has:
--- bytes already read from `reader` put back, so a caller can look at the
--- start of a stream (to tell its format) without losing them. Closing it
--- closes `reader`. It cannot `skip`.
function Stream.prepend(prefix: string, reader: Stream.Reader): Stream.Reader
  local r: PrependReader = setmetatable({ prefix = prefix, source = reader, at = 1,
    closed = false }, prepend_reader_mt)
  return r
end

--- Reads up to `n` bytes: all of them, or what is left when the stream
--- ends first, answered with "". So "" is a clean end of the stream and
--- fewer than `n` bytes are a truncated one; nil and why when `reader`
--- fails, with the bytes already read dropped.
---
---     local head, why = Stream.read_up_to(reader, 4)
---     assert(head, why)
---     if #head < 4 then print("shorter than a header") end
function Stream.read_up_to(reader: Stream.Reader, n: integer): string | nil, string
  if n <= 0 then return "", "" end
  local first, trouble = reader:read(n)
  if first == nil then
    if trouble ~= "" then return nil, trouble end
    return "", ""
  end
  if #first >= n then return first, "" end
  local parts: {string} = { first }
  local got = #first
  while got < n do
    local chunk, rtrouble = reader:read(n - got)
    if chunk == nil then
      if rtrouble ~= "" then return nil, rtrouble end
      break
    end
    parts[#parts + 1] = chunk
    got = got + #chunk
  end
  return table.concat(parts), ""
end

--- Reads exactly `n` bytes, or nil and an error when the stream ends
--- first.
function Stream.read_exact(reader: Stream.Reader, n: integer): string | nil, string
  local data, trouble = Stream.read_up_to(reader, n)
  if data == nil then return nil, trouble end
  if #data < n then
    return refuse("truncated: wanted " .. String.counted(n, "byte") ..
        ", got " .. tostring(#data))
  end
  return data, ""
end

--- Moves `reader` forward `n` bytes: with its `skip` when it has one,
--- by reading and discarding otherwise. Fails when the stream ends
--- first.
function Stream.skip(reader: Stream.Reader, n: integer): boolean, string
  if n <= 0 then return true, "" end
  if reader.skip ~= nil then return reader:skip(n) end
  local left = n
  while left > 0 do
    local want = left
    if want > chunk_size then want = chunk_size end
    local chunk, trouble = reader:read(want)
    if chunk == nil then
      if trouble ~= "" then return false, trouble end
      return false, "stream: truncated: skipping " .. String.counted(n, "byte")
    end
    left = left - #chunk
  end
  return true, ""
end

--- Reads a Reader to its end of file and returns everything as one
--- string. For bounded, whole-file cases; a streaming caller reads
--- [`Reader.read`] in a loop instead, or `copy`s to a Writer.
function Stream.read_all(reader: Stream.Reader): string | nil, string
  local parts: {string} = {}
  while true do
    local chunk, trouble = reader:read(chunk_size)
    if chunk == nil then
      if trouble ~= "" then return nil, trouble end
      return table.concat(parts), ""
    end
    parts[#parts + 1] = chunk
  end
end

local record StickyWriter is Stream.Sticky
  writer: Stream.Writer
  name: string
  closed: boolean
  failed: string
  put: function(StickyWriter, data: string): boolean, string
  fail: function(StickyWriter, trouble: string): boolean, string
  usable: function(StickyWriter): boolean, string
  close: function(StickyWriter, trailer: string): boolean, string
  abort: function(StickyWriter): boolean, string
end

local sticky_writer_mt: metatable<StickyWriter> = { __index = StickyWriter }

function StickyWriter:fail(trouble: string): boolean, string
  if self.failed == nil then
    self.failed = trouble ~= "" and trouble or self.name .. ": write failed"
    local _, _ = self.writer:abort()
  end
  return false, self.failed
end

function StickyWriter:put(data: string): boolean, string
  local ok, trouble = self.writer:write(data)
  if not ok then return self:fail(trouble) end
  return true, ""
end

function StickyWriter:usable(): boolean, string
  if self.failed then return false, self.failed end
  if self.closed then return false, self.name .. ": the writer is closed" end
  return true, ""
end

function StickyWriter:close(trailer: string): boolean, string
  if self.failed then return false, self.failed end
  if self.closed then return true, "" end
  self.closed = true
  local ok, trouble = self:put(trailer)
  if not ok then return false, trouble end
  ok, trouble = self.writer:close()
  if not ok then
    self.failed = trouble
    return false, trouble
  end
  return true, ""
end

function StickyWriter:abort(): boolean, string
  if self.closed or self.failed then return true, "" end
  self.closed = true
  return self.writer:abort()
end

--- The sticky failure [`cosmic.tar`] and [`cosmic.zip`] keep over the
--- Writer an archive goes to: the first write that fails aborts `w`,
--- and every later write, `close` included, answers that failure;
--- `name` prefixes the messages it makes itself.
function Stream.sticky(w: Stream.Writer, name: string): Stream.Sticky
  local s: StickyWriter = setmetatable({ writer = w, name = name, closed = false }, sticky_writer_mt)
  return s
end

local default_line_limit <const> = 1 << 20

local record LineReader is Stream.Lines
  source: Stream.Reader
  limit: integer
  -- `chunk` is the last one read, given out from `at`; `parts` holds
  -- the pieces of a line no chunk has ended yet, `held` bytes of them,
  -- joined once its "\n" comes, so a line spread over many small
  -- chunks costs linear time.
  chunk: string
  at: integer
  parts: {string}
  held: integer
  ended: boolean
  failed: string
  -- Set once `rest` has given the stream away.
  rested: boolean
  read: function(LineReader): string | nil, string
  each: function(LineReader): function(): string
  failure: function(LineReader): string
  rest: function(LineReader): Stream.Reader
end

local line_reader_mt: metatable<LineReader> = { __index = LineReader }

local function too_long(self: LineReader): string
  return "stream: a line is longer than " .. String.counted(self.limit, "byte")
end

-- Ends the lines with `why`, which every later read answers too.
local function fail(self: LineReader, why: string): nil, string
  self.failed = why
  self.chunk, self.at, self.parts, self.held = "", 1, {}, 0
  return nil, why
end

local rested <const> = "stream: these lines ended at `rest`; read the Reader it gave"

function LineReader:read(): string | nil, string
  if self.rested then error(rested, 2) end
  if self.failed ~= "" then return nil, self.failed end
  local limit = self.limit
  while true do
    local chunk, at = self.chunk, self.at
    local newline = chunk:find("\n", at, true)
    if newline ~= nil then
      if self.held + newline - at > limit then return fail(self, too_long(self)) end
      local line = chunk:sub(at, newline - 1)
      self.at = newline + 1
      if self.held > 0 then
        self.parts[#self.parts + 1] = line
        line = table.concat(self.parts)
        self.parts, self.held = {}, 0
      end
      return line, ""
    end
    if at <= #chunk then
      self.held = self.held + #chunk - at + 1
      if self.held > limit then return fail(self, too_long(self)) end
      self.parts[#self.parts + 1] = at == 1 and chunk or chunk:sub(at)
    end
    self.chunk, self.at = "", 1
    if self.ended then
      if self.held == 0 then return nil, "" end
      local line = table.concat(self.parts)
      self.parts, self.held = {}, 0
      return line, ""
    end
    -- A Reader answers a non-empty chunk or nil, so each round moves.
    local read, trouble = self.source:read(chunk_size)
    if read == nil then
      if trouble ~= "" then return fail(self, trouble) end
      self.ended = true
    else
      self.chunk = read
    end
  end
end

function LineReader:each(): function(): string
  if self.rested then error(rested, 2) end
  return function(): string
    local line, _ = self:read()
    return line
  end
end

function LineReader:failure(): string
  return self.failed
end

-- What `rest` gives once the Reader has nothing more to read through:
-- `why` on every read ("" for the end), and the Reader closed on close.
local record SpentReader is Stream.Reader
  source: Stream.Reader
  why: string
  closed: boolean
  read: function(SpentReader, max_bytes?: integer): string | nil, string
  close: function(SpentReader): boolean, string
end

local spent_reader_mt: metatable<SpentReader> = { __index = SpentReader }

function SpentReader:read(_max_bytes?: integer): string | nil, string
  if self.closed then return nil, closed_reader end
  return nil, self.why
end

function SpentReader:close(): boolean, string
  if self.closed then return true, "" end
  self.closed = true
  return self.source:close()
end

function LineReader:rest(): Stream.Reader
  if self.rested then error(rested, 2) end
  self.rested = true
  -- `parts` is empty after a read that returned, but holds the start of
  -- a line when the Reader raised in the middle of one.
  local ahead = table.concat(self.parts) .. self.chunk:sub(self.at)
  self.chunk, self.at, self.parts, self.held = "", 1, {}, 0
  if self.failed ~= "" or self.ended then
    local spent: SpentReader = setmetatable({ source = self.source, why = self.failed,
      closed = false }, spent_reader_mt)
    return Stream.prepend(ahead, spent)
  end
  return Stream.prepend(ahead, self.source)
end

--- The lines of `reader`, read a chunk at a time: each piece of it
--- ending in "\n", without the "\n", and the piece after the last "\n"
--- when that is not empty, so "a\nb\n" and "a\nb" are both two lines.
--- A "\r" before the "\n" stays on its line, as [`String.lines`] keeps
--- it; unlike [`String.lines`], text ending in "\n" has no empty last
--- line, and "" has no lines at all. A line longer than
--- `max_bytes` bytes (1 MiB by default) fails rather than grow without
--- bound; a `max_bytes` that is no integer of at least 1 raises.
--- `reader` is not closed.
---
--- The lines read `reader` ahead, a chunk at a time, and hold what they
--- read past the last line given: `reader` itself has moved past it. A
--- protocol that turns from lines to bytes (a head, then a body of a
--- stated length) reads the bytes from [`Lines.rest`], never from
--- `reader`, where a body already read ahead would never come and a
--- read for it would wait for good.
---
---     local reader = assert(Stream.open("log.txt"))
---     local lines = Stream.lines(reader)
---     for line in lines:each() do print(line) end
---     assert(lines:failure() == "", lines:failure())
---     assert(reader:close())
function Stream.lines(reader: Stream.Reader, max_bytes?: integer): Stream.Lines
  local limit = max_bytes or default_line_limit
  if math.type(limit) ~= "integer" or limit < 1 then
    error("stream: max_bytes must be an integer of at least 1", 2)
  end
  local lines: LineReader = setmetatable({ source = reader, limit = limit,
    chunk = "", at = 1, parts = {}, held = 0, ended = false, failed = "",
    rested = false }, line_reader_mt)
  return lines
end

--- Copies `reader` to `writer` until `reader`'s end of file, and
--- returns how many bytes went across. Closes neither side: on failure
--- the caller decides whether to `abort` `writer` or `close` it. To
--- cap a copy, copy `Stream.limit(reader, max_bytes + 1)` and compare the
--- count with `max_bytes`, which tells a source that ends at it from one
--- that goes on past it.
function Stream.copy(reader: Stream.Reader, writer: Stream.Writer): integer | nil, string
  local total = 0
  while true do
    local chunk, trouble = reader:read(chunk_size)
    if chunk == nil then
      if trouble ~= "" then return nil, trouble end
      return total, ""
    end
    total = total + #chunk
    local ok, wtrouble = writer:write(chunk)
    if not ok then return nil, wtrouble end
  end
end

--- Copies exactly `n` bytes of `reader` to `writer`, and no more of
--- `reader` than that: for a body whose size a header states and a
--- reader that holds more after it. Answers `true, ""`, or `false` and
--- why: a `reader` that ends before `n` bytes (its size was not the
--- stated one), or fails, or a `writer` that does. Closes neither side.
---
---     local ok, why = Stream.copy_n(reader, writer, size)
---     if not ok then writer:abort() end
function Stream.copy_n(reader: Stream.Reader, writer: Stream.Writer, n: integer): boolean, string
  local left = n
  while left > 0 do
    local want = left
    if want > chunk_size then want = chunk_size end
    local chunk, trouble = reader:read(want)
    if chunk == nil then
      if trouble ~= "" then return false, trouble end
      return false, "stream: truncated before its stated size: wanted " ..
        String.counted(n, "byte") .. ", got " .. tostring(n - left)
    end
    local ok, wtrouble = writer:write(chunk)
    if not ok then return false, wtrouble end
    left = left - #chunk
  end
  return true, ""
end

local record ToFdWriter is Stream.FdWriter
  fd: integer
  options: Stream.FdOptions
  closed: boolean
  failed: string
  went: integer
  write: function(ToFdWriter, data: string): boolean, string
  written: function(ToFdWriter): integer
  close: function(ToFdWriter): boolean, string
  abort: function(ToFdWriter): boolean, string
end

local to_fd_writer_mt: metatable<ToFdWriter> = { __index = ToFdWriter }

function ToFdWriter:write(data: string): boolean, string
  if self.closed then return false, closed_writer end
  if self.failed then return false, self.failed end
  local fd, options = self.fd, self.options
  local deadline: integer = nil
  if options.timeout_ns ~= nil then deadline = Time.monotonic_ns() + options.timeout_ns end
  local at = 0
  while at < #data do
    -- Handed in pieces, so a body of any size is not copied whole
    -- each time a descriptor that takes it in parts takes one.
    local piece = data
    if #data > chunk_size then
      piece = data:sub(at + 1, at + chunk_size)
    elseif at > 0 then
      piece = data:sub(at + 1)
    end
    local put, trouble, errno = sys.write(fd, piece)
    if put ~= nil then
      if put == 0 then
        self.failed = "stream: write made no progress"
        return false, self.failed
      end
      at = at + put
      self.went = self.went + put
    elseif options.nonblocking and (errno == sys.EAGAIN or errno == sys.EINTR) then
      local ready, why = wait_for(fd, sys.POLLOUT, options, deadline)
      if not ready then
        if resumable(why) then return false, why end
        self.failed = why
        return false, why
      end
    elseif errno == sys.EINTR then
      -- A blocking write a signal interrupted before it took a byte
      -- is tried again; one that took some has returned them.
    elseif errno == sys.EAGAIN then
      -- A descriptor the caller made non-blocking without saying so:
      -- no room now, which a later write may find.
      return false, trouble
    else
      self.failed = trouble
      return false, trouble
    end
  end
  return true, ""
end

function ToFdWriter:written(): integer
  return self.went
end

function ToFdWriter:close(): boolean, string
  self.closed = true
  return true, ""
end

ToFdWriter.abort = ToFdWriter.close

--- A Writer over an already-open descriptor. The descriptor is not
--- closed by this Writer's `close`; `abort` cannot take back what
--- already reached it. A `write` goes out whole: it writes until every
--- byte has gone, or fails. A failure is sticky, every later write
--- answering it, but for a deadline or a cancelled task, which leave
--- the Writer as it was, and for no room on a descriptor not declared
--- `nonblocking`, which a later write may find. A write a signal
--- interrupts is tried again.
---
--- Over a descriptor in non-blocking mode, `opts.nonblocking` makes a
--- write that finds no room wait for it, as [`Stream.FdOptions`] says,
--- and `opts.timeout_ns` bounds the whole call: it fails with
--- [`Poll.TIMEOUT`] having written part of `data`, which `written`
--- counts, so the caller can write the rest, or give up knowing how
--- much of it went.
---
---     local w = Stream.to_fd(fd, { nonblocking = true, timeout_ns = Time.seconds(5) })
---     local ok, why = w:write(body)
---     if not ok and why == Poll.TIMEOUT then print(w:written() .. " bytes went") end
function Stream.to_fd(fd: integer, opts?: Stream.FdOptions): Stream.FdWriter
  local w: ToFdWriter = setmetatable({ fd = fd, options = fd_options(opts, 2),
    closed = false, went = 0 }, to_fd_writer_mt)
  return w
end

local record StagedWriter is Stream.FileWriter
  staged: Fs.Staged
  write: function(StagedWriter, data: string): boolean, string
  sync: function(StagedWriter): boolean, string
  close: function(StagedWriter): boolean, string
  abort: function(StagedWriter): boolean, string
end

local staged_writer_mt: metatable<StagedWriter> = { __index = StagedWriter }

function StagedWriter:write(data: string): boolean, string
  return self.staged:write(data)
end

function StagedWriter:sync(): boolean, string
  return self.staged:sync()
end

function StagedWriter:close(): boolean, string
  return self.staged:close()
end

function StagedWriter:abort(): boolean, string
  return self.staged:abort()
end

--- A Writer over a file at `path`: bytes go to a temporary neighbor,
--- which is renamed onto `path` only when `close` succeeds, so a
--- reader of `path` never sees a partial write. A write or close
--- failure, or `abort`, leaves `path` untouched and removes the
--- temporary file. A failure names `path`, never the temporary file.
--- This is [`Fs.create`], which says more of the file.
function Stream.create(path: string, mode?: integer): Stream.FileWriter | nil, string
  local file, trouble = Fs.create(path, mode)
  if file == nil then return nil, trouble end
  -- Teal's interfaces are nominal, and cosmic.fs, a harness module, may
  -- not require this module to say that its Writer is one of ours.
  -- TODO: return the Fs.Staged itself once cosmic.fs may require
  -- cosmic.stream (see its TODO) and declares Staged a Stream.Writer.
  local w: StagedWriter = setmetatable({ staged = file }, staged_writer_mt)
  return w, ""
end

local record CollectWriter is Stream.Collector
  parts: {string}
  closed: boolean
  write: function(CollectWriter, data: string): boolean, string
  close: function(CollectWriter): boolean, string
  abort: function(CollectWriter): boolean, string
  result: function(CollectWriter): string
end

local collect_writer_mt: metatable<CollectWriter> = { __index = CollectWriter }

function CollectWriter:write(data: string): boolean, string
  if self.closed then return false, closed_writer end
  self.parts[#self.parts + 1] = data
  return true, ""
end

function CollectWriter:close(): boolean, string
  self.closed = true
  return true, ""
end

function CollectWriter:abort(): boolean, string
  self.closed = true
  self.parts = {}
  return true, ""
end

function CollectWriter:result(): string
  local whole = table.concat(self.parts)
  self.parts = { whole }
  return whole
end

--- A Writer that keeps everything written to it in memory, for a
--- caller building a small archive body it will hand elsewhere (a
--- request body, say) rather than write straight to a file. `abort`
--- drops what it holds.
function Stream.collect(): Stream.Collector
  local c: CollectWriter = setmetatable({ parts = {}, closed = false }, collect_writer_mt)
  return c
end

local record HashingWriter is Stream.Hashing
  hasher: Hash.Hasher
  closed: boolean
  result: string
  failure: string
  write: function(HashingWriter, data: string): boolean, string
  close: function(HashingWriter): boolean, string
  abort: function(HashingWriter): boolean, string
  digest: function(HashingWriter): string | nil, string
end

local hashing_writer_mt: metatable<HashingWriter> = { __index = HashingWriter }

function HashingWriter:write(data: string): boolean, string
  if self.closed or self.result ~= nil then return false, closed_writer end
  self.hasher:update(data)
  return true, ""
end

function HashingWriter:close(): boolean, string
  self.closed = true
  return true, ""
end

HashingWriter.abort = HashingWriter.close

function HashingWriter:digest(): string | nil, string
  if self.result == nil and self.failure == "" then
    self.closed = true
    local digest, digest_trouble = self.hasher:digest()
    if digest == nil then
      self.failure = digest_trouble
      return nil, digest_trouble
    end
    self.result = digest
  end
  if self.result == nil then return nil, self.failure end
  return self.result, ""
end

--- A Writer that digests what is written to it under `algorithm`,
--- for checking a body against a published digest as it streams past
--- -- `tee` it beside the Writer the body is really going to. Given a
--- `key`, it is the HMAC under that key ([`Hash.hmac_hasher`]) that
--- `digest` answers, not the plain digest.
-- TODO: once Hash.Hasher's `update` answers `"", ""` (or a thin adapter
-- stands over it), make a Hasher a Stream.Transform with `finish` as its
-- `digest`, so [`Stream.run`] and [`transform_writer`] drive it and this
-- Writer shrinks to that adapter.
function Stream.hashing(algorithm: Hash.Algorithm, key?: string): Stream.Hashing | nil, string
  local hasher, trouble: Hash.Hasher | nil, string
  if key == nil then
    hasher, trouble = Hash.hasher(algorithm)
  else
    hasher, trouble = Hash.hmac_hasher(algorithm, key)
  end
  if hasher == nil then return nil, trouble end
  local h: HashingWriter = setmetatable({ hasher = hasher, closed = false, failure = "" }, hashing_writer_mt)
  return h, ""
end

local record TeeWriter is Stream.Writer
  first: Stream.Writer
  second: Stream.Writer
  write: function(TeeWriter, data: string): boolean, string
  close: function(TeeWriter): boolean, string
  abort: function(TeeWriter): boolean, string
end

local tee_writer_mt: metatable<TeeWriter> = { __index = TeeWriter }

function TeeWriter:write(data: string): boolean, string
  local ok, trouble = self.first:write(data)
  if not ok then return false, trouble end
  return self.second:write(data)
end

function TeeWriter:close(): boolean, string
  local ok, trouble = self.first:close()
  local ok2, trouble2 = self.second:close()
  if not ok then return false, trouble end
  if not ok2 then return false, trouble2 end
  return true, ""
end

function TeeWriter:abort(): boolean, string
  local _, _ = self.first:abort()
  local _, _ = self.second:abort()
  return true, ""
end

--- A Writer that passes every chunk to both `a` and `b`, in that
--- order; `close` and `abort` go to both too.
function Stream.tee(a: Stream.Writer, b: Stream.Writer): Stream.Writer
  local w: TeeWriter = setmetatable({ first = a, second = b }, tee_writer_mt)
  return w
end

local record TransformWriter is Stream.Writer
  writer: Stream.Writer
  codec: Stream.Transform
  hold: integer
  closed: boolean
  failed: string
  -- With `hold`, one entry per write: its output, in order.
  held: {string}
  write: function(TransformWriter, data: string): boolean, string
  close: function(TransformWriter): boolean, string
  abort: function(TransformWriter): boolean, string
end

local transform_writer_mt: metatable<TransformWriter> = { __index = TransformWriter }

-- Writes `out` on, unless it is empty.
local function emit(self: TransformWriter, out: string): boolean, string
  if #out == 0 then return true, "" end
  return self.writer:write(out)
end

-- Feeds `data` to the codec and writes its output on, then keeps
-- draining while the codec says it is still holding output.
local function feed(self: TransformWriter, data: string): boolean, string
  local codec, hold = self.codec, self.hold
  local parts: {string} = {}
  while true do
    local out, trouble = codec:update(data)
    if out == nil then return false, trouble end
    if hold == 0 then
      local ok, why = emit(self, out)
      if not ok then return false, why end
    else
      parts[#parts + 1] = out
    end
    if not holds_output(codec) then break end
    data = ""
  end
  if hold == 0 then return true, "" end
  local held = self.held
  held[#held + 1] = table.concat(parts)
  -- This write went through: the oldest held write is now safe to release.
  if #held > hold then return emit(self, table.remove(held, 1)) end
  return true, ""
end

function TransformWriter:write(data: string): boolean, string
  if self.closed then return false, closed_writer end
  if self.failed then return false, self.failed end
  if self.hold > 0 and #data == 0 then return true, "" end
  local ok, trouble = feed(self, data)
  if not ok then
    self.failed, self.held = trouble, {}
    return false, trouble
  end
  return true, ""
end

function TransformWriter:abort(): boolean, string
  if self.closed then return true, "" end
  self.closed, self.held = true, {}
  return self.writer:abort()
end

function TransformWriter:close(): boolean, string
  if self.closed then
    if self.failed then return false, self.failed end
    return true, ""
  end
  self.closed = true
  if not self.failed then
    local out, trouble = self.codec:finish()
    if out == nil then
      self.failed = trouble
    else
      self.held[#self.held + 1] = out
      local ok, why = emit(self, table.concat(self.held))
      if not ok then self.failed = why end
    end
  end
  self.held = {}
  if self.failed then
    local _, _ = self.writer:abort()
    return false, self.failed
  end
  local ok, why = self.writer:close()
  if not ok then
    self.failed = why
    return false, why
  end
  return true, ""
end

--- A Writer that pipes each chunk written to it through a
--- [`Stream.Transform`] before passing it to `writer`; `close` flushes the codec's
--- last bytes with `codec:finish` and then closes `writer`, or aborts
--- `writer` when the codec or a write fails. `abort` aborts `writer`
--- without finishing the codec. A decoder's held output is drained
--- (`update("")` while `pending()`) after each write and before
--- `finish`, so each write to `writer` stays bounded however far the
--- input expands. That bound holds only without `hold`: with it, a
--- write's drained output is held and written whole, and `close`
--- commits everything held and the codec's last output in one write.
---
--- `opts.hold = n` holds back the output of the last `n` writes, so a
--- refusal that comes before `n` more writes have gone through leaves
--- `writer` untouched; see [`Stream.TransformWriterOptions`]. A codec
--- that fails (an invalid character at one write, a truncated stream at
--- `close`) then takes back what it would have let out:
---
---     local w = Stream.transform_writer(out, decoder, { hold = 1 })
---     assert(w:write(first_chunk))   -- nothing reaches `out` yet
---     assert(w:close())              -- the decoded bytes, or `out` aborted
function Stream.transform_writer(writer: Stream.Writer, codec: Stream.Transform,
                                 opts?: Stream.TransformWriterOptions): Stream.Writer
  local hold = opts ~= nil and opts.hold or 0
  if math.type(hold) ~= "integer" or hold < 0 then
    error("stream: hold must be an integer of at least 0", 2)
  end
  local w: TransformWriter = setmetatable({ writer = writer, codec = codec, hold = hold,
    closed = false, held = {} }, transform_writer_mt)
  return w
end

--- Drives `t` over the whole of `data` and answers everything it
--- produces: `t:update(data)`, `update("")` while `t` holds output
--- back, then `t:finish()`. Output that would pass `max_bytes`, when
--- given, fails naming the bound, so a small input a decoder expands
--- greatly cannot fill memory; a `max_bytes` that is not an integer of
--- at least 0 raises. `t` is finished by it, or left unfinished by a
--- failure, and is not reused.
---
---     local gz = assert(Compress.deflater("gzip"))
---     local packed = assert(Stream.run(gz, text))
function Stream.run(t: Stream.Transform, data: string, max_bytes?: integer): string | nil, string
  if max_bytes ~= nil and (math.type(max_bytes) ~= "integer" or max_bytes < 0) then
    error("stream: max_bytes must be an integer of at least 0", 2)
  end
  local parts: {string} = {}
  local total = 0
  --- Keeps `out`, or answers false when it takes the total past the bound.
  local function keep(out: string): boolean
    total = total + #out
    parts[#parts + 1] = out
    return max_bytes == nil or total <= max_bytes
  end
  local function too_much(): nil, string
    return refuse("output is larger than " .. String.counted(max_bytes, "byte"))
  end
  local out, trouble = t:update(data)
  while true do
    if out == nil then return nil, trouble end
    if not keep(out) then return too_much() end
    if not holds_output(t) then break end
    out, trouble = t:update("")
  end
  local last, finish_trouble = t:finish()
  if last == nil then return nil, finish_trouble end
  if not keep(last) then return too_much() end
  return table.concat(parts), ""
end

return Stream
