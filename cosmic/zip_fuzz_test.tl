--- Fuzz properties for `cosmic.zip`: the reader is total -- whatever
--- bytes it is handed, it returns entries or a failure and never raises
--- or runs away -- and what the writer writes, the reader reads back.
--- `FUZZ_SEED` and `FUZZ_ITERS` pick the inputs (build/fuzz/init.tl).

local Fuzz = require("build.fuzz")
local Stream = require("cosmic.stream")
local Zip = require("cosmic.zip")

local PARTS <const> = { "a", "b", "dir", "x.txt", "é", "a b", "..", ".", "" }

local function gen_path(src: Fuzz.Source): string
  local parts: {string} = {}
  for i = 1, src:int(1, 3) do parts[i] = Fuzz.pick(src, PARTS) end
  return table.concat(parts, "/")
end

--- Entries as `Fuzz.pack` fields: a kind ("file" or "dir"), a path, a
--- method, and a body, repeated.
local function gen_entries(src: Fuzz.Source): {string}
  local fields: {string} = {}
  for _ = 1, src:int(0, 4) do
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
    local kind, path, method, body = fields[i], fields[i + 1], fields[i + 2], fields[i + 3]
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
    return true, ""
  end
  local ended = false
  for _ = 1, 10000 do
    local e, ntrouble = zr:next()
    if e == nil then
      if ntrouble == nil then return false, "next: nil without a reason" end
      ended = true
      break
    else
      if e.size < 0 or e.compressed_size < 0 then
        return false, ("%s: a negative size"):format(e.path)
      end
      local body = e:open()
      if body ~= nil then
        local data = Stream.read_all(body)
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
  })
end

local function test_the_reader_is_total_on_arbitrary_bytes(tmp: string)
  Fuzz.run({
    name = "zip reader total on bytes",
    dir = tmp,
    gen = function(src: Fuzz.Source): string
      -- An end-of-central-directory signature, so some inputs get past
      -- the search for one.
      local tail = src:int(0, 1) == 1 and "PK\5\6" .. Fuzz.bytes(src, 40) or ""
      return Fuzz.bytes(src, 400) .. tail
    end,
    check = walk,
  })
end

local function test_what_the_writer_writes_the_reader_reads_back(tmp: string)
  Fuzz.run({
    name = "zip round trip",
    dir = tmp,
    gen = function(src: Fuzz.Source): string
      return Fuzz.pack(gen_entries(src))
    end,
    check = function(input: string): boolean, string
      local fields = Fuzz.unpack(input)
      local archive = write(fields)
      if archive == nil then return true, "" end
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
