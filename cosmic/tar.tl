--- A streaming tar reader and writer: ustar, GNU long name/link (`L`/`K`),
--- and pax extended headers (`x` per-entry, `g` global). Entries are
--- walked forward only, one at a time; an entry not read with `open`
--- is skipped automatically when the next one is asked for -- by
--- seeking, when the underlying Reader can `skip`. Neither side
--- buffers a whole archive: a body is read or written in chunks, so an
--- archive far larger than memory streams through in bounded space.
--- Compression, when there is any, wraps the underlying
--- [`Stream.Reader`]/[`Stream.Writer`] before it reaches this module --
--- see [`cosmic.archive`].

local Hash = require("cosmic.hash")
local Stream = require("cosmic.stream")
local String = require("cosmic.string")

local record Tar
  --- A tar's entry: a [`Stream.ArchiveEntry`] that also says who owns it
  --- and which typeflag its header carries.
  record Entry is Stream.ArchiveEntry
    --- The owner's numeric user id.
    uid: integer
    --- The owner's numeric group id.
    gid: integer
    --- The header's typeflag byte, for telling apart what `kind`
    --- lumps together as "other".
    typeflag: string
    --- This entry's body, as a Stream.Reader bounded to its size. Valid only
    --- until the next `Reader.next` call; reading it afterwards
    --- fails, and so does opening it twice.
    open: function(Entry): Stream.Reader | nil, string
  end

  interface Reader is Stream.ArchiveReader
    --- The next entry, or nil and `""` once the archive's two zero
    --- blocks are reached (or the stream simply ends there). An error
    --- is sticky: every later call returns it again.
    next: function(Reader): Entry | nil, string
    --- Closes the Stream.Reader this one reads from.
    close: function(Reader): boolean, string
  end

  record WriterOptions
    --- Forces every entry's mtime to 0, so the same sequence of calls
    --- tars to the same bytes. (uid/gid are always written as 0 and
    --- uname/gname as empty, deterministic or not.)
    deterministic: boolean
  end

  --- Once any call fails, the underlying Stream.Writer is aborted and every
  --- later call, `close` included, returns that failure: a half-written
  --- archive is never committed. A call after `close` fails too.
  interface Writer is Stream.ArchiveWriter
    --- Adds a regular file at `path` with `data` as its body. A
    --- [`Stream.Reader`] body needs `opts.size`, since a tar header
    --- states a size before its body, and is read to that many bytes,
    --- which it then requires; a string body must match `opts.size`
    --- when that is given. A `size` that is no integer, or is negative,
    --- raises. The reader is not closed. Returns `true, ""`, or `false`
    --- and why.
    add_file: function(self: Writer, path: string, data: string | Stream.Reader, opts?: Stream.EntryOptions): boolean, string
    --- Adds a directory entry at `path`, to which a trailing `/` is
    --- added if missing. Returns `true, ""`, or `false` and why.
    add_dir: function(self: Writer, path: string, opts?: Stream.EntryOptions): boolean, string
    --- Adds a symbolic link at `path` pointing at `target`. Returns
    --- `true, ""`, or `false` and why.
    add_symlink: function(self: Writer, path: string, target: string, opts?: Stream.EntryOptions): boolean, string
    --- Writes the archive's end blocks and closes the underlying
    --- Stream.Writer, committing it. Returns `true, ""`, or `false` and why.
    close: function(self: Writer): boolean, string
    --- Abandons the archive: aborts the underlying Stream.Writer.
    abort: function(self: Writer): boolean, string
  end
end

-- A Reader or Writer here is made as cosmic/stream.tl's "How an object of
-- this module is made" says: a record of its own per kind, implementing the
-- public interface it answers, with its methods on that record and its
-- state in fields. The one exception is an entry's `open`, which needs the
-- reader that made it: it is a closure of that reader, shared by all its
-- entries through their metatable, so that an entry stays the one table of
-- the fields its public record declares.

local BLOCK <const> = 512

--- What a failure of this module answers, nil and `why` under the
--- module's name.
local function refuse(why: string): nil, string
  return nil, "tar: " .. why
end

