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
    --- 0 for stored, 8 for deflated; nothing else is understood.
    method: integer
    crc32: integer
    --- The permission bits from the entry's external attributes, when
    --- it was made by a Unix zip tool; 0 otherwise.
    mode: integer
    mtime: integer
    --- A symlink's target; "" otherwise.
    linkpath: string
    --- This entry's uncompressed body. Verifies the CRC32 as it reads
    --- the last byte, failing there on a mismatch, and fails as soon
    --- as the body runs past its recorded size. Fails once the
    --- ZipReader it came from is closed.
    open: function(Entry): Stream.Reader | nil, string
  end

  record ZipReader
    entries: function(ZipReader): {Entry}
    close: function(ZipReader): boolean, string
  end

  record EntryOptions
    mode: integer
    --- Unix epoch seconds; zip's own resolution is two seconds, and
    --- only 1980 through 2107 is representable -- anything outside
    --- that is clamped to its nearer end.
    mtime: integer
    --- "deflate" (the default) or "store".
    method: string
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

  --- Once any call fails, the underlying Writer is aborted and every
  --- later call, `close` included, returns that failure. A call after
  --- `close` fails too.
  record ZipWriter
    add_file: function(ZipWriter, string, string, opts?: EntryOptions): boolean, string
    add_dir: function(ZipWriter, string, opts?: EntryOptions): boolean, string
    close: function(ZipWriter): boolean, string
    --- Abandons the archive: aborts the underlying Writer.
    abort: function(ZipWriter): boolean, string
  end
end

local chunk_size <const> = 1 << 16
local LFH_SIG <const> = "PK\3\4"
local CDFH_SIG <const> = "PK\1\2"
local EOCD_SIG <const> = "PK\5\6"
local Z64_EOCD_SIG <const> = "PK\6\6"
local Z64_LOC_SIG <const> = "PK\6\7"
local U32_MAX <const> = 0xFFFFFFFF
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

--- A Reader over `length` bytes starting at `offset`, read through
--- `pread` in chunks -- so an entry can be opened directly, at any
--- offset, without walking whatever came before it.
local function pread_reader(pread: Pread, offset: integer, length: integer): Stream.Reader
  local pos = offset
  local left = length
  local failed: string
  local r: Stream.Reader = {}
  r.read = function(_self: Stream.Reader, max: integer): string | nil, string
    if failed then return nil, failed end
    if left <= 0 then return nil, "" end
    local want = max or chunk_size
    if want > left then want = left end
    local chunk, trouble = pread(pos, want)
    if chunk == nil then
      failed = trouble
      return nil, trouble
    end
    if #chunk == 0 then
      failed = "zip: entry body runs past the end of the file"
      return nil, failed
    end
    pos = pos + #chunk
    left = left - #chunk
    return chunk, ""
  end
  r.close = function(_self: Stream.Reader): boolean, string
    left = 0
    return true, ""
  end
  return r
end

--- Wraps `inner`, accumulating a CRC32 as it is read and comparing it
--- against `expected_crc` at end of file; fails the moment more than
--- `expected_size` bytes arrive, so a body lying about its size is
--- never expanded much past it.
local function crc_checked_reader(inner: Stream.Reader, expected_crc: integer,
    expected_size: integer): Stream.Reader
  local state: integer = nil
  local seen = 0
  local failed: string
  local r: Stream.Reader = {}
  r.read = function(_self: Stream.Reader, max: integer): string | nil, string
    if failed then return nil, failed end
    local chunk, trouble = inner:read(max)
    if chunk == nil then
      if trouble ~= "" then
        failed = trouble
      elseif seen ~= expected_size then
        failed = "zip: size mismatch: " .. tostring(seen) .. " bytes, recorded " ..
          tostring(expected_size)
      elseif (state or 0) ~= expected_crc then
        failed = "zip: crc32 mismatch"
      else
        return nil, ""
      end
      return nil, failed
    end
    seen = seen + #chunk
    if seen > expected_size then
      failed = "zip: entry is larger than its recorded size of " .. tostring(expected_size) ..
        " bytes"
      return nil, failed
    end
    state = Compress.crc32(chunk, state)
    return chunk, ""
  end
  r.close = function(_self: Stream.Reader): boolean, string
    return inner:close()
  end
  return r
