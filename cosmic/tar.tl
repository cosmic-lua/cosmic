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

--- The sum of up to 32 byte values, passed as `string.byte` returns
--- them: summing a header 32 bytes to a call, rather than one `byte`
--- call per byte or a table of all 512, is what keeps walking a tar of
--- many small entries cheap.
local function add32(...: integer): integer
  local b1, b2, b3, b4, b5, b6, b7, b8, b9, b10, b11, b12, b13, b14, b15, b16, b17, b18, b19, b20, b21, b22, b23, b24, b25, b26, b27, b28, b29, b30, b31, b32 = ...
  return (b1 or 0) + (b2 or 0) + (b3 or 0) + (b4 or 0) + (b5 or 0) + (b6 or 0) + (b7 or 0) +
    (b8 or 0) + (b9 or 0) + (b10 or 0) + (b11 or 0) + (b12 or 0) + (b13 or 0) + (b14 or 0) +
    (b15 or 0) + (b16 or 0) + (b17 or 0) + (b18 or 0) + (b19 or 0) + (b20 or 0) + (b21 or 0) +
    (b22 or 0) + (b23 or 0) + (b24 or 0) + (b25 or 0) + (b26 or 0) + (b27 or 0) + (b28 or 0) +
    (b29 or 0) + (b30 or 0) + (b31 or 0) + (b32 or 0)
end

local ZERO32 <const> = string.rep("\0", 32)

--- The header checksum: every byte summed, the checksum field itself
--- (bytes 149 to 156) counted as eight spaces. All-zero stretches,
--- most of a typical header, are passed over without summing.
local function header_sum(block: string): integer
  local sum = 256 - add32(block:byte(149, 156))
  for i = 1, BLOCK, 32 do
    if block:sub(i, i + 31) ~= ZERO32 then sum = sum + add32(block:byte(i, i + 31)) end
  end
  return sum
end

local function checksum_ok(block: string): boolean
  return header_sum(block) == numeric(block:sub(149, 156))
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

--- A streaming reader over `raw`'s tar bytes. Closing it closes `raw`.
function Tar.reader(raw: Stream.Reader): Tar.TarReader
  local ended = false
  local failed: string
  local closed = false
  local pending_skip = 0
  local generation = 0
  local pax_global: {string:string} = {}
  local tr: Tar.TarReader = {}

  local function fail(trouble: string): nil, string
    failed = trouble ~= "" and trouble or "tar: read failed"
    return nil, failed
  end

  tr.next = function(_self: Tar.TarReader): Tar.Entry | nil, string
    if failed then return nil, failed end
    if closed then return nil, "tar: reader is closed" end
    if ended then return nil, "" end
    generation = generation + 1
    local skipped, dtrouble = Stream.skip(raw, pending_skip)
    pending_skip = 0
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
      local block, at_eof, trouble = read_block_or_eof(raw)
      if at_eof then
        ended = true
        return nil, ""
      end
      if block == nil then return fail(trouble) end
      if is_zero_block(block) then
        local _second, _second_eof, strouble = read_block_or_eof(raw)
        if strouble ~= "" then return fail(strouble) end
        ended = true
        return nil, ""
      end
      if not checksum_ok(block) then
        return fail("tar: bad header checksum")
      end
      local typeflag = block:sub(157, 157)
      if typeflag == "L" or typeflag == "K" or typeflag == "x" or typeflag == "g" then
        local data, rtrouble = read_special_body(raw, numeric(block:sub(125, 136)))
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
        local name = block:sub(1, 100):match("^[^%z]*")
        local prefix = block:sub(346, 500):match("^[^%z]*")
        if prefix ~= "" then name = prefix .. "/" .. name end
        if long_name ~= nil then name = long_name end
        local linkname = block:sub(158, 257):match("^[^%z]*")
        if long_link ~= nil then linkname = long_link end
        local f: Fields = {
          name = name,
          linkname = linkname,
          size = numeric(block:sub(125, 136)),
          mtime = numeric(block:sub(137, 148)),
          uid = numeric(block:sub(109, 116)),
          gid = numeric(block:sub(117, 124)),
          sparse = false,
        }
        local mode = numeric(block:sub(101, 108)) & 0xFFF
        local ok, ptrouble = apply_pax(pax_global, f)
        if ok and pax_local ~= nil then ok, ptrouble = apply_pax(pax_local, f) end
        if not ok then return fail(ptrouble) end
        if f.size < 0 then return fail("tar: negative entry size") end

        local my_generation = generation
        local size = f.size
        pending_skip = size + padding_of(size)
        local body_left = size

        local kind = kind_of(typeflag)
        if typeflag == "S" or f.sparse then kind = "other" end
        local entry: Tar.Entry = {
          path = f.name,
          kind = kind,
          mode = mode,
          size = size,
          mtime = f.mtime,
          linkpath = f.linkname,
          uid = f.uid,
          gid = f.gid,
          typeflag = typeflag,
        }
        local opened = false
        entry.open = function(_e: Tar.Entry): Stream.Reader | nil, string
          -- A second `open` on the same entry would share
          -- `body_left`/`pending_skip` with the first and read
          -- wherever that one left off, silently -- refuse it.
          if opened then return nil, "tar: entry already opened once" end
          if my_generation ~= generation then
            return nil, "tar: entry is no longer current"
          end
          opened = true
          local body_failed: string
          local body_closed = false
          local body: Stream.Reader = {}
          body.read = function(_self2: Stream.Reader, max: integer): string | nil, string
            if body_failed then return nil, body_failed end
            if body_closed then return nil, "tar: entry body is closed" end
            if my_generation ~= generation then
              return nil, "tar: entry is no longer current"
            end
            if body_left <= 0 then return nil, "" end
            local want = max or (1 << 16)
            if want > body_left then want = body_left end
            local chunk, rtrouble = raw:read(want)
            if chunk == nil then
              body_failed = rtrouble ~= "" and rtrouble or "tar: unexpected end of archive"
              return nil, body_failed
            end
            body_left = body_left - #chunk
            pending_skip = pending_skip - #chunk
            return chunk, ""
          end
          body.close = function(_self2: Stream.Reader): boolean, string
            body_closed = true
            return true, ""
          end
          return body, ""
        end
        return entry, ""
      end
    end
  end

  tr.close = function(_self: Tar.TarReader): boolean, string
    if closed then return true, "" end
    closed = true
    generation = generation + 1
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
