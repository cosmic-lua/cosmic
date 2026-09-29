--- A zip reader over a whole file or an in-memory string, walked
--- through the central directory with positional reads rather than a
--- sequential scan, plus a streaming writer. Store (method 0) and
--- deflate (method 8, through `cosmic.compress`'s `inflater`/
--- `deflater`) are the only methods understood. Zip64 is read and
--- written wherever an archive needs it: on the end-of-central-
--- directory record (more than 65535 entries, or a central directory
--- at or past the 4 GiB mark) and in each entry's extra field (a size
--- or a local header offset at or past 4 GiB).

local Fs = require("cosmic.fs")
local sys = require("cosmic.sys")
local Compress = require("cosmic.compress")
local Stream = require("cosmic.stream")

-- TODO: share one plural helper with build.plural once the library has an
-- internal Teal module to hold it: cosmic.* cannot require build.plural.
local function counted(n: integer, singular: string, several?: string): string
  return n .. " " .. (n == 1 and singular or several or singular .. "s")
end

local record Zip
  enum Kind
    "file"
    "dir"
    --- A Unix symlink (an entry whose external attributes say
    --- S_IFLNK); its body is the target, also given as `linkpath`.
    "symlink"
  end

  record Entry
    path: string
    kind: Kind
    --- The uncompressed size.
    size: integer
    compressed_size: integer
    -- TODO: EntryOptions.method is a Zip.Method name and this is zip's
    -- number, so a reader cannot hand an entry's method back to
    -- add_file. Answer a Zip.Method here too once the enum can say
    -- "a method this reader cannot open" (listing such an entry works
    -- today; only opening it fails), keeping the number beside it.

    --- 0 for stored, 8 for deflated; nothing else is understood.
    method: integer
    crc32: integer
    --- The permission bits from the entry's external attributes, when
    --- it was made by a Unix zip tool; 0 otherwise.
    mode: integer
    mtime: integer
    --- A symlink's target; "" otherwise.
    linkpath: string
    --- Where the entry's local file header starts in the file.
    offset: integer
    --- This entry's uncompressed body. Verifies the CRC32 as it reads
    --- the last byte, failing there on a mismatch, and fails as soon
    --- as the body runs past its recorded size. Fails once the
    --- Reader it came from is closed.
    open: function(Entry): Stream.Reader | nil, string
  end

  record Reader
    --- Every entry, in central directory order: built on the first
    --- call, which must come before `close`, and kept for later ones.
    entries: function(Reader): {Entry}
    --- The next entry in central directory order, read straight off
    --- the directory, so walking an archive of any size holds one
    --- entry at a time; nil and `""` after the last. Independent of
    --- `entries`.
    next: function(Reader): Entry | nil, string
    close: function(Reader): boolean, string
  end

  --- How `add_file` stores an entry's bytes: "deflate" compresses them
  --- (zip's method 8), "store" keeps them as they are (method 0).
  enum Method
    "deflate"
    "store"
  end

  record EntryOptions
    --- The Unix permission bits (the low 12 bits are recorded).
    --- Defaults to 0644 for a file and 0755 for a directory.
    mode: integer
    --- Unix epoch seconds; zip's own resolution is two seconds, and
    --- only 1980 through 2107 is representable -- anything outside
    --- that is clamped to its nearer end. Defaults to 0, which is
    --- clamped to 1980-01-01. Ignored when the writer is `deterministic`.
    mtime: integer
    --- "deflate" (the default) or "store".
    method: Method
    --- The body's uncompressed size, for a body given as a
    --- `Stream.Reader`; ignored for a string, whose length is its size.
    --- Optional: a streamed entry whose size is known to reach 2 GiB
    --- must say so, since its local header has to announce zip64
    --- before any of the body is read. When given, the body must turn
    --- out exactly this long, or the write fails.
    size: integer
  end

  record WriterOptions
    --- Every entry's timestamp becomes 1980-01-01 00:00:00, so the
    --- same tree zips to the same bytes.
    deterministic: boolean
    --- How many bytes precede this zip in the file it is written into
    --- (an executable it is appended to, say): every offset the zip
    --- records counts from the start of that file. 0 by default.
    offset: integer
  end

  --- Once any call fails, the underlying Stream.Writer is aborted and every
  --- later call, `close` included, returns that failure. A call after
  --- `close` fails too.
  record Writer
    --- Adds a file at `path` with `data` as its body; returns `true, ""`,
    --- or `false` and why. Refuses a path ending in `/`, which zip reads as a directory.
    --- A `Stream.Reader` body is read in chunks through the deflater
    --- and a running CRC32, so memory stays bounded however long it
    --- is: its sizes and CRC32 follow the data in a data descriptor
    --- (general-purpose bit 3) rather than the local header, so the
    --- output needs no seeking. Without `opts.size`, a streamed entry
    --- fails once it, or its compressed form, reaches 4 GiB; with
    --- `opts.size` of 2 GiB or more, it is written as zip64. The
    --- reader is read to its end but not closed.
    add_file: function(self: Writer, path: string, data: string | Stream.Reader, opts?: EntryOptions): boolean, string
    --- Adds a directory entry at `path`, to which a trailing `/` is
    --- added if missing. Returns `true, ""`, or `false` and why.
    add_dir: function(self: Writer, path: string, opts?: EntryOptions): boolean, string
    --- Writes the central directory and closes the underlying
    --- Stream.Writer, committing it. Returns `true, ""`, or `false` and why.
    close: function(self: Writer): boolean, string
    --- Abandons the archive: aborts the underlying Stream.Writer.
    abort: function(self: Writer): boolean, string
  end
end

local chunk_size <const> = 1 << 16
local LFH_SIG <const> = "PK\3\4"
local CDFH_SIG <const> = "PK\1\2"
local EOCD_SIG <const> = "PK\5\6"
local Z64_EOCD_SIG <const> = "PK\6\6"
local Z64_LOC_SIG <const> = "PK\6\7"
local U32_MAX <const> = 0xFFFFFFFF
local DESCRIPTOR_SIG <const> = "PK\7\8"
--- General-purpose bit 3: the CRC32 and sizes follow the data.
local FLAG_DESCRIPTOR <const> = 8
--- A streamed entry of at least this many bytes (as `opts.size` says)
--- is written as zip64 from its local header on.
local STREAM_ZIP64_AT <const> = 1 << 31
--- The longest symlink target read out of an entry body.
local LINK_LIMIT <const> = 4096

------------------------------------------------------------------
-- little-endian field access
------------------------------------------------------------------

local function u16(s: string, at: integer): integer
  return s:byte(at) | (s:byte(at + 1) << 8)
end

local function u32(s: string, at: integer): integer
  return s:byte(at) | (s:byte(at + 1) << 8) | (s:byte(at + 2) << 16) | (s:byte(at + 3) << 24)
end

local function u64(s: string, at: integer): integer
  return u32(s, at) | (u32(s, at + 4) << 32)
end

local function le16(n: integer): string
  return string.char(n & 0xFF, (n >> 8) & 0xFF)
end

local function le32(n: integer): string
  return string.char(n & 0xFF, (n >> 8) & 0xFF, (n >> 16) & 0xFF, (n >> 24) & 0xFF)
end

local function le64(n: integer): string
  return le32(n & 0xFFFFFFFF) .. le32((n >> 32) & 0xFFFFFFFF)
end

------------------------------------------------------------------
-- DOS date/time, Unix epoch seconds; no timezone -- both sides are UTC
------------------------------------------------------------------

-- TODO: these two copy cosmic.time's calendar, in seconds. Use
-- Time.civil for unix_to_dos; dos_to_unix reads an impossible DOS date
-- (February 31) leniently, which Time.from_civil refuses, so moving it
-- means deciding what such an entry's mtime is.

--- Days since 1970-01-01, for a proleptic Gregorian civil date. Howard
--- Hinnant's `days_from_civil`.
local function days_from_civil(y: integer, m: integer, d: integer): integer
  y = m <= 2 and y - 1 or y
  local era = (y >= 0 and y or y - 399) // 400
  local yoe = y - era * 400
  local doy = (153 * (m + (m > 2 and -3 or 9)) + 2) // 5 + d - 1
  local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
  return era * 146097 + doe - 719468
end

--- The inverse of `days_from_civil`.
local function civil_from_days(z: integer): integer, integer, integer
  z = z + 719468
  local era = (z >= 0 and z or z - 146096) // 146097
  local doe = z - era * 146097
  local yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
  local y = yoe + era * 400
  local doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
  local mp = (5 * doy + 2) // 153
  local d = doy - (153 * mp + 2) // 5 + 1
  local m = mp < 10 and mp + 3 or mp - 9
  y = m <= 2 and y + 1 or y
  return y, m, d
end

local function dos_to_unix(date: integer, time: integer): integer
  local year = ((date >> 9) & 0x7F) + 1980
  local month = (date >> 5) & 0x0F
  local day = date & 0x1F
  if month < 1 then month = 1 end
  if day < 1 then day = 1 end
  local hour = (time >> 11) & 0x1F
  local minute = (time >> 5) & 0x3F
  local second = (time & 0x1F) * 2
  return days_from_civil(year, month, day) * 86400 + hour * 3600 + minute * 60 + second
end

local function unix_to_dos(epoch: integer): integer, integer
  if epoch < 0 then epoch = 0 end
  local days = epoch // 86400
  local secs_of_day = epoch % 86400
  local y, m, d = civil_from_days(days)
  if y < 1980 then
    y, m, d, secs_of_day = 1980, 1, 1, 0
  elseif y > 2107 then
    -- the year field's seven bits end at 1980 + 127
    y, m, d, secs_of_day = 2107, 12, 31, 86399
  end
  local hour = secs_of_day // 3600
  local minute = (secs_of_day % 3600) // 60
  local second = secs_of_day % 60
  local date = ((y - 1980) << 9) | (m << 5) | d
  local time = (hour << 11) | (minute << 5) | (second // 2)
  return date, time
end

------------------------------------------------------------------
-- reading
------------------------------------------------------------------

local type Pread = function(integer, integer): string | nil, string

--- The end-of-central-directory record's offset: the earliest
--- signature in the file's last 64 KiB whose comment length runs
--- exactly to the end of the file -- so a comment that itself holds
--- a forged record is not mistaken for the real one -- or, failing
--- that, the last signature found.
local function find_eocd(size: integer, pread: Pread): integer | nil, string
  local window = size < 65557 and size or 65557
  local start = size - window
  local chunk, trouble = pread(start, window)
  if chunk == nil then return nil, trouble end
  local last: integer
  local exact: integer
  local from = 1
  while true do
    local i = chunk:find(EOCD_SIG, from, true)
    if i == nil or i > #chunk - 21 then break end
    last = i
    if exact == nil and i + 21 + u16(chunk, i + 20) == #chunk then exact = i end
    from = i + 1
  end
  local found = exact or last
  if found == nil then return nil, "zip: end of central directory record not found" end
  return start + found - 1, ""
end

--- `usize`, `csize` and `local_offset` from a central directory
--- entry's extra field, replaced by the zip64 (id 1) extra field's
--- 8-byte values wherever the 32-bit field was the 0xFFFFFFFF sentinel.
local function apply_zip64_extra(extra: string, usize: integer, csize: integer,
    local_offset: integer): integer, integer, integer
  local at = 1
  while at + 3 <= #extra do
    local id = u16(extra, at)
    local sz = u16(extra, at + 2)
    if id == 1 then
      local data = extra:sub(at + 4, at + 4 + sz - 1)
      local p = 1
      if usize == U32_MAX and p + 7 <= #data then usize = u64(data, p); p = p + 8 end
      if csize == U32_MAX and p + 7 <= #data then csize = u64(data, p); p = p + 8 end
      if local_offset == U32_MAX and p + 7 <= #data then
        local_offset = u64(data, p)
        p = p + 8
      end
      return usize, csize, local_offset
    end
    at = at + 4 + sz
  end
  return usize, csize, local_offset
end

--- A Reader over `left` bytes at `pos` in the file, read through
--- `pread` in chunks -- so an entry can be opened directly, at any
--- offset, without walking whatever came before it. `held`, when set,
--- is the start of those bytes, already read along with the local
--- header. Its methods live on a shared metatable.
local record Span is Stream.Reader
  pread: Pread
  pos: integer
  left: integer
  held: string
  failed: string
end

local Span_methods: {string:any} = {}
local span_mt: metatable<Span> = { __index = Span_methods }

Span_methods.read = function(self: Span, max: integer): string | nil, string
  if self.failed then return nil, self.failed end
  local left = self.left
  if left <= 0 then return nil, "" end
  local want = max or chunk_size
  if want > left then want = left end
  local chunk: string
  local held = self.held
  if held ~= nil then
    if want >= #held then
      chunk, self.held = held, nil
    else
      chunk, self.held = held:sub(1, want), held:sub(want + 1)
    end
  else
    local got, trouble = self.pread(self.pos, want)
    if got == nil then
      self.failed = trouble
      return nil, trouble
    end
    if #got == 0 then
      self.failed = "zip: entry body runs past the end of the file"
      return nil, self.failed
    end
    chunk = got
  end
  self.pos = self.pos + #chunk
  self.left = left - #chunk
  return chunk, ""
end

Span_methods.close = function(self: Span): boolean, string
  self.left = 0
  self.held = nil
  return true, ""
end

--- Wraps `inner`, accumulating a CRC32 as it is read and comparing it
--- against `crc` at end of file; fails the moment more than `size`
--- bytes arrive, so a body lying about its size is never expanded
--- much past it.
local record Checked is Stream.Reader
  inner: Stream.Reader
  crc: integer
  size: integer
  seen: integer
  state: integer
  failed: string
end

local Checked_methods: {string:any} = {}
local checked_mt: metatable<Checked> = { __index = Checked_methods }

Checked_methods.read = function(self: Checked, max: integer): string | nil, string
  if self.failed then return nil, self.failed end
  local chunk, trouble = self.inner:read(max)
  if chunk == nil then
    if trouble ~= "" then
      self.failed = trouble
    elseif self.seen ~= self.size then
      self.failed = "zip: size mismatch: " .. counted(self.seen, "byte") .. ", recorded " ..
        counted(self.size, "byte")
    elseif (self.state or 0) ~= self.crc then
      self.failed = "zip: crc32 mismatch"
    else
      return nil, ""
    end
    return nil, self.failed
  end
  local seen = self.seen + #chunk
  self.seen = seen
  if seen > self.size then
    self.failed = "zip: entry is larger than its recorded size of " .. counted(self.size, "byte")
    return nil, self.failed
  end
  self.state = Compress.crc32(chunk, self.state)
  return chunk, ""
end

Checked_methods.close = function(self: Checked): boolean, string
  return self.inner:close()
end

--- How much of a small entry's body is read in the same `pread` as its
--- local header, on the guess that its local extra field is no longer
--- than this plus its central one.
local EXTRA_SLACK <const> = 64
--- The largest compressed body read along with its local header.
local HELD_LIMIT <const> = 1 << 16

--- An entry's `open`, through `pread`: seeks past its local header
--- (whose extra field length can differ from the central
--- directory's) to its compressed body, decompresses it when needed,
--- and checks its CRC32. Every field it needs is on the entry itself,
--- so one of these serves a whole reader. A small body comes in the
--- same read as the header.
local function open_entry(pread: Pread, e: Zip.Entry): Stream.Reader | nil, string
  local csize = e.compressed_size
  local guess = 30
  if csize <= HELD_LIMIT then guess = 30 + #e.path + EXTRA_SLACK + csize end
  local header, trouble = pread(e.offset, guess)
  if header == nil then return nil, trouble end
  if #header < 30 or header:sub(1, 4) ~= LFH_SIG then return nil, "zip: bad local file header" end
  local skip = 30 + u16(header, 27) + u16(header, 29)
  local held: string
  if #header > skip then
    held = header:sub(skip + 1, skip + csize)
    if held == "" then held = nil end
  end
  local raw: Span = setmetatable({
    pread = pread, pos = e.offset + skip, left = csize, held = held,
  }, span_mt)
  local body: Stream.Reader
  local method = e.method
  if method == 0 then
    body = raw
  elseif method == 8 then
    local inflater, itrouble = Compress.inflater("raw")
    if inflater == nil then return nil, itrouble end
    body = Stream.transform(raw, inflater)
  else
    return nil, "zip: unsupported compression method " .. tostring(method)
  end
  local checked: Checked = setmetatable({
    inner = body, crc = e.crc32, size = e.size, seen = 0,
  }, checked_mt)
  return checked, ""
end

local S_IFMT <const> = 0xF000
local S_IFDIR <const> = 0x4000
local S_IFREG <const> = 0x8000
local S_IFLNK <const> = 0xA000

--- How much of the central directory is read at a time.
local CD_WINDOW <const> = 1 << 16

--- A position in the central directory, which is read `CD_WINDOW`
--- bytes at a time rather than all at once.
local record Cursor
  pread: Pread
  --- The window, and the index in it of the next unread byte.
  buf: string
  at: integer
  --- The file offsets just past the window, and just past the
  --- central directory.
  fill: integer
  limit: integer
  --- Where the central directory starts, before which every entry's
  --- local header and body lie.
  start: integer
end

local function cursor(pread: Pread, cd_offset: integer, cd_size: integer): Cursor
  return {
    pread = pread, buf = "", at = 1, fill = cd_offset, limit = cd_offset + cd_size, start = cd_offset,
  }
end

--- Makes sure the window holds at least `n` unread bytes.
local function need(c: Cursor, n: integer): boolean, string
  local avail = #c.buf - c.at + 1
  if avail >= n then return true, "" end
  local want = n - avail
  if want < CD_WINDOW then want = CD_WINDOW end
  local left = c.limit - c.fill
  if want > left then want = left end
  if avail + want < n then return false, "zip: malformed central directory" end
  local chunk, trouble = c.pread(c.fill, want)
  if chunk == nil then return false, trouble end
  if #chunk ~= want then return false, "zip: truncated central directory" end
  c.buf = avail > 0 and (c.buf:sub(c.at) .. chunk) or chunk
  c.at = 1
  c.fill = c.fill + want
  return true, ""
end

--- A central directory file header's fixed part, after its signature.
local CDFH_FIELDS <const> = "<I2I2I2I2I2I2I4I4I4I2I2I2I2I2I4I4"

--- What `next_record` returns for an entry it was asked only to check.
local CHECKED: Zip.Entry = { path = "", kind = "file", linkpath = "" }

--- The central directory's next entry, or nil and `""` at its end.
--- A symlink's `linkpath` is left "": its target is its body, which
--- the caller reads. With `bare`, an entry other than a symlink is
--- only checked, and `CHECKED` returned in its place.
local function next_record(c: Cursor, mt: metatable<Zip.Entry>, bare?: boolean):
    Zip.Entry | nil, string
  if c.at > #c.buf and c.fill >= c.limit then return nil, "" end
  local ok, trouble = need(c, 46)
  if not ok then return nil, trouble end
  local buf, at = c.buf, c.at
  if buf:sub(at, at + 3) ~= CDFH_SIG then return nil, "zip: malformed central directory" end
  local made_by, _version, _flags, method, mtime_dos, mdate_dos, crc, csize, usize,
    name_len, extra_len, comment_len, _disk, _internal, ext_attrs, local_offset =
    string.unpack(CDFH_FIELDS, buf, at + 4)
  local whole = 46 + name_len + extra_len + comment_len
  ok, trouble = need(c, whole)
  if not ok then return nil, trouble end
  buf, at = c.buf, c.at
  c.at = at + whole
  local name_start = at + 46
  local name_end = name_start + name_len - 1
  local nul = buf:find("\0", name_start, true)
  if nul ~= nil and nul <= name_end then
    return nil, "zip: NUL byte in an entry name"
  end
  local mode = 0
  local unix_type = 0
  if (made_by >> 8) == 3 then -- made by a Unix tool
    mode = (ext_attrs >> 16) & 0xFFF
    unix_type = (ext_attrs >> 16) & S_IFMT
  end
  local kind: Zip.Kind = "file"
  if (name_len > 0 and buf:byte(name_end) == 47) or unix_type == S_IFDIR then -- '/'
    kind = "dir"
  elseif unix_type == S_IFLNK then
    kind = "symlink"
  end
  -- `open_reader`'s first pass checks this too, so an entry with a zip64
  -- value no Lua integer holds (2^63 or more reads negative) is refused
  -- there rather than listed with a negative size.
  if extra_len > 0 and (usize == U32_MAX or csize == U32_MAX or local_offset == U32_MAX) then
    local extra = buf:sub(name_end + 1, name_end + extra_len)
    usize, csize, local_offset = apply_zip64_extra(extra, usize, csize, local_offset)
    if usize < 0 or csize < 0 or local_offset < 0 then
      return nil, "zip: a zip64 extra field's size or offset is past 2^63"
    end
  end
  -- An entry's local header (30 bytes at least) and compressed body lie
  -- before the central directory: APPNOTE 4.3.6 puts every local
  -- header, body and data descriptor ahead of it and the zip64 end
  -- records after it, and `open_reader` has already found it inside the
  -- file. An entry that does not fit there is refused on
  -- `open_reader`'s first pass, rather than listed and failing only when
  -- opened (through `Zip.open`, an offset near 2^63 fails as pread's
  -- bare "Invalid argument"). Written as subtractions, which cannot
  -- overflow for values already known not to be negative.
  local cd_offset = c.start
  if local_offset > cd_offset - 30 or csize > cd_offset - 30 - local_offset then
    return nil, "zip: entry " .. buf:sub(name_start, name_end) .. " (offset " ..
      tostring(local_offset) .. ", " .. counted(csize, "compressed byte") .. ") runs past " ..
      "the start of the central directory at " .. tostring(cd_offset)
  end
  if bare and kind ~= "symlink" then return CHECKED, "" end
  local name = buf:sub(name_start, name_end)
  local entry: Zip.Entry = setmetatable({
    path = name,
    kind = kind,
    size = usize,
    compressed_size = csize,
    method = method,
    crc32 = crc,
    mode = mode,
    mtime = dos_to_unix(mdate_dos, mtime_dos),
    linkpath = "",
    offset = local_offset,
  }, mt)
  return entry, ""
end

--- A symlink entry's target: its (small) body.
local function read_link(entry: Zip.Entry): string | nil, string
  if entry.size > LINK_LIMIT then
    return nil, "zip: symlink " .. entry.path .. " has a " .. tostring(entry.size) ..
      "-byte target"
  end
  local body, trouble = entry:open()
  if body == nil then return nil, trouble end
  local target, rtrouble = Stream.read_all(body)
  if target == nil then return nil, entry.path .. ": " .. rtrouble end
  if target:find("\0", 1, true) ~= nil then
    return nil, "zip: NUL byte in the target of symlink " .. entry.path
  end
  return target, ""
end

local function open_reader(size: integer, pread: Pread, closer: function(): boolean, string):
    Zip.Reader | nil, string
  local eocd_off, trouble = find_eocd(size, pread)
  if eocd_off == nil then return nil, trouble end
  local fixed, ftrouble = pread(eocd_off, 22)
  if fixed == nil then return nil, ftrouble end
  local total = u16(fixed, 11)
  local cd_size = u32(fixed, 13)
  local cd_offset = u32(fixed, 17)
  -- The central directory must end before whichever end record
  -- follows it.
  local cd_limit = eocd_off
  if eocd_off >= 20 then
    local loc, loc_trouble = pread(eocd_off - 20, 20)
    if loc == nil then return nil, loc_trouble end
    if #loc == 20 and loc:sub(1, 4) == Z64_LOC_SIG then
      local z64_off = u64(loc, 9)
      if z64_off < 0 or z64_off > eocd_off - 20 - 56 then
        return nil, "zip: zip64 end of central directory lies outside the file"
      end
      local rec, rec_trouble = pread(z64_off, 56)
      if rec == nil then return nil, rec_trouble end
      if #rec ~= 56 or rec:sub(1, 4) ~= Z64_EOCD_SIG then
        return nil, "zip: bad zip64 end of central directory record"
      end
      total = u64(rec, 33)
      cd_size = u64(rec, 41)
      cd_offset = u64(rec, 49)
      cd_limit = z64_off
    end
  end
  if cd_offset < 0 or cd_size < 0 or cd_offset + cd_size > cd_limit or
      cd_offset + cd_size < cd_offset then
    return nil, "zip: central directory (offset " .. tostring(cd_offset) .. ", " ..
      counted(cd_size, "byte") .. ") lies outside the file"
  end
  if total < 0 or total > cd_size // 46 then
    return nil, "zip: " .. counted(total, "entry", "entries") .. " cannot fit a " .. tostring(cd_size) ..
      "-byte central directory"
  end

  -- One `open` serves every entry this reader makes, through their
  -- shared metatable.
  local entry_mt: metatable<Zip.Entry> = {
    __index = {
      open = function(e: Zip.Entry): Stream.Reader | nil, string
        return open_entry(pread, e)
      end,
    },
  }

  -- One pass over the whole directory up front, keeping no entry, so
  -- a malformed one, or a count that disagrees with the end record,
  -- fails here rather than partway through a walk. Symlink targets
  -- are read now too -- they are few -- and kept by their place in
  -- the directory.
  local links: {integer:string} = {}
  local count = 0
  local check = cursor(pread, cd_offset, cd_size)
  while true do
    local entry, etrouble = next_record(check, entry_mt, true)
    if entry == nil then
      if etrouble ~= "" then return nil, etrouble end
      break
    end
    count = count + 1
    if entry.kind == "symlink" then
      local target, ltrouble = read_link(entry)
      if target == nil then return nil, ltrouble end
      links[count] = target
    end
  end
  if count ~= total then
    return nil, "zip: central directory holds " .. counted(count, "entry", "entries") ..
      ", but the end record says " .. tostring(total)
  end

  local closed = false
  local walk = cursor(pread, cd_offset, cd_size)
  local walked = 0
  local listed: {Zip.Entry}
  local zr: Zip.Reader = {}
  zr.next = function(_self: Zip.Reader): Zip.Entry | nil, string
    if closed then return nil, "zip: reader is closed" end
    local entry, etrouble = next_record(walk, entry_mt)
    if entry == nil then return nil, etrouble end
    walked = walked + 1
    local target = links[walked]
    if target ~= nil then entry.linkpath = target end
    return entry, ""
  end
  zr.entries = function(_self: Zip.Reader): {Zip.Entry}
    if listed ~= nil then return listed end
    local all: {Zip.Entry} = {}
    local c = cursor(pread, cd_offset, cd_size)
    while true do
      -- TODO: answer `{Zip.Entry} | nil, string` from `entries`, so a
      -- malformed or closed reader's list is refused rather than cut
      -- short; a public signature change every caller follows.
      local entry, _ = next_record(c, entry_mt)
      if entry == nil then break end
      all[#all + 1] = entry
      local target = links[#all]
      if target ~= nil then entry.linkpath = target end
    end
    -- Only a complete list is kept, so one cut short (by a closed
    -- reader) is not what every later call gets.
    if #all == count then listed = all end
    return all
  end
  zr.close = function(_self: Zip.Reader): boolean, string
    if closed then return true, "" end
    closed = true
    return closer()
  end
  return zr, ""
end

--- A reader over the zip file at `path`, walked with positional reads
--- rather than loaded whole into memory.
function Zip.open(path: string): Zip.Reader | nil, string
  local fd, trouble = Fs.open_read(path)
  if fd == nil then return nil, trouble end
  -- The length of the file `fd` opened, so it is the same file every
  -- read goes to.
  local st, strouble = sys.fstat(fd)
  if st == nil then
    local _, _ = Fs.close(fd)
    return nil, "zip: " .. path .. ": " .. strouble
  end
  local closed = false
  local pread: Pread = function(offset: integer, count: integer): string | nil, string
    -- Once closed, `fd` may already name some other file.
    if closed then return nil, "zip: " .. path .. ": reader is closed" end
    local data, ptrouble = sys.pread(fd, count, offset)
    if data == nil then return nil, ptrouble end
    return data, ""
  end
  local reader, otrouble = open_reader(st.size, pread, function(): boolean, string
    closed = true
    return Fs.close(fd)
  end)
  if reader == nil then
    closed = true
    local _, _ = Fs.close(fd)
    return nil, otrouble
  end
  return reader, ""
end

--- A reader over a zip already in memory as `data`.
function Zip.open_string(data: string): Zip.Reader | nil, string
  local closed = false
  local pread: Pread = function(offset: integer, count: integer): string | nil, string
    if closed then return nil, "zip: reader is closed" end
    if offset >= #data then return "", "" end
    return data:sub(offset + 1, offset + count), ""
  end
  return open_reader(#data, pread, function(): boolean, string
    closed = true
    return true, ""
  end)
end

------------------------------------------------------------------
-- writing
------------------------------------------------------------------

--- The "version made by" field: host system 3 (Unix) in the high byte,
--- specification version 2.0 in the low.
local UNIX_MADE_BY <const> = (3 << 8) | 20
local DOS_DIR_ATTR <const> = 0x10

local function zip64_extra(values: {integer}): string
  if #values == 0 then return "" end
  local parts: {string} = { le16(1), le16(8 * #values) }
  for _, v in ipairs(values) do parts[#parts + 1] = le64(v) end
  return table.concat(parts)
end

--- A local file header. Sizes that do not fit 32 bits become the
--- 0xFFFFFFFF sentinel, with both real sizes in a zip64 extra field
--- (a local header's zip64 field always holds both).
local function local_header(name: string, method: integer, dos_time: integer, dos_date: integer,
    crc: integer, csize: integer, usize: integer, flags?: integer, wide?: boolean): string
  local extra = ""
  local version = 20
  if wide or usize >= U32_MAX or csize >= U32_MAX then
    extra = zip64_extra({ usize, csize })
    -- Whenever the field is there, the fields it stands for are the
    -- sentinel (a streamed entry's, which announces zip64 before it
    -- knows either size, included).
    usize, csize, version = U32_MAX, U32_MAX, 45
  end
  return LFH_SIG .. le16(version) .. le16(flags or 0) .. le16(method) .. le16(dos_time) ..
    le16(dos_date) .. le32(crc) .. le32(csize) .. le32(usize) .. le16(#name) ..
    le16(#extra) .. name .. extra
end

--- A central directory header. Each of the uncompressed size, the
--- compressed size and the local header offset that does not fit 32
--- bits becomes the sentinel, with its real value in the zip64 extra
--- field, in that order.
local function central_header(name: string, method: integer, dos_time: integer, dos_date: integer,
    crc: integer, csize: integer, usize: integer, ext_attrs: integer, local_offset: integer,
    flags?: integer): string
  local wide: {integer} = {}
  if usize >= U32_MAX then wide[#wide + 1] = usize; usize = U32_MAX end
  if csize >= U32_MAX then wide[#wide + 1] = csize; csize = U32_MAX end
  if local_offset >= U32_MAX then
    wide[#wide + 1] = local_offset
    local_offset = U32_MAX
  end
  local extra = zip64_extra(wide)
  local version = #wide > 0 and 45 or 20
  return CDFH_SIG .. le16(UNIX_MADE_BY) .. le16(version) .. le16(flags or 0) .. le16(method) ..
    le16(dos_time) .. le16(dos_date) .. le32(crc) .. le32(csize) .. le32(usize) ..
    le16(#name) .. le16(#extra) .. le16(0) .. le16(0) .. le16(0) .. le32(ext_attrs) ..
    le32(local_offset) .. name .. extra
end

--- A streaming writer over `w`. A string body is written with its CRC32
--- and sizes in its local header; a `Stream.Reader` body, whose CRC32
--- and sizes are known only once it is read, with them in a data
--- descriptor after it (the central directory, which the reader goes by,
--- has them either way). A reader that walks local headers forward
--- without the central directory (Java's ZipInputStream) cannot find
--- the end of a stored entry written so; knowing its sizes up front
--- would mean reading the body twice or seeking.
function Zip.writer(w: Stream.Writer, opts?: Zip.WriterOptions): Zip.Writer
  opts = opts or {}
  local deterministic = opts.deterministic or false
  local offset = opts.offset or 0
  local cd_parts: {string} = {}
  local count = 0
  local sink = Stream.sticky(w, "zip")
  local zw: Zip.Writer = {}

  local function put(data: string): boolean, string
    local ok, trouble = sink:put(data)
    if not ok then return false, trouble end
    offset = offset + #data
    return true, ""
  end

  local function write_entry(path: string, data: string, method_name: Zip.Method,
      mode: integer, mtime: integer, is_dir: boolean): boolean, string
    local usable, why = sink:usable()
    if not usable then return false, why end
    if path:find("\0", 1, true) ~= nil then return false, "zip: NUL byte in a path" end
    if #path > 0xFFFF then return false, "zip: path longer than 65535 bytes" end
    local dos_date: integer
    local dos_time: integer
    if deterministic then
      dos_date, dos_time = 0x21, 0
    else
      dos_date, dos_time = unix_to_dos(mtime)
    end
    local crc = Compress.crc32(data)
    local usize = #data
    local method: integer
    local payload: string
    if method_name == "store" or is_dir then
      method, payload = 0, data
    elseif method_name == "deflate" then
      local deflater, dtrouble = Compress.deflater("raw")
      if deflater == nil then return false, dtrouble end
      local part1, trouble = deflater:update(data)
      if part1 == nil then return false, trouble end
      local part2, ftrouble = deflater:finish()
      if part2 == nil then return false, ftrouble end
      payload = part1 .. part2
      method = 8
    else
      return false, "zip: unknown method '" .. method_name .. "'"
    end
    local csize = #payload
    local type_bits = is_dir and S_IFDIR or S_IFREG
    local ext_attrs = ((type_bits | (mode & 0xFFF)) << 16) | (is_dir and DOS_DIR_ATTR or 0)
    local local_offset = offset
    local ok, trouble = put(local_header(path, method, dos_time, dos_date, crc, csize, usize))
    if not ok then return false, trouble end
    ok, trouble = put(payload)
    if not ok then return false, trouble end
    cd_parts[#cd_parts + 1] = central_header(path, method, dos_time, dos_date, crc, csize, usize,
      ext_attrs, local_offset)
    count = count + 1
    return true, ""
  end

  local function write_streamed(path: string, body: Stream.Reader, method_name: Zip.Method,
      mode: integer, mtime: integer, hint: integer | nil): boolean, string
    local usable, why = sink:usable()
    if not usable then return false, why end
    if path:find("\0", 1, true) ~= nil then return false, "zip: NUL byte in a path" end
    if #path > 0xFFFF then return false, "zip: path longer than 65535 bytes" end
    if hint ~= nil and (math.type(hint) ~= "integer" or hint < 0) then
      return false, "zip: opts.size must be a non-negative integer"
    end
    local deflater: Compress.Stream
    local method: integer
    if method_name == "store" then
      method = 0
    elseif method_name == "deflate" then
      local made, dtrouble = Compress.deflater("raw")
      if made == nil then return false, dtrouble end
      deflater, method = made, 8
    else
      return false, "zip: unknown method '" .. method_name .. "'"
    end
    local dos_date: integer
    local dos_time: integer
    if deterministic then
      dos_date, dos_time = 0x21, 0
    else
      dos_date, dos_time = unix_to_dos(mtime)
    end
    local wide = hint ~= nil and hint >= STREAM_ZIP64_AT
    local local_offset = offset
    local ok, trouble = put(local_header(path, method, dos_time, dos_date, 0, 0, 0,
      FLAG_DESCRIPTOR, wide))
    if not ok then return false, trouble end
    local crc, usize, csize = 0, 0, 0
    local function emit(data: string): boolean, string
      if data == "" then return true, "" end
      csize = csize + #data
      if not wide and csize >= U32_MAX then
        return sink:fail("zip: " .. path .. ": a streamed entry of 4 GiB or more needs opts.size")
      end
      return put(data)
    end
    while true do
      local chunk, rtrouble = body:read(chunk_size)
      if chunk == nil then
        if rtrouble ~= "" then return sink:fail(rtrouble) end
        break
      end
      usize = usize + #chunk
      if not wide and usize >= U32_MAX then
        return sink:fail("zip: " .. path .. ": a streamed entry of 4 GiB or more needs opts.size")
      end
      crc = Compress.crc32(chunk, crc)
      if deflater ~= nil then
        local out, etrouble = deflater:update(chunk)
        if out == nil then return sink:fail(etrouble) end
        ok, trouble = emit(out)
      else
        ok, trouble = emit(chunk)
      end
      if not ok then return false, trouble end
    end
    if deflater ~= nil then
      local tail, ftrouble = deflater:finish()
      if tail == nil then return sink:fail(ftrouble) end
      ok, trouble = emit(tail)
      if not ok then return false, trouble end
    end
    if hint ~= nil and hint ~= usize then
      return sink:fail("zip: " .. path .. ": body is " .. counted(usize, "byte") .. ", not " ..
        counted(hint, "byte"))
    end
    if wide then
      ok, trouble = put(DESCRIPTOR_SIG .. le32(crc) .. le64(csize) .. le64(usize))
    else
      ok, trouble = put(DESCRIPTOR_SIG .. le32(crc) .. le32(csize) .. le32(usize))
    end
    if not ok then return false, trouble end
    local ext_attrs = (S_IFREG | (mode & 0xFFF)) << 16
    cd_parts[#cd_parts + 1] = central_header(path, method, dos_time, dos_date, crc, csize, usize,
      ext_attrs, local_offset, FLAG_DESCRIPTOR)
    count = count + 1
    return true, ""
  end

  zw.add_file = function(_self: Zip.Writer, path: string, data: string | Stream.Reader,
      fopts?: Zip.EntryOptions): boolean, string
    -- A trailing `/` is what marks a directory: a file of that name
    -- would read back as one.
    if path:sub(-1) == "/" then return false, "zip: a file's path ends in /: " .. path end
    fopts = fopts or {}
    local mode = fopts.mode or 0x1a4
    local mtime = fopts.mtime or 0
    local method_name = fopts.method or "deflate"
    if data is string then
      return write_entry(path, data, method_name, mode, mtime, false)
    end
    return write_streamed(path, data, method_name, mode, mtime, fopts.size)
  end

  zw.add_dir = function(_self: Zip.Writer, path: string, fopts?: Zip.EntryOptions): boolean, string
    fopts = fopts or {}
    local mode = fopts.mode or 0x1ed
    local mtime = fopts.mtime or 0
    local dirpath = path:sub(-1) == "/" and path or (path .. "/")
    return write_entry(dirpath, "", "store", mode, mtime, true)
  end

  zw.close = function(_self: Zip.Writer): boolean, string
    -- Closed or failed already: close answers that without writing.
    local usable, _ = sink:usable()
    if not usable then return sink:close("") end
    local cd = table.concat(cd_parts)
    local cd_offset = offset
    local cd_size = #cd
    local trailer = { cd }
    local needs_zip64 = count >= 0xFFFF or cd_size >= U32_MAX or cd_offset >= U32_MAX
    if needs_zip64 then
      local zip64_eocd_offset = cd_offset + cd_size
      trailer[#trailer + 1] = Z64_EOCD_SIG .. le64(44) .. le16((3 << 8) | 45) .. le16(45) ..
        le32(0) .. le32(0) .. le64(count) .. le64(count) .. le64(cd_size) .. le64(cd_offset)
      trailer[#trailer + 1] = Z64_LOC_SIG .. le32(0) .. le64(zip64_eocd_offset) .. le32(1)
    end
    local eocd_count = needs_zip64 and 0xFFFF or count
    local eocd_cd_size = needs_zip64 and U32_MAX or cd_size
    local eocd_cd_offset = needs_zip64 and U32_MAX or cd_offset
    trailer[#trailer + 1] = EOCD_SIG .. le16(0) .. le16(0) .. le16(eocd_count) ..
      le16(eocd_count) .. le32(eocd_cd_size) .. le32(eocd_cd_offset) .. le16(0)
    cd_parts = {}
    return sink:close(table.concat(trailer))
  end

  zw.abort = function(_self: Zip.Writer): boolean, string
    return sink:abort()
  end

  return zw
end

return Zip
