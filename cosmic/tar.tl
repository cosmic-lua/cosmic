--- A streaming tar reader and writer: ustar, GNU long name/link (`L`/`K`),
--- and pax extended headers (`x` per-entry, `g` global). Entries are
--- walked forward only, one at a time; an entry not read with `open`
--- is skipped automatically when the next one is asked for -- by
--- seeking, when the underlying Reader can `skip`. Neither side
--- buffers a whole archive: a body is read or written in chunks, so an
--- archive far larger than memory streams through in bounded space.
--- Compression, when there is any, wraps the underlying
--- `Stream.Reader`/`Stream.Writer` before it reaches this module --
--- see `cosmic.archive`.

local Hash = require("cosmic.hash")
local Stream = require("cosmic.stream")

local record Tar
  enum Kind
    "file"
    "dir"
    "symlink"
    "hardlink"
    --- Anything else: a device, a FIFO, a GNU sparse file (typeflag
    --- `S`, or pax `GNU.sparse.*` records), or a typeflag this module
    --- does not know. Its body, if any, is still skipped correctly.
    "other"
  end

  record Entry
    path: string
    kind: Kind
    mode: integer
    size: integer
    mtime: integer
    linkpath: string
    uid: integer
    gid: integer
    --- The header's typeflag byte, for telling apart what `kind`
    --- lumps together as "other".
    typeflag: string
    --- This entry's body, as a Reader bounded to its size. Valid only
    --- until the next `TarReader.next` call; reading it afterwards
    --- fails, and so does opening it twice.
    open: function(Entry): Stream.Reader | nil, string
  end

  record TarReader
    --- The next entry, or nil and `""` once the archive's two zero
    --- blocks are reached (or the stream simply ends there). An error
    --- is sticky: every later call returns it again.
    next: function(TarReader): Entry | nil, string
    --- Closes the Reader this one reads from.
    close: function(TarReader): boolean, string
  end

  record EntryOptions
    mode: integer
    mtime: integer
    --- Required when the body passed to `add_file` is a Reader rather
    --- than a string, since a tar header states a size before its body.
    size: integer
  end

  record WriterOptions
    --- Forces every entry's mtime to 0, so the same sequence of calls
    --- tars to the same bytes. (uid/gid are always written as 0 and
    --- uname/gname as empty, deterministic or not.)
    deterministic: boolean
  end

  --- Once any call fails, the underlying Writer is aborted and every
  --- later call, `close` included, returns that failure: a half-written
  --- archive is never committed. A call after `close` fails too.
  record TarWriter
    add_file: function(TarWriter, string, string | Stream.Reader, opts?: EntryOptions): boolean, string
    add_dir: function(TarWriter, string, opts?: EntryOptions): boolean, string
    add_symlink: function(TarWriter, string, string, opts?: EntryOptions): boolean, string
    close: function(TarWriter): boolean, string
    --- Abandons the archive: aborts the underlying Writer.
    abort: function(TarWriter): boolean, string
  end
end

local BLOCK <const> = 512
local EIGHT_GIB <const> = 1 << 33
local OCTAL_11_LIMIT <const> = 1 << 33 -- 8^11, what 11 octal digits hold
--- The largest `L`/`K`/`x`/`g` body read into memory. Real ones are a
--- path or a handful of records; a header claiming more is refused
--- rather than allocated.
local SPECIAL_BODY_LIMIT <const> = 1 << 20

------------------------------------------------------------------
-- shared header field encoding/decoding
------------------------------------------------------------------

