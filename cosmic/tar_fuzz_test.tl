--- Fuzz properties for `cosmic.tar`: the reader is total -- whatever
--- bytes it is handed, it returns entries or a failure and never raises
--- or runs away -- and what the writer writes, the reader reads back.
--- `FUZZ_SEED` and `FUZZ_ITERS` pick the inputs (build/fuzz/init.tl).

local Fuzz = require("build.fuzz")
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

--- Walks every entry of `input`, reading each body: fails only when the
--- reader answers something no archive could mean.
local function walk(input: string): boolean, string
  local tr = Tar.reader(Stream.from_string(input))
  for _ = 1, 10000 do
    local e, trouble = tr:next()
    if e == nil then
      if trouble == nil then return false, "next: nil without a reason" end
      Fuzz.label(trouble == "" and "ended" or "refused")
      return true, ""
    end
    Fuzz.label("entry")
    if e.size < 0 then return false, "an entry of negative size: " .. e.size end
    local body = e:open()
    if body ~= nil then
      local data = Stream.read_all(body)
      if data ~= nil then Fuzz.label("body read") end
      if data ~= nil and e.kind == "file" and #data ~= e.size then
        return false, ("%s: read %d bytes of a body of %d"):format(e.path, #data, e.size)
      end
    end
  end
  return false, "more than 10000 entries from one input"
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

-- TODO: no input of 2000 reads an entry: none gets past a header, whose checksum
-- random bytes never match, so this checks only that refusal; drawing
-- header fields and writing their checksum would reach the field
-- parsing behind it.
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