--- The most of an entry's body read at once, as [`cosmic.stream`] reads.
local chunk_size <const> = 1 << 16
--- 8^11, what 11 octal digits hold.
local OCTAL_11_LIMIT <const> = 1 << 33
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
--- A base-256 value an integer cannot hold (a 12-byte field holds 95
--- bits) answers nil, for the header to be refused, as GNU tar does,
--- rather than read as whatever its low 64 bits say.
local function numeric(field: string): integer | nil
  if #field > 0 and (field:byte(1) & 0x80) ~= 0 then
    local negative = (field:byte(1) & 0x40) ~= 0
    local value: integer = negative and -1 or 0
    value = (value << 7) | (field:byte(1) & 0x7f)
    for i = 2, #field do
      -- Past this range, shifting in another byte drops bits the
      -- value needs, its sign among them.
      if value < -(1 << 55) or value >= (1 << 55) then return nil end
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
--- terminator) takes `numeric`'s slower, general path, and answers
--- nil as it does.
local function numeric_at(block: string, off: integer, len: integer): integer | nil
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

--- The refusal of a header whose `what` field `numeric` answered nil for.
local function out_of_range(what: string): string
  return "tar: header " .. what .. " field is a base-256 value past the integer range"
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
  local block, trouble = Stream.read_up_to(raw, BLOCK)
  if block == nil then return nil, false, trouble end
  if block == "" then return nil, true, "" end
  if #block < BLOCK then return nil, false, "tar: truncated header block" end
  return block, false, ""
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
    return refuse("a long-name or pax header body of " .. String.counted(size, "byte") ..
      " is over the " .. tostring(SPECIAL_BODY_LIMIT) .. "-byte limit")
  end
  local data, trouble = Stream.read_exact(raw, size)
  if data == nil then return nil, trouble end
  local skipped, strouble = Stream.skip(raw, padding_of(size))
  if not skipped then return nil, strouble end
  return data, ""
end

--- The refusal of `text`, which `what` names, when it holds a NUL
--- byte: every system call would take it as the end of the string and
--- never see the rest. "" when it holds none.
local function nul_refusal(text: string, what: string): string
  if text:find("\0", 1, true) == nil then return "" end
  return "tar: NUL byte " .. what
end

--- A GNU `L`/`K` body: a name with trailing NULs, which are dropped.
local function long_field(data: string): string | nil, string
  local name = data:gsub("%z+$", "")
  local refusal = nul_refusal(name, "inside a GNU long name")
  if refusal ~= "" then return nil, refusal end
  return name, ""
end

--- The `key=value` records of a pax extended header body, each
--- prefixed with its own decimal byte length. Only the keys [`apply_pax`]
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

--- What a regular header says, the pax records and long names applied.
local record Fields
  name: string
  linkname: string
  size: integer
  mtime: integer
  uid: integer
  gid: integer
  mode: integer
  typeflag: string
  kind: Stream.EntryKind
  --- Whether a pax record named a GNU sparse file, which `kind` says too.
  sparse: boolean
end

local function apply_pax(fields: {string:string}, f: Fields): boolean, string
  for key, value in pairs(fields) do
    if key == "path" or key == "linkpath" then
      local refusal = nul_refusal(value, "inside a pax " .. key)
      if refusal ~= "" then return false, refusal end
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

local function kind_of(typeflag: string): Stream.EntryKind
  if typeflag == "0" or typeflag == "\0" or typeflag == "7" then return "file" end
  if typeflag == "5" then return "dir" end
  if typeflag == "2" then return "symlink" end
  if typeflag == "1" then return "hardlink" end
  return "other"
end

