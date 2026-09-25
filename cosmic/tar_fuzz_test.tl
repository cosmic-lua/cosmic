--- Fuzz properties for `cosmic.tar`: the reader is total -- whatever
--- bytes it is handed, it returns entries or a failure and never raises
--- or runs away -- and what the writer writes, the reader reads back.
--- `FUZZ_SEED` and `FUZZ_ITERS` pick the inputs (build/fuzz/init.tl).

local Fuzz = require("build.fuzz")
local Hash = require("cosmic.hash")
local Stream = require("cosmic.stream")
local Tar = require("cosmic.tar")

--- Path components a tar header has to carry: a name too long for the
--- ustar fields, ones only pax can hold, and ones an extractor refuses.
local PARTS <const> = { "a", "b", "dir", "x.txt", "é", "a b", "..", ".", "-", "", "\\" }

local function gen_path(src: Fuzz.Source): string
  local parts: {string} = {}
  repeat
    if src:int(1, 8) == 1 then
      parts[#parts + 1] = string.rep("n", src:int(90, 160))
    else
      parts[#parts + 1] = Fuzz.pick(src, PARTS)
    end
  until not Fuzz.more(src, #parts, 4)
  local path = table.concat(parts, "/")
  if src:int(1, 8) == 1 then path = "/" .. path end
  return path
end

--- Entries as `Fuzz.pack` fields: a kind, a path, and a body (a file's
--- bytes, a link's target, nothing for a directory), repeated.
local function gen_entries(src: Fuzz.Source): {string}
  local fields: {string} = {}
  while Fuzz.more(src, #fields // 3, 5) do
    local kind = Fuzz.pick(src, { "file", "dir", "symlink" })
    local body = ""
    if kind == "file" then
      body = Fuzz.bytes(src, src:int(0, 1) == 0 and 16 or 1100)
    elseif kind == "symlink" then
      body = gen_path(src)
    end
    fields[#fields + 1] = kind
    fields[#fields + 1] = gen_path(src)
    fields[#fields + 1] = body
  end
  return fields
end

--- The archive the writer makes of `fields`, or nil when it refuses one.
local function write(fields: {string}): string | nil
  local out = Stream.collect()
  local tw = Tar.writer(out, { deterministic = true })
  for i = 1, #fields, 3 do
    local kind, path, body = fields[i], fields[i + 1], fields[i + 2]
    local ok: boolean
    if kind == "file" then
      ok = tw:add_file(path, body)
    elseif kind == "dir" then
      ok = tw:add_dir(path)
    else
      ok = tw:add_symlink(path, body)
    end
    if not ok then return nil end
  end
  if not tw:close() then return nil end
  return out:result()
end

--- The entries a reader finds in `input`, each as its path, kind and
--- size, and how the walk ended: `""` at the archive's end, else the
--- failure. Each body is read when `read` is true and left for `next`
--- to skip otherwise. Nil and why when the reader answers something no
--- archive could mean.
local function entries_of(input: string, read: boolean): {string} | nil, string
  local tr = Tar.reader(Stream.from_string(input))
  local seen: {string} = {}
  for _ = 1, 10000 do
    local e, trouble = tr:next()
    if e == nil then
      if trouble == nil then return nil, "next: nil without a reason" end
      if read then Fuzz.label(trouble == "" and "ended" or "refused") end
      seen[#seen + 1] = trouble == "" and "ended" or "refused"
      return seen, ""
    end
    if e.size < 0 then return nil, "an entry of negative size: " .. e.size end
    seen[#seen + 1] = ("%q %s %d"):format(e.path, e.kind, e.size)
    if read then
      Fuzz.label("entry")
      if #e.path > 100 then Fuzz.label("long path") end
      local body = e:open()
      if body ~= nil then
        -- Every other body is asked for whole, its size in one read, as
        -- a caller that trusts the header would; the rest in chunks.
        local data: string = nil
        if #seen % 2 == 0 and e.size > 0 then
          local first, ftrouble = body:read(e.size)
          if first ~= nil then
            local rest = Stream.read_all(body)
            if rest ~= nil then data = first .. rest end
          elseif ftrouble == "" then
            data = ""
          end
        else
          data = Stream.read_all(body)
        end
        if data ~= nil then Fuzz.label("body read") end
        if data ~= nil and e.kind == "file" and #data ~= e.size then
          return nil, ("%s: read %d bytes of a body of %d"):format(e.path, #data, e.size)
        end
      end
    end
  end
  return nil, "more than 10000 entries from one input"
end

--- Walks every entry of `input`, reading each body, then again leaving
--- every body for `next` to skip: fails when the reader answers
--- something no archive could mean, or when skipping a body leaves it
--- somewhere reading the body does not.
local function walk(input: string): boolean, string
  local read, trouble = entries_of(input, true)
  if read == nil then return false, trouble end
  local skipped, strouble = entries_of(input, false)
  if skipped == nil then return false, "skipping bodies: " .. strouble end
  for i = 1, math.max(#read, #skipped) do
    if read[i] ~= skipped[i] then
      return false, ("entry %d: %s when its bodies are read, %s when they are skipped"):
        format(i, read[i] or "nothing", skipped[i] or "nothing")
    end
  end
  return true, ""
end

local function test_the_reader_is_total_on_mutated_archives(tmp: string)
  Fuzz.run({
    name = "tar reader total",
    dir = tmp,
    gen = function(src: Fuzz.Source): string
      local archive = write(gen_entries(src)) or ""
      return Fuzz.mutate(src, archive, 8)
    end,
    check = walk,
    requires = { "entry", "body read" },
  })
end

-- Nearly every input here is refused at its first header, whose
-- checksum random bytes never match: this checks that refusal and a
-- short read's, and `test_the_reader_is_total_on_drawn_headers` reaches
-- what lies behind them.
local function test_the_reader_is_total_on_arbitrary_bytes(tmp: string)
  Fuzz.run({
    name = "tar reader total on bytes",
    dir = tmp,
    gen = function(src: Fuzz.Source): string
      return Fuzz.bytes(src, 1600)
    end,
    check = walk,
  })
end

--- `s` fitted to a `width`-byte field: cut to it, or NUL padded.
local function field(s: string, width: integer): string
  if #s >= width then return s:sub(1, width) end
  return s .. string.rep("\0", width - #s)
end

--- What a numeric field holds besides octal digits: a sign, a hex or
--- decimal spelling, digits no octal field has, and blanks.
local NOT_OCTAL <const> = { "8", "9", "-1", "+7", "0x1f", "1e9", " ", "7 7", "\0" .. "17", "\xff" }

--- A `width`-byte numeric field meant to hold `v`, in one of the
--- spellings a reader meets: octal NUL or space terminated, digits
--- filling the field with no terminator, GNU base-256 (`v` itself or
--- any bytes, so past 64 bits too), text no octal field holds, blanks,
--- or every digit a 7.
local function numeric_field(src: Fuzz.Source, width: integer, v: integer): string
  local how = src:int(1, 12)
  if how <= 5 then
    return field(("%0" .. (width - 1) .. "o"):format(v) .. "\0", width)
  elseif how == 6 then
    return field(("%" .. (width - 2) .. "o \0"):format(v), width)
  elseif how == 7 then
    return ("%0" .. width .. "o"):format(v):sub(-width)
  elseif how == 8 then
    local b = string.pack(">i8", v)
    if width > 8 then
      b = string.rep(v < 0 and "\xff" or "\0", width - 8) .. b
    else
      b = b:sub(-width)
    end
    return string.char(b:byte(1) | 0x80) .. b:sub(2)
  elseif how == 9 then
    local b: {string} = { string.char(0x80 | src:int(0, 0x7f)) }
    for i = 2, width do b[i] = string.char(src:int(0, 255)) end
    return table.concat(b)
  elseif how == 10 then
    return field(Fuzz.pick(src, NOT_OCTAL) .. ("%o"):format(v), width)
  elseif how == 11 then
    return string.rep(src:int(0, 1) == 0 and "\0" or " ", width)
  end
  return string.rep("7", width)
end

--- Typeflags: each kind the reader tells apart, the special headers it
--- reads a body of, and ones it does not know.
local TYPEFLAGS <const> = { "0", "\0", "7", "1", "2", "5", "S", "3", "6", "A", "\xff", "L", "K", "x", "g" }

--- Keys a pax header carries: the ones the reader applies, a sparse
--- one that makes an entry "other", and one it ignores.
local PAX_KEYS <const> = { "path", "linkpath", "size", "mtime", "uid", "gid", "GNU.sparse.map", "comment" }

--- Values for them: numbers in spellings `tonumber` reads differently,
--- ones past 64 bits, a NUL, and paths.
local PAX_VALUES <const> = {
  "0", "1", "12", "-1", "1.5", "1e3", "0x10", "nan", "inf", "9223372036854775807",
  -- Either side of the largest size whose padding cannot wrap.
  "9223372036854775295", "9223372036854775296",
  "99999999999999999999", "a\0b", "", "dir/x.txt",
}

--- A path past the 100 bytes a ustar name field holds: what only a
--- prefix, a GNU long name or a pax path can carry.
local function long_path(src: Fuzz.Source): string
  return string.rep("n", src:int(60, 160)) .. "/" .. gen_path(src)
end

--- One pax record, `<length> key=value\n`, its length counted right
--- unless the draw says otherwise.
local function pax_record(src: Fuzz.Source): string
  local key = Fuzz.pick(src, PAX_KEYS)
  local value: string
  local how = src:int(0, 3)
  if how == 0 then
    value = gen_path(src)
  elseif how == 1 then
    value = long_path(src)
  else
    value = Fuzz.pick(src, PAX_VALUES)
  end
  local rest = " " .. key .. "=" .. value .. "\n"
  local len = #rest + 1
  while #tostring(len) + #rest ~= len do len = #tostring(len) + #rest end
  if src:int(0, 7) == 0 then len = len + src:int(-3, 3) end
  return tostring(len) .. rest
end

--- A special header's body: a GNU long name or link, sometimes with a
--- NUL inside it, or pax records, sometimes cut short.
local function special_body(src: Fuzz.Source, typeflag: string): string
  if typeflag == "L" or typeflag == "K" then
    local name = src:int(0, 1) == 0 and long_path(src) or gen_path(src)
    if src:int(0, 7) == 0 then name = name .. "\0" .. gen_path(src) end
    return name .. string.rep("\0", src:int(0, 2))
  end
  local records: {string} = {}
  while Fuzz.more(src, #records, 4) do records[#records + 1] = pax_record(src) end
  local body = table.concat(records)
  if src:int(0, 7) == 0 then body = body:sub(1, src:int(0, #body)) end
  return body
end

--- One header block for `typeflag`, its size field meant to say `size`:
--- each field drawn, hostile ones among them, and its checksum written
--- right unless the draw says otherwise.
local function header(src: Fuzz.Source, typeflag: string, size: integer): string
  local prefix = ""
  local with_prefix = src:int(0, 3)
  if with_prefix == 0 then
    prefix = gen_path(src)
  elseif with_prefix == 1 then
    prefix = long_path(src)
  end
  local linkname = ""
  if typeflag == "1" or typeflag == "2" or src:int(0, 7) == 0 then linkname = gen_path(src) end
  local parts: {string} = {
    field(gen_path(src), 100),
    numeric_field(src, 8, src:int(0, 0x1ff)),
    numeric_field(src, 8, src:int(0, 70000)),
    numeric_field(src, 8, src:int(0, 70000)),
    -- A size misread misplaces every header after it, so it is spelled
    -- plainly more often than the other fields.
    src:int(0, 3) ~= 0 and field(("%011o"):format(size) .. "\0", 12) or numeric_field(src, 12, size),
    numeric_field(src, 12, src:int(-1, 1 << 34)),
    "        ",
    typeflag,
    field(linkname, 100),
    Fuzz.pick(src, { "ustar\0" .. "00", "ustar  \0", string.rep("\0", 8) }),
    string.rep("\0", 32 + 32 + 8 + 8),
    field(prefix, 155),
    string.rep("\0", 12),
  }
  local block = table.concat(parts)
  local sum = Hash.byte_sum(block)
  if src:int(0, 15) == 0 then sum = sum + src:int(1, 64) end
  return block:sub(1, 148) .. ("%06o\0 "):format(sum) .. block:sub(157)
end

--- An archive drawn header by header: each entry's header, then its
--- body -- a special header's records, or bytes whose count the size
--- field usually states -- padded to a block, usually; then the end.
local function gen_archive(src: Fuzz.Source): string
  local out: {string} = {}
  local entries = 0
  while Fuzz.more(src, entries, 6) do
    entries = entries + 1
    local typeflag = Fuzz.pick(src, TYPEFLAGS)
    local body: string
    if typeflag == "L" or typeflag == "K" or typeflag == "x" or typeflag == "g" then
      body = special_body(src, typeflag)
    else
      local len = src:int(0, 3) == 0 and src:int(0, 1100) or src:int(0, 24)
      body = string.rep(string.char(src:int(0, 255)), len)
    end
    local size = #body
    if src:int(0, 7) == 0 then size = size + src:int(-600, 600) end
    out[#out + 1] = header(src, typeflag, size)
    out[#out + 1] = body
    if src:int(0, 7) ~= 0 then out[#out + 1] = string.rep("\0", (512 - #body % 512) % 512) end
  end
  local ending = src:int(1, 5)
  if ending <= 2 then
    out[#out + 1] = string.rep("\0", 1024)
  elseif ending == 3 then
    out[#out + 1] = string.rep("\0", 512)
  elseif ending == 4 then
    out[#out + 1] = Fuzz.bytes(src, 600)
  end
  return table.concat(out)
end

local function test_the_reader_is_total_on_drawn_headers(tmp: string)
  Fuzz.run({
    name = "tar reader total on headers",
    dir = tmp,
    gen = gen_archive,
    check = walk,
    requires = { "entry", "body read", "long path", "ended", "refused" },
  })
end

local function strip_slash(path: string): string
  return (path:gsub("/+$", ""))
end

local function test_what_the_writer_writes_the_reader_reads_back(tmp: string)
  Fuzz.run({
    name = "tar round trip",
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
      local tr = Tar.reader(Stream.from_string(archive))
      for i = 1, #fields, 3 do
        local kind, path, body = fields[i], fields[i + 1], fields[i + 2]
        local e, trouble = tr:next()
        if e == nil then return false, ("entry %d (%q): %s"):format(i // 3 + 1, path, trouble) end
        if strip_slash(e.path) ~= strip_slash(path) then
          return false, ("wrote path %q, read %q"):format(path, e.path)
        end
        if tostring(e.kind) ~= kind then
          return false, ("%q: wrote a %s, read a %s"):format(path, kind, e.kind)
        end
        if kind == "file" then
          local r = e:open()
          local data = r and Stream.read_all(r)
          if data ~= body then return false, ("%q: the body differs"):format(path) end
        elseif kind == "symlink" and e.linkpath ~= body then
          return false, ("%q: wrote target %q, read %q"):format(path, body, e.linkpath)
        end
      end
      local e, trouble = tr:next()
      if e ~= nil then return false, "read an entry past the last written: " .. e.path end
      if trouble ~= "" then return false, "the end read as a failure: " .. trouble end
      return true, ""
    end,
  })
end