--- A numeric header field: usual NUL/space-padded octal text, or a
--- GNU base-256 field (its first byte's high bit set) for a value too
--- large for octal text to hold, or negative (a pre-1970 mtime, say).
--- The field, taken as a whole, is a two's-complement integer: the
--- first byte's second-highest bit is its sign, sign-extended before
--- the rest of the bytes are folded in, so a negative value decodes
--- to a small negative number rather than a huge positive one.
local function numeric(field: string): integer
  if #field > 0 and (field:byte(1) & 0x80) ~= 0 then
    local negative = (field:byte(1) & 0x40) ~= 0
    local value: integer = negative and -1 or 0
    value = (value << 7) | (field:byte(1) & 0x7f)
    for i = 2, #field do
      value = (value << 8) | field:byte(i)
    end
    return value
  end
  local digits = field:match("^%s*([0-7]*)")
  if digits == nil or digits == "" then return 0 end
  return math.tointeger(tonumber(digits, 8)) or 0
end

--- `numeric` of the `len`-byte field at `off` in `block`. The usual
--- field -- octal digits, perhaps space-padded, ending in a NUL or a
--- space -- goes straight to `tonumber`; anything else (a base-256
--- field, digits right up to the field's end, NUL padding before the
--- terminator) takes `numeric`'s slower, general path.
local function numeric_at(block: string, off: integer, len: integer): integer
  local stop = off + len - 2
  local last = block:byte(stop + 1)
  if last == 0 or last == 32 then
    -- The checksum field ends in a NUL and then a space.
    if block:byte(stop) == 0 then stop = stop - 1 end
    local n = math.tointeger(tonumber(block:sub(off, stop), 8))
    if n ~= nil and n >= 0 then return n end
  end
  return numeric(block:sub(off, off + len - 1))
end

--- The NUL-terminated text of the `len`-byte field at `off`, which may
--- also fill the field with no NUL at all.
local function text_at(block: string, off: integer, len: integer): string
  local stop = off + len - 1
  local nul = block:find("\0", off, true)
  if nul ~= nil and nul <= stop then stop = nul - 1 end
  return block:sub(off, stop)
end

--- The header checksum: every byte summed, the checksum field itself
--- (bytes 149 to 156) counted as eight spaces.
local function header_sum(block: string): integer
  return Hash.byte_sum(block, 1, 148) + Hash.byte_sum(block, 157, BLOCK) + 256
end

------------------------------------------------------------------
-- reading
------------------------------------------------------------------

--- One 512-byte block, `false` and no error; nil, true, "" at a clean
--- end of stream before any of it arrived; or nil, false, an error --
--- including a short read that never reaches a full block.
local function read_block_or_eof(raw: Stream.Reader): string | nil, boolean, string
  local first, trouble = raw:read(BLOCK)
  if first == nil then
    if trouble ~= "" then return nil, false, trouble end
    return nil, true, ""
  end
  if #first == BLOCK then return first, false, "" end
  local parts: {string} = { first }
  local got = #first
  while got < BLOCK do
    local chunk, rtrouble = raw:read(BLOCK - got)
    if chunk == nil then
      if rtrouble ~= "" then return nil, false, rtrouble end
      return nil, false, "tar: truncated header block"
    end
    parts[#parts + 1] = chunk
    got = got + #chunk
  end
  return table.concat(parts), false, ""
end

local function is_zero_block(block: string): boolean
  return block:find("[^\0]") == nil
end

local function padding_of(size: integer): integer
  return (BLOCK - (size % BLOCK)) % BLOCK
end

--- Reads `size` raw bytes and the padding after them, up to the next
--- block boundary, for an `L`/`K`/`x`/`g` special entry's own body.
local function read_special_body(raw: Stream.Reader, size: integer): string | nil, string
  if size < 0 or size > SPECIAL_BODY_LIMIT then
    return nil, "tar: a long-name or pax header body of " .. tostring(size) ..
      " bytes is over the " .. tostring(SPECIAL_BODY_LIMIT) .. "-byte limit"
  end
  local data, trouble = Stream.read_exact(raw, size)
  if data == nil then return nil, trouble end
  local skipped, strouble = Stream.skip(raw, padding_of(size))
  if not skipped then return nil, strouble end
  return data, ""
end

--- A GNU `L`/`K` body: a name with trailing NULs. A NUL before the
--- end would hide the rest of the name from every system call that
--- sees it, so it is refused.
local function long_field(data: string): string | nil, string
  local name = data:gsub("%z+$", "")
  if name:find("\0", 1, true) ~= nil then
    return nil, "tar: NUL byte inside a GNU long name"
  end
  return name, ""
end

--- The `key=value` records of a pax extended header body, each
--- prefixed with its own decimal byte length. Only the keys `apply_pax`
--- reads are kept, and every `GNU.sparse.*` key folds into one
--- valueless `GNU.sparse.` marker, so global (`g`) headers, which last
--- for the reader's lifetime, retain a handful of values however many
--- distinct keys an archive sends.
local function parse_pax(body: string): {string:string}
  local out: {string:string} = {}
  local at = 1
  while at <= #body do
    local sp = body:find(" ", at, true)
    if sp == nil then break end
    local len = math.tointeger(tonumber(body:sub(at, sp - 1)))
    if len == nil or len <= 0 or at + len - 1 > #body then break end
    local rec = body:sub(at, at + len - 1)
    local eq = rec:find("=", 1, true)
    if eq ~= nil then
      local key = rec:sub(sp - at + 2, eq - 1)
      if key:sub(1, 11) == "GNU.sparse." then
        out["GNU.sparse."] = ""
      elseif key == "path" or key == "linkpath" or key == "size" or key == "mtime"
        or key == "uid" or key == "gid" then
        out[key] = rec:sub(eq + 1, #rec - 1) -- drop the trailing newline
      end
    end
    at = at + len
  end
  return out
end

local record Fields
  name: string
  linkname: string
  size: integer
  mtime: integer
  uid: integer
  gid: integer
  sparse: boolean
end

local function apply_pax(fields: {string:string}, f: Fields): boolean, string
  for key, value in pairs(fields) do
    if key == "path" or key == "linkpath" then
      if value:find("\0", 1, true) ~= nil then
        return false, "tar: NUL byte inside a pax " .. key
      end
      if key == "path" then f.name = value else f.linkname = value end
    elseif key == "size" then
      local n = math.tointeger(tonumber(value))
      if n == nil or n < 0 then return false, "tar: bad pax size '" .. value .. "'" end
      f.size = n
    elseif key == "mtime" then
      f.mtime = math.tointeger(math.floor(tonumber(value) or f.mtime)) or f.mtime
    elseif key == "uid" then f.uid = math.tointeger(tonumber(value)) or f.uid
    elseif key == "gid" then f.gid = math.tointeger(tonumber(value)) or f.gid
    elseif key:sub(1, 11) == "GNU.sparse." then f.sparse = true
    end
  end
  return true, ""
end

local function kind_of(typeflag: string): Tar.Kind
  if typeflag == "0" or typeflag == "\0" or typeflag == "7" then return "file" end
  if typeflag == "5" then return "dir" end
  if typeflag == "2" then return "symlink" end
  if typeflag == "1" then return "hardlink" end
  return "other"
end

--- How much a reader asks of its underlying Reader at a time.
local READ_AHEAD <const> = 1 << 16

--- A Reader over another that asks it for `READ_AHEAD` bytes at a
--- time, so that walking an archive of small entries costs one read
--- of the underlying Reader per 64 KiB rather than a read per header,
--- a read per body and a seek per padding. A read at least that big
--- with nothing held goes straight through, and a skip past what is
--- held goes to the underlying Reader's own skip.
local record Buffered is Stream.Reader
  raw: Stream.Reader
  buf: string
  at: integer
end

local Buffered_methods: {string:any} = {}
local buffered_mt: metatable<Buffered> = { __index = Buffered_methods as Buffered }

Buffered_methods.read = function(self: Buffered, max: integer): string | nil, string
  local buf, at = self.buf, self.at
  local avail = #buf - at + 1
  if avail <= 0 then
    if max ~= nil and max >= READ_AHEAD then return self.raw:read(max) end
    local chunk, trouble = self.raw:read(READ_AHEAD)
    if chunk == nil then return nil, trouble end
    buf, at, avail = chunk, 1, #chunk
    self.buf = buf
  end
  local n = max or avail
  if n > avail then n = avail end
  self.at = at + n
  if at == 1 and n == #buf then return buf, "" end
  return buf:sub(at, at + n - 1), ""
end

Buffered_methods.skip = function(self: Buffered, n: integer): boolean, string
  local avail = #self.buf - self.at + 1
  if n <= avail then
    self.at = self.at + n
    return true, ""
  end
  self.buf, self.at = "", 1
  return Stream.skip(self.raw, n - avail)
end

Buffered_methods.close = function(self: Buffered): boolean, string
  self.buf, self.at = "", 1
  return self.raw:close()
end

local function buffered(raw: Stream.Reader): Buffered
  return setmetatable({ raw = raw, buf = "", at = 1 } as Buffered, buffered_mt)
end

--- What a reader shares with the bodies it hands out: an entry's body
--- reads through `raw`, and counts down `pending_skip`, only while
--- `generation` is still the one it was opened in.
local record ReaderState
  raw: Stream.Reader
  pending_skip: integer
  generation: integer
  --- The entry `next` last returned, and whether it has been opened.
  current: Tar.Entry
  opened: boolean
  --- The current entry's body size, as its header gave it.
  size: integer
end

--- An entry's body: a Reader bounded to the entry's size, whose
--- methods live on one shared metatable rather than in closures made
--- per entry.
local record Body is Stream.Reader
  state: ReaderState
  generation: integer
  left: integer
  failed: string
  closed: boolean
end

local Body_methods: {string:any} = {}
local body_mt: metatable<Body> = { __index = Body_methods as Body }

Body_methods.read = function(self: Body, max: integer): string | nil, string
  if self.failed then return nil, self.failed end
  if self.closed then return nil, "tar: entry body is closed" end
  local state = self.state
  if self.generation ~= state.generation then
    return nil, "tar: entry is no longer current"
  end
  local left = self.left
  if left <= 0 then return nil, "" end
  local want = max or (1 << 16)
  if want > left then want = left end
  local chunk, rtrouble = state.raw:read(want)
  if chunk == nil then
    self.failed = rtrouble ~= "" and rtrouble or "tar: unexpected end of archive"
    return nil, self.failed
  end
  self.left = left - #chunk
  state.pending_skip = state.pending_skip - #chunk
  return chunk, ""
end

Body_methods.close = function(self: Body): boolean, string
  self.closed = true
  return true, ""
end

--- A streaming reader over `raw`'s tar bytes. Closing it closes `raw`.
function Tar.reader(raw: Stream.Reader): Tar.TarReader
  local ended = false
  local failed: string
  local closed = false
  local pax_global: {string:string} = {}
  local src = buffered(raw)
  local state: ReaderState = {
    raw = src, pending_skip = 0, generation = 0, opened = false, size = 0,
  }
  local tr: Tar.TarReader = {}

  local function fail(trouble: string): nil, string
    failed = trouble ~= "" and trouble or "tar: read failed"
    return nil, failed
  end

  -- Every entry this reader makes shares one `open`, through its
  -- metatable: only the current entry can be opened, and only once.
  local entry_mt: metatable<Tar.Entry> = {
    __index = {
      open = function(e: Tar.Entry): Stream.Reader | nil, string
        if e ~= state.current then return nil, "tar: entry is no longer current" end
        -- A second `open` on the same entry would share `left` and
        -- `pending_skip` with the first and read wherever that one
        -- left off, silently -- refuse it.
        if state.opened then return nil, "tar: entry already opened once" end
        state.opened = true
        local body: Body = setmetatable({
          state = state, generation = state.generation, left = state.size, closed = false,
        } as Body, body_mt)
        return body, ""
      end,
    } as Tar.Entry,
  }

  tr.next = function(_self: Tar.TarReader): Tar.Entry | nil, string
    if failed then return nil, failed end
    if closed then return nil, "tar: reader is closed" end
    if ended then return nil, "" end
    state.generation = state.generation + 1
    state.current = nil
    local skipped, dtrouble = Stream.skip(src, state.pending_skip)
    state.pending_skip = 0
    if not skipped then
      if dtrouble:find("end of", 1, true) ~= nil then
        return fail("tar: unexpected end of archive")
      end
      return fail(dtrouble)
    end

    local long_name: string
    local long_link: string
    local pax_local: {string:string}

    while true do
      local block, at_eof, trouble = read_block_or_eof(src)
      if at_eof then
        ended = true
        return nil, ""
      end
      if block == nil then return fail(trouble) end
      local chksum = numeric_at(block, 149, 8)
      if chksum == 0 and is_zero_block(block) then
        local _second, _second_eof, strouble = read_block_or_eof(src)
        if strouble ~= "" then return fail(strouble) end
        ended = true
        return nil, ""
      end
      if header_sum(block) ~= chksum then
        return fail("tar: bad header checksum")
      end
      local typeflag = block:sub(157, 157)
      if typeflag == "L" or typeflag == "K" or typeflag == "x" or typeflag == "g" then
        local data, rtrouble = read_special_body(src, numeric_at(block, 125, 12))
        if data == nil then return fail(rtrouble) end
        if typeflag == "L" or typeflag == "K" then
          local value, ltrouble = long_field(data)
          if value == nil then return fail(ltrouble) end
          if typeflag == "L" then long_name = value else long_link = value end
        elseif typeflag == "x" then
          pax_local = parse_pax(data)
        else
          for key, value in pairs(parse_pax(data)) do pax_global[key] = value end
        end
      else
        local name = long_name
        if name == nil then
          name = text_at(block, 1, 100)
          -- A ustar prefix is only there when byte 346 is not NUL.
          if block:byte(346) ~= 0 then name = text_at(block, 346, 155) .. "/" .. name end
        end
        local linkname = long_link or (block:byte(158) ~= 0 and text_at(block, 158, 100) or "")
        local size = numeric_at(block, 125, 12)
        local mtime = numeric_at(block, 137, 12)
        local uid = numeric_at(block, 109, 8)
        local gid = numeric_at(block, 117, 8)
        local mode = numeric_at(block, 101, 8) & 0xFFF
        local sparse = false
        if pax_local ~= nil or next(pax_global) ~= nil then
          local f: Fields = {
            name = name, linkname = linkname, size = size, mtime = mtime, uid = uid, gid = gid,
            sparse = false,
          }
          local ok, ptrouble = apply_pax(pax_global, f)
          if ok and pax_local ~= nil then ok, ptrouble = apply_pax(pax_local, f) end
          if not ok then return fail(ptrouble) end
          name, linkname, size, mtime, uid, gid, sparse =
            f.name, f.linkname, f.size, f.mtime, f.uid, f.gid, f.sparse
        end
        if size < 0 then return fail("tar: negative entry size") end
        state.pending_skip = size + padding_of(size)

        local kind = kind_of(typeflag)
        if typeflag == "S" or sparse then kind = "other" end
        local entry: Tar.Entry = setmetatable({
          path = name,
          kind = kind,
          mode = mode,
          size = size,
          mtime = mtime,
          linkpath = linkname,
          uid = uid,
          gid = gid,
          typeflag = typeflag,
        }, entry_mt)
        state.current = entry
        state.opened = false
        state.size = size
        return entry, ""
      end
    end
  end

  tr.close = function(_self: Tar.TarReader): boolean, string
    if closed then return true, "" end
    closed = true
    state.generation = state.generation + 1
    state.current = nil
    return raw:close()
  end

  return tr
end

------------------------------------------------------------------
-- writing
------------------------------------------------------------------

local function txt(s: string, width: integer): string
  if #s >= width then return s:sub(1, width) end
  return s .. string.rep("\0", width - #s)
end

--- `n` as zero-padded octal text filling a `width`-byte field, NUL
--- terminated. The caller keeps `n` within range (0 to 8^(width-1)-1);
--- anything else would be silently wrapped.
local function oct(n: integer, width: integer): string
  return string.format("%0" .. tostring(width - 1) .. "o", n) .. "\0"
end

local function pad_bytes(size: integer): string
  local rem = size % BLOCK
  if rem == 0 then return "" end
  return string.rep("\0", BLOCK - rem)
end

--- A path split for the ustar name/prefix fields: the rightmost `/`
--- that leaves both halves within their field widths. Empty prefix
--- and the whole path in `name` when the path already fits. `fits` is
--- false when no split works and the path needs a pax header instead.
local function split_ustar(path: string): string, string, boolean
  if #path <= 100 then return "", path, true end
  local best: integer
  for i = 1, #path do
    if path:byte(i) == 47 then -- '/'
      local prefix_len = i - 1
      local name_len = #path - i
      if prefix_len <= 155 and name_len > 0 and name_len <= 100 then
        best = i
      end
    end
  end
  if best == nil then return "", "", false end
  return path:sub(1, best - 1), path:sub(best + 1), true
end

local function build_header(name: string, prefix: string, typeflag: string, size: integer,
    mode: integer, uid: integer, gid: integer, mtime: integer, linkname: string,
    uname: string, gname: string): string
  local block = txt(name, 100) .. oct(mode, 8) .. oct(uid, 8) .. oct(gid, 8) ..
    oct(size, 12) .. oct(mtime, 12) .. string.rep(" ", 8) .. typeflag ..
    txt(linkname, 100) .. "ustar\0" .. "00" .. txt(uname, 32) .. txt(gname, 32) ..
    oct(0, 8) .. oct(0, 8) .. txt(prefix, 155) .. string.rep("\0", 12)
  local checksum = string.format("%06o", header_sum(block)) .. "\0 "
  return block:sub(1, 148) .. checksum .. block:sub(157)
end

--- One pax record: its own decimal length, a space, `key=value`, and
--- a newline -- with the length counting itself, computed by the usual
--- fixed-point search.
local function pax_record(key: string, value: string): string
  local body = " " .. key .. "=" .. value .. "\n"
  local len = #body + 1
  while true do
    local candidate = #tostring(len) + #body
    if candidate == len then return tostring(len) .. body end
    len = candidate
  end
end

local function pax_header(real_name: string, records: string): string
  local base = real_name:match("([^/]+)/?$") or real_name
  local pax_name = "PaxHeaders/" .. base
  if #pax_name > 100 then pax_name = pax_name:sub(1, 100) end
  return build_header(pax_name, "", "x", #records, 0, 0, 0, 0, "", "", "") ..
    records .. pad_bytes(#records)
end

--- A streaming writer over `w`.
function Tar.writer(w: Stream.Writer, opts?: Tar.WriterOptions): Tar.TarWriter
  opts = opts or {}
  local deterministic = opts.deterministic or false
  local closed = false
  local failed: string
  local tw: Tar.TarWriter = {}

  local function fail(trouble: string): boolean, string
    if failed == nil then
      failed = trouble ~= "" and trouble or "tar: write failed"
      w:abort()
    end
    return false, failed
  end

  local function usable(): boolean, string
    if failed then return false, failed end
    if closed then return false, "tar: writer is closed" end
    return true, ""
  end

  local function put(data: string): boolean, string
    local ok, trouble = w:write(data)
    if not ok then return fail(trouble) end
    return true, ""
  end

  local function put_entry(path: string, typeflag: string, size: integer,
      mode: integer, mtime: integer, linkname: string): boolean, string
    local ok, trouble = usable()
    if not ok then return false, trouble end
    if path:find("\0", 1, true) ~= nil or linkname:find("\0", 1, true) ~= nil then
      return false, "tar: NUL byte in a path"
    end
    if size < 0 then return false, "tar: negative size" end
    if deterministic then mtime = 0 end
    local uid, gid, uname, gname = 0, 0, "", ""
    local prefix, name, fits = split_ustar(path)
    local link_fits = #linkname <= 100
    local size_fits = size < EIGHT_GIB
    local mtime_fits = mtime >= 0 and mtime < OCTAL_11_LIMIT
    if not (fits and link_fits and size_fits and mtime_fits) then
      local records: {string} = {}
      if not fits then records[#records + 1] = pax_record("path", path) end
      if not link_fits then records[#records + 1] = pax_record("linkpath", linkname) end
      if not size_fits then records[#records + 1] = pax_record("size", tostring(size)) end
      if not mtime_fits then records[#records + 1] = pax_record("mtime", tostring(mtime)) end
      ok, trouble = put(pax_header(path, table.concat(records)))
      if not ok then return false, trouble end
      if not fits then prefix, name = "", path:sub(-100) end
    end
    local header_size = size_fits and size or 0
    local header_mtime = mtime_fits and mtime or (mtime < 0 and 0 or OCTAL_11_LIMIT - 1)
    local header = build_header(name, prefix, typeflag, header_size, mode & 0xFFF, uid, gid,
      header_mtime, linkname:sub(1, 100), uname, gname)
    return put(header)
  end

  tw.add_file = function(_self: Tar.TarWriter, path: string, data: string | Stream.Reader,
      fopts?: Tar.EntryOptions): boolean, string
    fopts = fopts or {}
    local size = fopts.size
    if size == nil then
      if data is string then
        size = #data
      else
        return false, "tar: add_file needs opts.size for a Reader body"
      end
    end
    local mode = fopts.mode or 0x1a4
    local mtime = fopts.mtime or 0
    local ok, trouble = put_entry(path, "0", size, mode, mtime, "")
    if not ok then return false, trouble end
    if data is string then
      if #data ~= size then
        return fail("tar: add_file: body is " .. tostring(#data) .. " bytes, not " .. tostring(size))
      end
      ok, trouble = put(data)
      if not ok then return false, trouble end
    else
      local written = 0
      while written < size do
        local want = size - written
        if want > (1 << 16) then want = 1 << 16 end
        local chunk, rtrouble = data:read(want)
        if chunk == nil then
          if rtrouble ~= "" then return fail(rtrouble) end
          return fail("tar: add_file: reader ended before its stated size")
        end
        ok, trouble = put(chunk)
        if not ok then return false, trouble end
        written = written + #chunk
      end
    end
    return put(pad_bytes(size))
  end

  tw.add_dir = function(_self: Tar.TarWriter, path: string, fopts?: Tar.EntryOptions): boolean, string
    fopts = fopts or {}
    local mode = fopts.mode or 0x1ed
    local mtime = fopts.mtime or 0
    local dirpath = path:sub(-1) == "/" and path or (path .. "/")
    return put_entry(dirpath, "5", 0, mode, mtime, "")
  end

  tw.add_symlink = function(_self: Tar.TarWriter, path: string, target: string,
      fopts?: Tar.EntryOptions): boolean, string
    fopts = fopts or {}
    local mode = fopts.mode or 0x1ff
    local mtime = fopts.mtime or 0
    return put_entry(path, "2", 0, mode, mtime, target)
  end

  tw.close = function(_self: Tar.TarWriter): boolean, string
    if failed then return false, failed end
    if closed then return true, "" end
    local ok, trouble = put(string.rep("\0", 2 * BLOCK))
    closed = true
    if not ok then return false, trouble end
    ok, trouble = w:close()
    if not ok then failed = trouble end
    return ok, trouble
  end

  tw.abort = function(_self: Tar.TarWriter): boolean, string
    if closed or failed then return true, "" end
    closed = true
    return w:abort()
  end

  return tw
end

return Tar