--- The fields of the regular header `block`, whose checksum has been
--- checked. `long_name` and `long_link` are those of the `L` and `K`
--- headers before it, and the pax records of an `x` header before it
--- (`pax_local`) and of every `g` header so far (`pax_global`) are
--- applied over what the block says, the entry's own first. Nil and why
--- when a field is refused.
local function parse_header(block: string, long_name: string | nil, long_link: string | nil,
    pax_local: {string:string} | nil, pax_global: {string:string}): Fields | nil, string
  local name = long_name
  if name == nil then
    name = text_at(block, 1, 100)
    -- A ustar prefix is only there when byte 346 is not NUL.
    if block:byte(346) ~= 0 then name = text_at(block, 346, 155) .. "/" .. name end
  end
  local linkname = long_link or (block:byte(158) ~= 0 and text_at(block, 158, 100) or "")
  local size = numeric_at(block, 125, 12)
  if size == nil then return nil, out_of_range("size") end
  local mtime = numeric_at(block, 137, 12)
  if mtime == nil then return nil, out_of_range("mtime") end
  -- An 8-byte field's 63 bits always fit, but its type says nil.
  local uid = numeric_at(block, 109, 8)
  if uid == nil then return nil, out_of_range("uid") end
  local gid = numeric_at(block, 117, 8)
  if gid == nil then return nil, out_of_range("gid") end
  local raw_mode = numeric_at(block, 101, 8)
  if raw_mode == nil then return nil, out_of_range("mode") end
  local typeflag = block:sub(157, 157)
  local f: Fields = {
    name = name, linkname = linkname, size = size, mtime = mtime, uid = uid, gid = gid,
    mode = raw_mode & 0xFFF, typeflag = typeflag, sparse = false,
  }
  if pax_local ~= nil or next(pax_global) ~= nil then
    local ok, trouble = apply_pax(pax_global, f)
    if ok and pax_local ~= nil then ok, trouble = apply_pax(pax_local, f) end
    if not ok then return nil, trouble end
  end
  if f.size < 0 then return refuse("negative entry size") end
  -- Its padding added, a size this near the integer limit could wrap
  -- negative, and `next` would skip none of its body; a block below the
  -- limit is a bound no padding crosses.
  if f.size > math.maxinteger - BLOCK then
    return refuse("entry size " .. tostring(f.size) .. " is too large")
  end
  f.kind = (typeflag == "S" or f.sparse) and "other" or kind_of(typeflag)
  return f, ""
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
  read: function(Buffered, max_bytes?: integer): string | nil, string
  skip: function(Buffered, n: integer): boolean, string
  close: function(Buffered): boolean, string
end

local buffered_mt: metatable<Buffered> = { __index = Buffered }

function Buffered:read(max_bytes?: integer): string | nil, string
  local buf, at = self.buf, self.at
  local avail = #buf - at + 1
  if avail <= 0 then
    if max_bytes ~= nil and max_bytes >= READ_AHEAD then return self.raw:read(max_bytes) end
    local chunk, trouble = self.raw:read(READ_AHEAD)
    if chunk == nil then return nil, trouble end
    buf, at, avail = chunk, 1, #chunk
    self.buf = buf
  end
  local n = max_bytes or avail
  if n > avail then n = avail end
  self.at = at + n
  if at == 1 and n == #buf then return buf, "" end
  return buf:sub(at, at + n - 1), ""
end

function Buffered:skip(n: integer): boolean, string
  local avail = #self.buf - self.at + 1
  if n <= avail then
    self.at = self.at + n
    return true, ""
  end
  self.buf, self.at = "", 1
  return Stream.skip(self.raw, n - avail)
end

function Buffered:close(): boolean, string
  self.buf, self.at = "", 1
  return self.raw:close()
end

local function buffered(raw: Stream.Reader): Buffered
  local b: Buffered = setmetatable({ raw = raw, buf = "", at = 1 }, buffered_mt)
  return b
end

--- What [`Tar.reader`] answers. Its entries' bodies share its state:
--- a body reads through `src`, and counts down `pending_skip`, only
--- while `generation` is still the one it was opened in.
local record EntryReader is Tar.Reader
  --- What the reader was given, which `close` closes, and what the
  --- headers and bodies are read through.
  raw: Stream.Reader
  src: Buffered
  pax_global: {string:string}
  ended: boolean
  closed: boolean
  failed: string
  pending_skip: integer
  generation: integer
  --- The entry `next` last returned, and whether it has been opened.
  current: Tar.Entry
  opened: boolean
  --- The current entry's body size, as its header gave it.
  size: integer
  --- What every entry of this reader gets as its metatable.
  entry_mt: metatable<Tar.Entry>
  next: function(EntryReader): Tar.Entry | nil, string
  close: function(EntryReader): boolean, string