end

--- One entry's `open`: seeks past its local header (whose extra field
--- length can differ from the central directory's) to its compressed
--- body, decompresses it when needed, and checks its CRC32.
local function make_open(pread: Pread, local_offset: integer, method: integer,
    csize: integer, usize: integer, crc: integer): function(Zip.Entry): Stream.Reader | nil, string
  return function(_e: Zip.Entry): Stream.Reader | nil, string
    local header, trouble = pread(local_offset, 30)
    if header == nil then return nil, trouble end
    if header:sub(1, 4) ~= LFH_SIG then return nil, "zip: bad local file header" end
    local name_len = u16(header, 27)
    local extra_len = u16(header, 29)
    local data_off = local_offset + 30 + name_len + extra_len
    local raw = pread_reader(pread, data_off, csize)
    local body: Stream.Reader
    if method == 0 then
      body = raw
    elseif method == 8 then
      local inflater, itrouble = Compress.inflater("raw")
      if inflater == nil then return nil, itrouble end
      body = Stream.transform(raw, inflater)
    else
      return nil, "zip: unsupported compression method " .. tostring(method)
    end
    return crc_checked_reader(body, crc, usize), ""
  end
end

local S_IFMT <const> = 0xF000
local S_IFDIR <const> = 0x4000
local S_IFREG <const> = 0x8000
local S_IFLNK <const> = 0xA000

