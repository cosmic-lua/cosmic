--- A streaming tar reader and writer: ustar, GNU long name/link (`L`/`K`),
--- and pax extended headers (`x` per-entry, `g` global). Entries are
--- walked forward only, one at a time; an entry not read with `open`
--- is skipped automatically when the next one is asked for. Neither
--- side buffers a whole archive: a body is read or written in chunks,
--- so an archive far larger than memory streams through in bounded
--- space. Compression, when there is any, wraps the underlying
--- `Stream.Reader`/`Stream.Writer` before it reaches this module --
--- see `cosmic.archive`.

local Stream = require("cosmic.stream")

local record Tar
  enum Kind
    "file"
    "dir"
    "symlink"
    "hardlink"
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
    --- This entry's body, as a Reader bounded to its size. Valid only
    --- until the next `TarReader.next` call; reading it afterwards
    --- fails.
    open: function(Entry): Stream.Reader
  end

  record TarReader
    --- The next entry, or nil and `""` once the archive's two zero
    --- blocks are reached (or the stream simply ends there).
    next: function(TarReader): Entry | nil, string
  end

  record EntryOptions
    mode: integer
    mtime: integer
    --- Required when the body passed to `add_file` is a Reader rather
    --- than a string, since a tar header states a size before its body.
    size: integer
  end

  record WriterOptions
    --- Forces mtime 0, uid/gid 0 and empty uname/gname on every entry,
    --- so the same tree tars to the same bytes.
    deterministic: boolean
  end

  record TarWriter
    add_file: function(TarWriter, string, string | Stream.Reader, opts?: EntryOptions): boolean, string
    add_dir: function(TarWriter, string, opts?: EntryOptions): boolean, string
    add_symlink: function(TarWriter, string, string, opts?: EntryOptions): boolean, string
    close: function(TarWriter): boolean, string
  end
end

local BLOCK <const> = 512
local EIGHT_GIB <const> = 1 << 33
local chunk_size <const> = 1 << 16

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
  local cut = field:find("\0", 1, true)
  local text = cut and field:sub(1, cut - 1) or field
  text = text:gsub("^%s+", ""):gsub("%s+$", "")
  if text == "" then return 0 end
  return math.tointeger(tonumber(text, 8)) or 0
end

local function checksum_ok(block: string): boolean
  local recorded = numeric(block:sub(149, 156))
  local sum = 256 -- the checksum field itself counts as eight spaces
  for i = 1, 148 do sum = sum + block:byte(i) end
  for i = 157, 512 do sum = sum + block:byte(i) end
  return sum == recorded
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

--- Reads `size` raw bytes and the padding after them, up to the next
--- block boundary, for an `L`/`K`/`x`/`g` special entry's own body.
local function read_special_body(raw: Stream.Reader, size: integer): string | nil, string
  local data, trouble = Stream.read_exact(raw, size)
  if data == nil then return nil, trouble end
  local skip = (BLOCK - (size % BLOCK)) % BLOCK
  local left = skip
  while left > 0 do
    local want = left
    if want > chunk_size then want = chunk_size end
    local chunk, dtrouble = raw:read(want)
    if chunk == nil then
      if dtrouble ~= "" then return nil, dtrouble end
      return nil, "tar: truncated special entry"
    end
    left = left - #chunk
  end
  return data, ""
end