end

local entry_reader_mt: metatable<EntryReader> = { __index = EntryReader }

--- An entry's body: a Reader bounded to the entry's size.
local record Body is Stream.Reader
  state: EntryReader
  generation: integer
  left: integer
  failed: string
  closed: boolean
  read: function(Body, max_bytes?: integer): string | nil, string
  close: function(Body): boolean, string
end

local body_mt: metatable<Body> = { __index = Body }

function Body:read(max_bytes?: integer): string | nil, string
  if self.failed then return nil, self.failed end
  if self.closed then return refuse("the entry body is closed") end
  local state = self.state
  if self.generation ~= state.generation then
    return refuse("entry is no longer current")
  end
  local left = self.left
  if left <= 0 then return nil, "" end
  local want = max_bytes or chunk_size
  if want > left then want = left end
  local chunk, rtrouble = state.src:read(want)
  if chunk == nil then
    self.failed = rtrouble ~= "" and rtrouble or "tar: truncated archive"
    return nil, self.failed
  end
  self.left = left - #chunk
  state.pending_skip = state.pending_skip - #chunk
  return chunk, ""
end

function Body:close(): boolean, string
  self.closed = true
  return true, ""
end

--- Keeps `trouble` as the reader's failure, or "tar: read failed" when
--- it is "", and answers it.
local function fail(self: EntryReader, trouble: string): nil, string
  self.failed = trouble ~= "" and trouble or "tar: read failed"
  return nil, self.failed
end

function EntryReader:next(): Tar.Entry | nil, string
  if self.failed then return nil, self.failed end
  if self.closed then return refuse("the reader is closed") end
  if self.ended then return nil, "" end
  local src = self.src
  self.generation = self.generation + 1
  self.current = nil
  local skipped, dtrouble = Stream.skip(src, self.pending_skip)
  self.pending_skip = 0
  -- The skip's own reason says whether the archive ended early or a
  -- read failed; this says what was being done.
  if not skipped then return fail(self, "tar: cannot skip to the next entry: " .. dtrouble) end

  local long_name: string | nil
  local long_link: string | nil
  local pax_local: {string:string} | nil

  while true do
    local block, at_eof, trouble = read_block_or_eof(src)
    if at_eof then
      self.ended = true
      return nil, ""
    end
    if block == nil then return fail(self, trouble) end
    local chksum = numeric_at(block, 149, 8)
    if chksum == 0 and is_zero_block(block) then
      local _second, _second_eof, strouble = read_block_or_eof(src)
      if strouble ~= "" then return fail(self, strouble) end
      self.ended = true
      return nil, ""
    end
    if header_sum(block) ~= chksum then
      return fail(self, "tar: bad header checksum")
    end
    local typeflag = block:sub(157, 157)
    if typeflag == "L" or typeflag == "K" or typeflag == "x" or typeflag == "g" then
      local special_size = numeric_at(block, 125, 12)
      if special_size == nil then return fail(self, out_of_range("size")) end
      local data, rtrouble = read_special_body(src, special_size)
      if data == nil then return fail(self, rtrouble) end
      if typeflag == "L" or typeflag == "K" then
        local value, ltrouble = long_field(data)
        if value == nil then return fail(self, ltrouble) end
        if typeflag == "L" then long_name = value else long_link = value end
      elseif typeflag == "x" then
        pax_local = parse_pax(data)
      else
        for key, value in pairs(parse_pax(data)) do self.pax_global[key] = value end
      end
    else
      local f, ftrouble = parse_header(block, long_name, long_link, pax_local, self.pax_global)
      if f == nil then return fail(self, ftrouble) end
      self.pending_skip = f.size + padding_of(f.size)
      local entry: Tar.Entry = setmetatable({
        path = f.name,
        kind = f.kind,
        mode = f.mode,
        size = f.size,
        mtime = f.mtime,
        linkpath = f.linkname,
        uid = f.uid,
        gid = f.gid,
        typeflag = typeflag,
      }, self.entry_mt)
      self.current = entry
      self.opened = false
      self.size = f.size
      return entry, ""
    end
  end
