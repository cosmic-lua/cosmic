--- Fuzz properties for `cosmic.zip`: the reader is total -- whatever
--- bytes it is handed, it returns entries or a failure and never raises
--- or runs away -- and what the writer writes, the reader reads back.
--- `FUZZ_SEED` and `FUZZ_ITERS` pick the inputs (build/fuzz/init.tl).

local Compress = require("cosmic.compress")
local Fuzz = require("build.fuzz")
local Stream = require("cosmic.stream")
local Zip = require("cosmic.zip")

local PARTS <const> = { "a", "b", "dir", "x.txt", "é", "a b", "..", ".", "" }

local function gen_path(src: Fuzz.Source): string
  local parts: {string} = {}
  repeat parts[#parts + 1] = Fuzz.pick(src, PARTS) until not Fuzz.more(src, #parts, 3)
  return table.concat(parts, "/")
end

--- Entries as `Fuzz.pack` fields: a kind ("file" or "dir"), a path, a
--- method, and a body, repeated.
local function gen_entries(src: Fuzz.Source): {string}
  local fields: {string} = {}
  while Fuzz.more(src, #fields // 4, 4) do
    local kind = Fuzz.pick(src, { "file", "file", "dir" })
    fields[#fields + 1] = kind
    fields[#fields + 1] = gen_path(src)
    fields[#fields + 1] = Fuzz.pick(src, { "store", "deflate" })
    local body = ""
    if kind == "file" then
      -- Repetitive bodies give deflate back-references to mutate.
      body = string.rep(Fuzz.bytes(src, 8), src:int(1, 40))
    end
    fields[#fields + 1] = body
  end
  return fields
end

--- The archive the writer makes of `fields`, or nil when it refuses one.
local function write(fields: {string}): string | nil
  local out = Stream.collect()
  local zw = Zip.writer(out, { deterministic = true })
  for i = 1, #fields, 4 do
    local kind, path, name, body = fields[i], fields[i + 1], fields[i + 2], fields[i + 3]
    -- A shrunk input may name no method at all, which the writer
    -- would refuse.
    if kind == "file" and name ~= "store" and name ~= "deflate" then return nil end
    local method: Zip.Method = name == "store" and "store" or "deflate"
    local ok: boolean
    if kind == "file" then
      ok = zw:add_file(path, body, { method = method })
    else
      ok = zw:add_dir(path)
    end
    if not ok then return nil end
  end
  if not zw:close() then return nil end
  return out:result()
end

--- Opens `input` and reads every entry's body, both ways the reader
--- walks: fails only when it answers something no archive could mean.
local function walk(input: string): boolean, string
  local zr, trouble = Zip.open_string(input)
  if zr == nil then
    if trouble == "" then return false, "open: nil without a reason" end
    Fuzz.label(trouble:find("not found", 1, true) and "no end record" or "refused at open")
    return true, ""
  end
  Fuzz.label("opened")
  local ended = false
  for _ = 1, 10000 do
    local e, ntrouble = zr:next()
    if e == nil then
      if ntrouble == nil then return false, "next: nil without a reason" end
      Fuzz.label(ntrouble == "" and "ended" or "refused")
      ended = true
      break
    else
      Fuzz.label("entry")
      if e.size < 0 or e.compressed_size < 0 or e.offset < 0 then
        return false, ("%s: a negative size or offset"):format(e.path)
      end
      local body, otrouble = e:open()
      if body == nil then
        Fuzz.label(otrouble:find("local file header", 1, true) and "local header refused" or
          "body refused")
      end
      if body ~= nil then
        local data = Stream.read_all(body)
        if data ~= nil then Fuzz.label("body read") end
        if data ~= nil and #data ~= e.size then
          return false, ("%s: read %d bytes of a body of %d"):format(e.path, #data, e.size)
        end
      end
    end
  end
  if not ended then return false, "more than 10000 entries from one input" end
  zr:entries()
  zr:close()
  return true, ""
end

local function test_the_reader_is_total_on_mutated_archives(tmp: string)
  Fuzz.run({
    name = "zip reader total",
    dir = tmp,
    gen = function(src: Fuzz.Source): string
      local archive = write(gen_entries(src)) or ""
      return Fuzz.mutate(src, archive, 8)
    end,
    check = walk,
    requires = { "opened", "body read", "no end record" },
  })
end

--- A record's fixed fields, in order, as `string.pack` formats: the
--- widths `hostile` keeps a value within.
local LFH_FIELDS <const> = { "c4", "I2", "I2", "I2", "I2", "I2", "I4", "I4", "I4", "I2", "I2" }
local CDFH_FIELDS <const> = { "c4", "I2", "I2", "I2", "I2", "I2", "I2", "I4", "I4", "I4", "I2", "I2",
  "I2", "I2", "I2", "I4", "I4" }
local Z64_EOCD_FIELDS <const> = { "c4", "i8", "I2", "I2", "I4", "I4", "i8", "i8", "i8", "i8" }
local Z64_LOC_FIELDS <const> = { "c4", "I4", "i8", "I4" }
local EOCD_FIELDS <const> = { "c4", "I2", "I2", "I2", "I2", "I4", "I4", "I2" }

--- One record of a laid-out archive: its fixed fields, by `fields`'
--- formats, and the variable bytes after them. A zip64 extra field's
--- values are a record of their own, so each can be made hostile.
local record Rec
  fields: {string}
  values: {any}
  tail: string
end

local function packed(r: Rec): string
  return string.pack("<" .. table.concat(r.fields), table.unpack(r.values)) .. (r.tail or "")
end

--- A value to put in place of `v`, a field `fmt` wide: off by one either
--- way, zero, all ones (the zip64 sentinel, or -1 at 64 bits), the top
--- bit alone, one of `marks` (where the archive's records start, and its
--- length) give or take a little, or anything that fits.
local function hostile(src: Fuzz.Source, v: integer, fmt: string, marks: {integer}): integer
  local bits = fmt == "I2" and 16 or fmt == "I4" and 32 or 64
  local k = src:int(1, 7)
  local w: integer
  if k == 1 then w = v + 1
  elseif k == 2 then w = v - 1
  elseif k == 3 then w = 0
  elseif k == 4 then w = -1
  elseif k == 5 then w = 1 << (bits - 1)
  elseif k == 6 then w = Fuzz.pick(src, marks) + src:int(-2, 2)
  else w = src:int(math.mininteger, math.maxinteger)
  end
  if bits < 64 then w = w & ((1 << bits) - 1) end
  return w
end

local UNIX_MADE_BY <const> = (3 << 8) | 20
--- External attributes: a regular file, a directory, a symlink, none.
local ATTRS <const> = { 0x81A4 << 16, 0x41ED << 16, 0xA1FF << 16, 0 }

--- An archive laid out record by record, every count, offset, size and
--- length consistent with the bytes around it -- entries of either
--- method (or one no reader knows) and kind, zip64 extra fields and end
--- records, bytes before it and a comment after it that may hold a
--- forged end record -- then up to a few of its fields made hostile.
local function gen_laid_out(src: Fuzz.Source): string
  local out: {string} = {}
  local recs: {Rec} = {}
  local marks: {integer} = {}
  local pos = 0
  local function put(r: Rec)
    recs[#recs + 1] = r
    marks[#marks + 1] = pos
    pos = pos + #packed(r)
  end
  local prefix = src:int(0, 3) == 0 and Fuzz.bytes(src, 16) or ""
  pos = #prefix

  local centrals: {Rec} = {}
  local wides: {Rec} = {}
  local comments: {string} = {}
  local n = 0
  while Fuzz.more(src, n, 4) do
    n = n + 1
    local name = gen_path(src)
    local attrs = Fuzz.pick(src, ATTRS)
    if attrs == ATTRS[2] and src:int(0, 1) == 1 then name = name .. "/" end
    local data = attrs == ATTRS[3] and gen_path(src) or
      string.rep(Fuzz.bytes(src, 8), src:int(0, 20))
    local method = Fuzz.pick(src, { 0, 8, 8, 12 })
    local body = data
    if method == 8 then body = Compress.deflate("raw", data) end
    local crc = Compress.crc32(data)
    local lfh: Rec = {
      fields = LFH_FIELDS,
      values = { "PK\3\4", 20, 0, method, 0, 0x21, crc, #body, #data, #name, 0 },
      tail = name .. body,
    }
    local offset = pos
    put(lfh)
    -- A central header's zip64 field holds the values its sentinels
    -- stand for, in order; an unknown field may come before it.
    local usize, csize, loff = #data, #body, offset
    local wide: {integer} = {}
    if src:int(0, 2) == 0 then
      if src:int(0, 1) == 1 then wide[#wide + 1] = usize; usize = 0xFFFFFFFF end
      if src:int(0, 1) == 1 then wide[#wide + 1] = csize; csize = 0xFFFFFFFF end
      if src:int(0, 1) == 1 then wide[#wide + 1] = loff; loff = 0xFFFFFFFF end
    end
    local before = ""
    if src:int(0, 3) == 0 then
      local junk = Fuzz.bytes(src, 8)
      before = string.pack("<I2s2", 0xCAFE, junk)
    end
    local fmts: {string} = { "I2", "I2" }
    local vals: {any} = { 1, 8 * #wide }
    for i, v in ipairs(wide) do fmts[i + 2] = "i8"; vals[i + 2] = v end
    local z64: Rec = { fields = fmts, values = vals, tail = "" }
    local extra_len = #before + (#wide > 0 and #packed(z64) or 0)
    local comment = src:int(0, 3) == 0 and Fuzz.bytes(src, 8) or ""
    centrals[n] = {
      fields = CDFH_FIELDS,
      values = { "PK\1\2", UNIX_MADE_BY, 20, 0, method, 0, 0x21, crc, csize, usize, #name,
        extra_len, #comment, 0, 0, attrs, loff },
      tail = name .. before,
    }
    wides[n] = #wide > 0 and z64 or nil
    comments[n] = comment
  end

  local cd_offset = pos
  for i = 1, n do
    put(centrals[i])
    if wides[i] ~= nil then put(wides[i]) end
    put({ fields = {}, values = {}, tail = comments[i] })
  end
  local cd_size = pos - cd_offset
  local total, eocd_size, eocd_offset = n, cd_size, cd_offset
  if src:int(0, 3) == 0 then
    local z64_off = pos
    put({
      fields = Z64_EOCD_FIELDS,
      values = { "PK\6\6", 44, UNIX_MADE_BY, 45, 0, 0, n, n, cd_size, cd_offset },
    })
    put({ fields = Z64_LOC_FIELDS, values = { "PK\6\7", 0, z64_off, 1 } })
    total, eocd_size, eocd_offset = 0xFFFF, 0xFFFFFFFF, 0xFFFFFFFF
  end
  -- A comment may hold a forged end record of its own.
  local comment = src:int(0, 3) == 0 and "PK\5\6" .. Fuzz.bytes(src, 24) or Fuzz.bytes(src, 4)
  put({
    fields = EOCD_FIELDS,
    values = { "PK\5\6", 0, 0, total, total, eocd_size, eocd_offset, #comment },
    tail = comment,
  })
  marks[#marks + 1] = pos

  local edits = 0
  while Fuzz.more(src, edits, 3) do
    edits = edits + 1
    local r = recs[src:int(1, #recs)]
    local at: integer
    if n > 0 and src:int(0, 2) == 0 then
      -- An entry's local header offset, which only reading its body
      -- follows: few of the fields drawn at random are one.
      r = centrals[src:int(1, n)]
      at = #CDFH_FIELDS
    elseif #r.fields > 0 then
      -- Leave the signature, the one field every check starts from.
      at = src:int(r.fields[1] == "c4" and 2 or 1, #r.fields)
    end
    if at ~= nil then
      r.values[at] = hostile(src, r.values[at] as integer, r.fields[at], marks)
    end
  end

  out[1] = prefix
  for _, r in ipairs(recs) do out[#out + 1] = packed(r) end
  return table.concat(out)
end

local function test_the_reader_is_total_on_hostile_records(tmp: string)
  Fuzz.run({
    name = "zip reader total on records",
    dir = tmp,
    gen = gen_laid_out,
    check = walk,
    requires = { "opened", "entry", "body read", "local header refused", "refused at open" },
  })
end

local function test_what_the_writer_writes_the_reader_reads_back(tmp: string)
  Fuzz.run({
    name = "zip round trip",
    dir = tmp,
    gen = function(src: Fuzz.Source): string
      return Fuzz.pack(gen_entries(src))
    end,
    requires = { "written" },
    check = function(input: string): boolean, string
      local fields = Fuzz.unpack(input)
      local archive = write(fields)
      if archive == nil then return true, "" end
      Fuzz.label("written")
      local zr, trouble = Zip.open_string(archive)
      if zr == nil then return false, "open: " .. trouble end
      for i = 1, #fields, 4 do
        local kind, path, body = fields[i], fields[i + 1], fields[i + 3]
        local e, ntrouble = zr:next()
        if e == nil then return false, ("entry %d (%q): %s"):format(i // 4 + 1, path, ntrouble) end
        if (e.path:gsub("/+$", "")) ~= (path:gsub("/+$", "")) then
          return false, ("wrote path %q, read %q"):format(path, e.path)
        end
        if tostring(e.kind) ~= kind then
          return false, ("%q: wrote a %s, read a %s"):format(path, kind, tostring(e.kind))
        end
        if kind == "file" then
          local r, otrouble = e:open()
          if r == nil then return false, ("%q: open: %s"):format(path, otrouble) end
          local data, rtrouble = Stream.read_all(r)
          if data ~= body then return false, ("%q: the body differs: %s"):format(path, rtrouble) end
        end
      end
      local e, ntrouble = zr:next()
      if e ~= nil then return false, "read an entry past the last written: " .. e.path end
      if ntrouble ~= "" then return false, "the end read as a failure: " .. ntrouble end
      zr:close()
      return true, ""
    end,
  })
end