--- The `key=value` records of a pax extended header body, each
--- prefixed with its own decimal byte length.
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
      local value = rec:sub(eq + 1, #rec - 1) -- drop the trailing newline
      out[key] = value
    end
    at = at + len
  end
  return out
end

local function apply_pax(fields: {string:string}, name: string, linkname: string,
    size: integer, mtime: integer, uid: integer, gid: integer):
    string, string, integer, integer, integer, integer
  for key, value in pairs(fields) do
    if key == "path" then name = value
    elseif key == "linkpath" then linkname = value
    elseif key == "size" then size = math.tointeger(math.floor(tonumber(value) or size)) or size
    elseif key == "mtime" then mtime = math.tointeger(math.floor(tonumber(value) or mtime)) or mtime
    elseif key == "uid" then uid = math.tointeger(tonumber(value)) or uid
    elseif key == "gid" then gid = math.tointeger(tonumber(value)) or gid
    end
  end
  return name, linkname, size, mtime, uid, gid
end

local function drain(raw: Stream.Reader, n: integer): boolean, string
  local left = n
  while left > 0 do
    local want = left
    if want > chunk_size then want = chunk_size end
    local chunk, trouble = raw:read(want)
    if chunk == nil then
      if trouble ~= "" then return false, trouble end
      return false, "tar: unexpected end of archive"
    end
    left = left - #chunk
  end
  return true, ""
end

local function kind_of(typeflag: string): Tar.Kind
  if typeflag == "0" or typeflag == "\0" then return "file" end
  if typeflag == "5" then return "dir" end
  if typeflag == "2" then return "symlink" end
  if typeflag == "1" then return "hardlink" end
  return "other"
end

--- A streaming reader over `raw`'s tar bytes.
function Tar.reader(raw: Stream.Reader): Tar.TarReader
  local ended = false
  local pending_skip = 0
  local generation = 0
  local pax_global: {string:string} = {}
  local tr: Tar.TarReader = {}

  tr.next = function(_self: Tar.TarReader): Tar.Entry | nil, string
    if ended then return nil, "" end
    local drained, dtrouble = drain(raw, pending_skip)
    pending_skip = 0
    if not drained then return nil, dtrouble end

    local long_name: string
    local long_link: string
    local pax_local: {string:string}

    while true do
      local block, at_eof, trouble = read_block_or_eof(raw)
      if at_eof then
        ended = true
        return nil, ""
      end
      if block == nil then return nil, trouble end
      if is_zero_block(block) then
        local _second, _second_eof, strouble = read_block_or_eof(raw)
        ended = true
        if strouble ~= "" then return nil, strouble end
        return nil, ""
      end
      if not checksum_ok(block) then
        return nil, "tar: bad header checksum"
      end
      local typeflag = block:sub(157, 157)
      if typeflag == "L" then
        local size = numeric(block:sub(125, 136))
        local data, rtrouble = read_special_body(raw, size)
        if data == nil then return nil, rtrouble end
        long_name = data:gsub("%z.*$", "")
      elseif typeflag == "K" then
        local size = numeric(block:sub(125, 136))
        local data, rtrouble = read_special_body(raw, size)
        if data == nil then return nil, rtrouble end
        long_link = data:gsub("%z.*$", "")
      elseif typeflag == "x" then
        local size = numeric(block:sub(125, 136))
        local data, rtrouble = read_special_body(raw, size)
        if data == nil then return nil, rtrouble end
        pax_local = parse_pax(data)
      elseif typeflag == "g" then
        local size = numeric(block:sub(125, 136))
        local data, rtrouble = read_special_body(raw, size)
        if data == nil then return nil, rtrouble end
        for key, value in pairs(parse_pax(data)) do pax_global[key] = value end
      else
        local name = block:sub(1, 100):gsub("%z.*$", "")
        local prefix = block:sub(346, 500):gsub("%z.*$", "")
        if prefix ~= "" then name = prefix .. "/" .. name end
        if long_name ~= nil then name = long_name end
        local linkname = block:sub(158, 257):gsub("%z.*$", "")
        if long_link ~= nil then linkname = long_link end
        local size = numeric(block:sub(125, 136))
        local mode = numeric(block:sub(101, 108)) & 0xFFF
        local uid = numeric(block:sub(109, 116))
        local gid = numeric(block:sub(117, 124))
        local mtime = numeric(block:sub(137, 148))
        name, linkname, size, mtime, uid, gid =
          apply_pax(pax_global, name, linkname, size, mtime, uid, gid)
        if pax_local ~= nil then
          name, linkname, size, mtime, uid, gid =
            apply_pax(pax_local, name, linkname, size, mtime, uid, gid)
        end

        generation = generation + 1
        local my_generation = generation
        local padding = (BLOCK - (size % BLOCK)) % BLOCK
        pending_skip = size + padding
        local body_left = size

        local entry: Tar.Entry = {
          path = name,
          kind = kind_of(typeflag),
          mode = mode,
          size = size,
          mtime = mtime,
          linkpath = linkname,
          uid = uid,
          gid = gid,
        }
        local opened = false
        entry.open = function(_e: Tar.Entry): Stream.Reader
          if opened then
            -- A second `open` on the same entry would share
            -- `body_left`/`pending_skip` with the first and read
            -- wherever that one left off, silently -- refuse it
            -- instead of handing back a reader that lies about
            -- starting from the beginning.
            local reopened: Stream.Reader = {}
            reopened.read = function(_self2: Stream.Reader, _max: integer): string | nil, string
              return nil, "tar: entry already opened once"
            end
            reopened.close = function(_self2: Stream.Reader): boolean, string
              return true, ""
            end
            return reopened
          end
          opened = true
          local body: Stream.Reader = {}
          body.read = function(_self2: Stream.Reader, max: integer): string | nil, string
            if my_generation ~= generation then
              return nil, "tar: entry is no longer current"
            end
            if body_left <= 0 then return nil, "" end
            local want = max or chunk_size
            if want > body_left then want = body_left end
            local chunk, rtrouble = raw:read(want)
            if chunk == nil then
              if rtrouble ~= "" then return nil, rtrouble end
              return nil, "tar: unexpected end of archive"
            end
            body_left = body_left - #chunk
            pending_skip = pending_skip - #chunk
            return chunk, ""
          end
          body.close = function(_self2: Stream.Reader): boolean, string
            return true, ""
          end
          return body
        end
        return entry, ""
      end
    end
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

local function oct(n: integer, width: integer): string
  local digits = string.format("%0" .. tostring(width - 1) .. "o", n)
  if #digits > width - 1 then digits = digits:sub(-(width - 1)) end
  return digits .. "\0"
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
  local sum = 256
  for i = 1, 148 do sum = sum + block:byte(i) end
  for i = 157, BLOCK do sum = sum + block:byte(i) end
  local checksum = string.format("%06o", sum) .. "\0 "
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

local function write_pax(w: Stream.Writer, real_name: string, records: string): boolean, string
  local base = real_name:match("([^/]+)$") or real_name
  local pax_name = "PaxHeaders/" .. base
  if #pax_name > 100 then pax_name = pax_name:sub(1, 100) end
  local header = build_header(pax_name, "", "x", #records, 0, 0, 0, 0, "", "", "")
  local ok, trouble = w:write(header)
  if not ok then return false, trouble end
  ok, trouble = w:write(records)
  if not ok then return false, trouble end
  local pad = pad_bytes(#records)
  if #pad > 0 then
    ok, trouble = w:write(pad)
    if not ok then return false, trouble end
  end
  return true, ""
end

--- A streaming writer over `w`.
function Tar.writer(w: Stream.Writer, opts?: Tar.WriterOptions): Tar.TarWriter
  opts = opts or {}
  local deterministic = opts.deterministic or false
  local closed = false
  local tw: Tar.TarWriter = {}

  local function put_entry(path: string, typeflag: string, size: integer,
      mode: integer, mtime: integer, linkname: string): boolean, string
    if deterministic then mtime = 0 end
    local uid, gid, uname, gname = 0, 0, "", ""
    local prefix, name, fits = split_ustar(path)
    local link_fits = #linkname <= 100
    local size_fits = size < EIGHT_GIB
    if not (fits and link_fits and size_fits) then
      local records: {string} = {}
      if not fits then records[#records + 1] = pax_record("path", path) end
      if not link_fits then records[#records + 1] = pax_record("linkpath", linkname) end
      if not size_fits then records[#records + 1] = pax_record("size", tostring(size)) end
      local ok, trouble = write_pax(w, path, table.concat(records))
      if not ok then return false, trouble end
      if not fits then prefix, name = "", path:sub(-100) end
    end
    local header_size = size_fits and size or 0
    local header = build_header(name, prefix, typeflag, header_size, mode, uid, gid, mtime,
      linkname, uname, gname)
    return w:write(header)
  end

  tw.add_file = function(_self: Tar.TarWriter, path: string, data: string | Stream.Reader,
      fopts?: Tar.EntryOptions): boolean, string
    fopts = fopts or {}
    local size = fopts.size
    if size == nil then
      if data is string then
        size = #data
      else
        error("tar: add_file needs opts.size for a Reader body", 2)
      end
    end
    local mode = fopts.mode or 0x1a4
    local mtime = fopts.mtime or 0
    local ok, trouble = put_entry(path, "0", size, mode, mtime, "")
    if not ok then return false, trouble end
    if data is string then
      ok, trouble = w:write(data)
      if not ok then return false, trouble end
    else
      local written = 0
      while written < size do
        local want = size - written
        if want > chunk_size then want = chunk_size end
        local chunk, rtrouble = data:read(want)
        if chunk == nil then
          if rtrouble ~= "" then return false, rtrouble end
          return false, "tar: add_file: reader ended before its stated size"
        end
        ok, trouble = w:write(chunk)
        if not ok then return false, trouble end
        written = written + #chunk
      end
    end
    local pad = pad_bytes(size)
    if #pad > 0 then
      ok, trouble = w:write(pad)
      if not ok then return false, trouble end
    end
    return true, ""
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
    if closed then return true, "" end
    closed = true
    local ok, trouble = w:write(string.rep("\0", 2 * BLOCK))
    if not ok then return false, trouble end
    return w:close()
  end

  return tw
end

return Tar