end

function EntryReader:close(): boolean, string
  if self.closed then return true, "" end
  self.closed = true
  self.generation = self.generation + 1
  self.current = nil
  return self.raw:close()
end

--- A streaming reader over `raw`'s tar bytes. Closing it closes `raw`.
function Tar.reader(raw: Stream.Reader): Tar.Reader
  local r: EntryReader = setmetatable({
    raw = raw, src = buffered(raw), pax_global = {}, ended = false, closed = false,
    pending_skip = 0, generation = 0, opened = false, size = 0,
  }, entry_reader_mt)
  -- Every entry this reader makes shares one `open`, through its
  -- metatable: only the current entry can be opened, and only once. It
  -- is one closure for the whole reader, not one for each entry, and
  -- the entry's fields stay those [`Tar.Entry`] declares.
  r.entry_mt = {
    __index = {
      open = function(e: Tar.Entry): Stream.Reader | nil, string
        if e ~= r.current then return refuse("entry is no longer current") end
        -- A second `open` on the same entry would share `left` and
        -- `pending_skip` with the first and read wherever that one
        -- left off, silently -- refuse it.
        if r.opened then return refuse("entry already opened once") end
        r.opened = true
        local body: Body = setmetatable({
          state = r, generation = r.generation, left = r.size, closed = false,
        }, body_mt)
        return body, ""
      end,
    },
  }
  return r
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

--- The zero bytes that carry `size` bytes of data to a block boundary.
local function pad_bytes(size: integer): string
  return string.rep("\0", padding_of(size))
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
      -- An empty prefix reads back as no prefix at all, so a split at
      -- a leading `/` would lose it.
      if prefix_len > 0 and prefix_len <= 155 and name_len > 0 and name_len <= 100 then
        best = i
      end
    end
  end
  if best == nil then return "", "", false end
  return path:sub(1, best - 1), path:sub(best + 1), true
end