local function parse_central_directory(pread: Pread, cd: string): {Zip.Entry} | nil, string
  local entries: {Zip.Entry} = {}
  local at = 1
  while at <= #cd do
    if at + 45 > #cd or cd:sub(at, at + 3) ~= CDFH_SIG then
      return nil, "zip: malformed central directory"
    end
    local made_by = u16(cd, at + 4)
    local method = u16(cd, at + 10)
    local mtime_dos = u16(cd, at + 12)
    local mdate_dos = u16(cd, at + 14)
    local crc = u32(cd, at + 16)
    local csize = u32(cd, at + 20)
    local usize = u32(cd, at + 24)
    local name_len = u16(cd, at + 28)
    local extra_len = u16(cd, at + 30)
    local comment_len = u16(cd, at + 32)
    local ext_attrs = u32(cd, at + 38)
    local local_offset = u32(cd, at + 42)
    local name_start = at + 46
    if name_start + name_len + extra_len + comment_len - 1 > #cd then
      return nil, "zip: malformed central directory"
    end
    local name = cd:sub(name_start, name_start + name_len - 1)
    if name:find("\0", 1, true) ~= nil then
      return nil, "zip: NUL byte in an entry name"
    end
    local extra = cd:sub(name_start + name_len, name_start + name_len + extra_len - 1)
    usize, csize, local_offset = apply_zip64_extra(extra, usize, csize, local_offset)
    local mode = 0
    local unix_type = 0
    if (made_by >> 8) == 3 then -- made by a Unix tool
      mode = (ext_attrs >> 16) & 0xFFF
      unix_type = (ext_attrs >> 16) & S_IFMT
    end
    local kind: Zip.Kind = "file"
    if name:sub(-1) == "/" or unix_type == S_IFDIR then
      kind = "dir"
    elseif unix_type == S_IFLNK then
      kind = "symlink"
    end
    local entry: Zip.Entry = {
      path = name,
      kind = kind,
      size = usize,
      compressed_size = csize,
      method = method,
      crc32 = crc,
      mode = mode,
      mtime = dos_to_unix(mdate_dos, mtime_dos),
      linkpath = "",
    }
    entry.open = make_open(pread, local_offset, method, csize, usize, crc)
    entries[#entries + 1] = entry
    at = name_start + name_len + extra_len + comment_len
  end
  return entries, ""
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
    Zip.ZipReader | nil, string
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
    local loc = pread(eocd_off - 20, 20)
    if loc ~= nil and #loc == 20 and loc:sub(1, 4) == Z64_LOC_SIG then
      local z64_off = u64(loc, 9)
      if z64_off < 0 or z64_off + 56 > eocd_off - 20 then
        return nil, "zip: zip64 end of central directory lies outside the file"
      end
      local rec = pread(z64_off, 56)
      if rec == nil or #rec ~= 56 or rec:sub(1, 4) ~= Z64_EOCD_SIG then
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
      tostring(cd_size) .. " bytes) lies outside the file"
  end
  if total < 0 or total > cd_size // 46 then
    return nil, "zip: " .. tostring(total) .. " entries cannot fit a " .. tostring(cd_size) ..
      "-byte central directory"
  end
  local cd = ""
  if cd_size > 0 then
    local read_cd: string
    read_cd, trouble = pread(cd_offset, cd_size)
    if read_cd == nil then return nil, trouble end
    if #read_cd ~= cd_size then return nil, "zip: truncated central directory" end
    cd = read_cd
  end
  local entries, ptrouble = parse_central_directory(pread, cd)
  if entries == nil then return nil, ptrouble end
  if #entries ~= total then
    return nil, "zip: central directory holds " .. tostring(#entries) ..
      " entries, but the end record says " .. tostring(total)
  end
  for _, entry in ipairs(entries) do
    if entry.kind == "symlink" then
      local target, ltrouble = read_link(entry)
      if target == nil then return nil, ltrouble end
      entry.linkpath = target
    end
  end
  local closed = false
  local zr: Zip.ZipReader = {}
  zr.entries = function(_self: Zip.ZipReader): {Zip.Entry}
    return entries
  end
  zr.close = function(_self: Zip.ZipReader): boolean, string
    if closed then return true, "" end
    closed = true
    return closer()
  end
  return zr, ""
end

--- A reader over the zip file at `path`, walked with positional reads
--- rather than loaded whole into memory.
function Zip.open(path: string): Zip.ZipReader | nil, string
  local st, strouble = Fs.stat(path)
  if st == nil then return nil, strouble end
  local fd, trouble = Fs.open_read(path)
  if fd == nil then return nil, trouble end
  local closed = false
  local pread: Pread = function(offset: integer, count: integer): string | nil, string
    -- Once closed, `fd` may already name some other file.
    if closed then return nil, "zip: " .. path .. ": reader is closed" end
    local data, ptrouble = sys.pread(fd, count, offset)
    return data, ptrouble
  end
  local reader, otrouble = open_reader(st.size, pread, function(): boolean, string
    closed = true
    return Fs.close(fd)
  end)
  if reader == nil then
    closed = true
    Fs.close(fd)
    return nil, otrouble
  end
  return reader, ""
end

--- A reader over a zip already in memory as `data`.
function Zip.open_string(data: string): Zip.ZipReader | nil, string
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

--- Every entry of the zip at `path`, without keeping the reader open
--- -- so their `open` fails; use `Zip.open` to read bodies.
function Zip.list(path: string): {Zip.Entry} | nil, string
  local reader, trouble = Zip.open(path)
  if reader == nil then return nil, trouble end
  local entries = reader:entries()
  reader:close()
  return entries, ""
end

------------------------------------------------------------------
-- writing
------------------------------------------------------------------

local UNIX_MADE_BY <const> = (3 << 8) | 20 -- Unix, version 2.0
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
    crc: integer, csize: integer, usize: integer): string
  local extra = ""
  local version = 20
  if usize >= U32_MAX or csize >= U32_MAX then
    extra = zip64_extra({ usize, csize })
    usize, csize, version = U32_MAX, U32_MAX, 45
  end
  return LFH_SIG .. le16(version) .. le16(0) .. le16(method) .. le16(dos_time) ..
    le16(dos_date) .. le32(crc) .. le32(csize) .. le32(usize) .. le16(#name) ..
    le16(#extra) .. name .. extra
end

--- A central directory header. Each of the uncompressed size, the
--- compressed size and the local header offset that does not fit 32
--- bits becomes the sentinel, with its real value in the zip64 extra
--- field, in that order.
local function central_header(name: string, method: integer, dos_time: integer, dos_date: integer,
    crc: integer, csize: integer, usize: integer, ext_attrs: integer, local_offset: integer): string
  local wide: {integer} = {}
  if usize >= U32_MAX then wide[#wide + 1] = usize; usize = U32_MAX end
  if csize >= U32_MAX then wide[#wide + 1] = csize; csize = U32_MAX end
  if local_offset >= U32_MAX then
    wide[#wide + 1] = local_offset
    local_offset = U32_MAX
  end
  local extra = zip64_extra(wide)
  local version = #wide > 0 and 45 or 20
  return CDFH_SIG .. le16(UNIX_MADE_BY) .. le16(version) .. le16(0) .. le16(method) ..
    le16(dos_time) .. le16(dos_date) .. le32(crc) .. le32(csize) .. le32(usize) ..
    le16(#name) .. le16(#extra) .. le16(0) .. le16(0) .. le16(0) .. le32(ext_attrs) ..
    le32(local_offset) .. name .. extra
end

--- A streaming writer over `w`. Every body is given whole (this format
--- states each entry's size before its data, same as tar, but does not
--- offer tar's Reader-with-known-size escape hatch), so add_file takes
--- a plain string.
function Zip.writer(w: Stream.Writer, opts?: Zip.WriterOptions): Zip.ZipWriter
  opts = opts or {}
  local deterministic = opts.deterministic or false
  local offset = opts.offset or 0
  local cd_parts: {string} = {}
  local count = 0
  local closed = false
  local failed: string
  local zw: Zip.ZipWriter = {}

  local function fail(trouble: string): boolean, string
    if failed == nil then
      failed = trouble ~= "" and trouble or "zip: write failed"
      w:abort()
    end
    return false, failed
  end

  local function put(data: string): boolean, string
    local ok, trouble = w:write(data)
    if not ok then return fail(trouble) end
    offset = offset + #data
    return true, ""
  end

  local function write_entry(path: string, data: string, method_name: string,
      mode: integer, mtime: integer, is_dir: boolean): boolean, string
    if failed then return false, failed end
    if closed then return false, "zip: writer is closed" end
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

  zw.add_file = function(_self: Zip.ZipWriter, path: string, data: string,
      fopts?: Zip.EntryOptions): boolean, string
    fopts = fopts or {}
    local mode = fopts.mode or 0x1a4
    local mtime = fopts.mtime or 0
    local method_name = fopts.method or "deflate"
    return write_entry(path, data, method_name, mode, mtime, false)
  end

  zw.add_dir = function(_self: Zip.ZipWriter, path: string, fopts?: Zip.EntryOptions): boolean, string
    fopts = fopts or {}
    local mode = fopts.mode or 0x1ed
    local mtime = fopts.mtime or 0
    local dirpath = path:sub(-1) == "/" and path or (path .. "/")
    return write_entry(dirpath, "", "store", mode, mtime, true)
  end

  zw.close = function(_self: Zip.ZipWriter): boolean, string
    if failed then return false, failed end
    if closed then return true, "" end
    closed = true
    local cd_offset = offset
    local ok, trouble = put(table.concat(cd_parts))
    if not ok then return false, trouble end
    cd_parts = {}
    local cd_size = offset - cd_offset
    local needs_zip64 = count >= 0xFFFF or cd_size >= U32_MAX or cd_offset >= U32_MAX
    if needs_zip64 then
      local zip64_eocd_offset = offset
      local record = Z64_EOCD_SIG .. le64(44) .. le16((3 << 8) | 45) .. le16(45) .. le32(0) ..
        le32(0) .. le64(count) .. le64(count) .. le64(cd_size) .. le64(cd_offset)
      ok, trouble = put(record)
      if not ok then return false, trouble end
      local locator = Z64_LOC_SIG .. le32(0) .. le64(zip64_eocd_offset) .. le32(1)
      ok, trouble = put(locator)
      if not ok then return false, trouble end
    end
    local eocd_count = needs_zip64 and 0xFFFF or count
    local eocd_cd_size = needs_zip64 and U32_MAX or cd_size
    local eocd_cd_offset = needs_zip64 and U32_MAX or cd_offset
    local eocd = EOCD_SIG .. le16(0) .. le16(0) .. le16(eocd_count) .. le16(eocd_count) ..
      le32(eocd_cd_size) .. le32(eocd_cd_offset) .. le16(0)
    ok, trouble = put(eocd)
    if not ok then return false, trouble end
    ok, trouble = w:close()
    if not ok then failed = trouble end
    return ok, trouble
  end

  zw.abort = function(_self: Zip.ZipWriter): boolean, string
    if closed or failed then return true, "" end
    closed = true
    return w:abort()
  end

  return zw
end

return Zip