--- A ustar header block. Every entry is owned by uid and gid 0 with no
--- user or group name, as [`Tar.WriterOptions`] documents.
local function build_header(name: string, prefix: string, typeflag: string, size: integer,
    mode: integer, mtime: integer, linkname: string): string
  local block = txt(name, 100) .. oct(mode, 8) .. oct(0, 8) .. oct(0, 8) ..
    oct(size, 12) .. oct(mtime, 12) .. string.rep(" ", 8) .. typeflag ..
    txt(linkname, 100) .. "ustar\0" .. "00" .. txt("", 32) .. txt("", 32) ..
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
  return build_header(pax_name, "", "x", #records, 0, 0, "") ..
    records .. pad_bytes(#records)
end

--- What a body is copied to: the writer's sink, which keeps a write's
--- failure.
local record BodyWriter is Stream.Writer
  sink: Stream.Sticky
  write: function(BodyWriter, string): boolean, string
  close: function(BodyWriter): boolean, string
  abort: function(BodyWriter): boolean, string
end

local body_writer_mt: metatable<BodyWriter> = { __index = BodyWriter }

function BodyWriter:write(data: string): boolean, string
  return self.sink:put(data)
end

function BodyWriter:close(): boolean, string
  return true, ""
end

function BodyWriter:abort(): boolean, string
  return true, ""
end

--- What [`Tar.writer`] answers.
local record EntryWriter is Tar.Writer
  sink: Stream.Sticky
  deterministic: boolean
  add_file: function(EntryWriter, path: string, data: string | Stream.Reader,
    opts?: Stream.EntryOptions): boolean, string
  add_dir: function(EntryWriter, path: string, opts?: Stream.EntryOptions): boolean, string
  add_symlink: function(EntryWriter, path: string, target: string, opts?: Stream.EntryOptions): boolean, string
  close: function(EntryWriter): boolean, string
  abort: function(EntryWriter): boolean, string
end

local entry_writer_mt: metatable<EntryWriter> = { __index = EntryWriter }

local function put_entry(self: EntryWriter, path: string, typeflag: string, size: integer,
    mode: integer, mtime: integer, linkname: string): boolean, string
  local sink = self.sink
  local ok, trouble = sink:usable()
  if not ok then return false, trouble end
  local refusal = nul_refusal(path, "in a path")
  if refusal == "" then refusal = nul_refusal(linkname, "in a link target") end
  if refusal ~= "" then return false, refusal end
  if self.deterministic then mtime = 0 end
  local prefix, name, fits = split_ustar(path)
  local link_fits = #linkname <= 100
  local size_fits = size < OCTAL_11_LIMIT
  local mtime_fits = mtime >= 0 and mtime < OCTAL_11_LIMIT
  if not (fits and link_fits and size_fits and mtime_fits) then
    local records: {string} = {}
    if not fits then records[#records + 1] = pax_record("path", path) end
    if not link_fits then records[#records + 1] = pax_record("linkpath", linkname) end
    if not size_fits then records[#records + 1] = pax_record("size", tostring(size)) end
    if not mtime_fits then records[#records + 1] = pax_record("mtime", tostring(mtime)) end
    ok, trouble = sink:put(pax_header(path, table.concat(records)))
    if not ok then return false, trouble end
    if not fits then prefix, name = "", path:sub(-100) end
  end
  local header_size = size_fits and size or 0
  local header_mtime = mtime_fits and mtime or (mtime < 0 and 0 or OCTAL_11_LIMIT - 1)
  local header = build_header(name, prefix, typeflag, header_size, mode & 0xFFF,
    header_mtime, linkname:sub(1, 100))
  return sink:put(header)
end

function EntryWriter:add_file(path: string, data: string | Stream.Reader,
    fopts?: Stream.EntryOptions): boolean, string
  fopts = fopts or {}
  local size = fopts.size
  if size ~= nil and (math.type(size) ~= "integer" or size < 0) then
    error("tar: opts.size must be an integer of at least 0", 2)
  end
  if size == nil then
    if data is string then
      size = #data
    else
      return false, "tar: add_file needs opts.size for a Reader body"
    end
  end
  local mode = fopts.mode or 0x1a4
  local mtime = fopts.mtime or 0
  local ok, trouble = put_entry(self, path, "0", size, mode, mtime, "")
  if not ok then return false, trouble end
  local sink = self.sink
  if data is string then
    if #data ~= size then
      return sink:fail("tar: add_file: body is " .. String.counted(#data, "byte") .. ", not " .. String.counted(size, "byte"))
    end
    ok, trouble = sink:put(data)
    if not ok then return false, trouble end
  else
    local body_sink: BodyWriter = setmetatable({ sink = sink }, body_writer_mt)
    ok, trouble = Stream.copy_n(data, body_sink, size)
    if not ok then
      -- A failed write is the sink's already, said as the Writer said it.
      local usable, failure = sink:usable()
      if not usable then return false, failure end
      return sink:fail("tar: add_file: " .. trouble)
    end
  end
  return sink:put(pad_bytes(size))
end

function EntryWriter:add_dir(path: string, fopts?: Stream.EntryOptions): boolean, string
  fopts = fopts or {}
  local mode = fopts.mode or 0x1ed
  local mtime = fopts.mtime or 0
  local dirpath = path:sub(-1) == "/" and path or (path .. "/")
  return put_entry(self, dirpath, "5", 0, mode, mtime, "")
end

function EntryWriter:add_symlink(path: string, target: string, fopts?: Stream.EntryOptions): boolean, string
  fopts = fopts or {}
  local mode = fopts.mode or 0x1ff
  local mtime = fopts.mtime or 0
  return put_entry(self, path, "2", 0, mode, mtime, target)
end

function EntryWriter:close(): boolean, string
  return self.sink:close(string.rep("\0", 2 * BLOCK))
end

function EntryWriter:abort(): boolean, string
  return self.sink:abort()
end

--- A streaming writer over `w`.
function Tar.writer(w: Stream.Writer, opts?: Tar.WriterOptions): Tar.Writer
  opts = opts or {}
  local tw: EntryWriter = setmetatable({
    sink = Stream.sticky(w, "tar"), deterministic = opts.deterministic or false,
  }, entry_writer_mt)
  return tw
end

return Tar
