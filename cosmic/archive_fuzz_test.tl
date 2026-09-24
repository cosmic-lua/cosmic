--- Fuzz properties for `cosmic.archive`: opening is total over any bytes,
--- plain or behind a compressor's magic, and extraction never writes
--- outside its destination or leaves a link there that leads out of it,
--- whatever paths, links and options an archive combines.
--- `FUZZ_SEED` and `FUZZ_ITERS` pick the inputs (build/fuzz/init.tl).

local Archive = require("cosmic.archive")
local Compress = require("cosmic.compress")
local Fs = require("cosmic.fs")
local Fuzz = require("build.fuzz")
local Stream = require("cosmic.stream")
local Tar = require("cosmic.tar")
local Zip = require("cosmic.zip")
local sys = require("cosmic.sys")

--- `@OUT@` stands for the directory beside the destination that nothing
--- may reach, spelled absolutely: the generator runs before the check
--- knows where that is.
local PARTS <const> = { "a", "b", "link", "..", ".", "", "@OUT@" }
local TARGETS <const> = { "a", "b", "..", "../..", "link", "link/..", "a/../..", "/", "@OUT@", "@OUT@/x", "../outside" }

local function gen_path(src: Fuzz.Source, from: {string}): string
  local parts: {string} = {}
  for i = 1, src:int(1, 3) do parts[i] = Fuzz.pick(src, from) end
  return table.concat(parts, "/")
end

--- An extraction as `Fuzz.pack` fields: a format, the `links` option,
--- the `strip` option, then a kind, a path and a body per entry.
local function gen_extraction(src: Fuzz.Source): string
  local format = Fuzz.pick(src, { "tar", "tar.gz", "zip" })
  local fields: {string} = { format, Fuzz.pick(src, { "skip", "create" }), Fuzz.pick(src, { "", "1", "a" }) }
  for _ = 1, src:int(1, 6) do
    local kind = Fuzz.pick(src, { "file", "dir", "symlink" })
    if format == "zip" and kind == "symlink" then kind = "file" end
    fields[#fields + 1] = kind
    fields[#fields + 1] = gen_path(src, PARTS)
    fields[#fields + 1] = kind == "symlink" and Fuzz.pick(src, TARGETS) or
      (kind == "file" and Fuzz.bytes(src, 8) or "")
  end
  return Fuzz.pack(fields)
end

--- The archive `fields` describe, with `@OUT@` spelled as `outside`.
local function build(fields: {string}, outside: string): string | nil
  local out = Stream.collect()
  local format = fields[1]
  local function place(s: string): string
    return (s:gsub("@OUT@", outside))
  end
  if format == "zip" then
    local zw = Zip.writer(out, { deterministic = true })
    for i = 4, #fields, 3 do
      local path = place(fields[i + 1])
      if fields[i] == "dir" then zw:add_dir(path) else zw:add_file(path, fields[i + 2]) end
    end
    if not zw:close() then return nil end
    return out:result()
  end
  local tw = Tar.writer(out, { deterministic = true })
  for i = 4, #fields, 3 do
    local kind, path = fields[i], place(fields[i + 1])
    if kind == "file" then
      tw:add_file(path, fields[i + 2])
    elseif kind == "dir" then
      tw:add_dir(path)
    else
      tw:add_symlink(path, place(fields[i + 2]))
    end
  end
  if not tw:close() then return nil end
  local archive = out:result()
  if format == "tar.gz" then
    local enc = Compress.deflater("gzip")
    if enc == nil then return nil end
    local head = enc:update(archive) as string
    local tail = enc:finish()
    if tail == nil then return nil end
    archive = head .. tail
  end
  return archive
end

--- `path` with `.` and `..` resolved by name alone.
local function lexical(path: string): string
  local parts: {string} = {}
  for part in path:gmatch("[^/]+") do
    if part == ".." then
      parts[#parts] = nil
    elseif part ~= "." then
      parts[#parts + 1] = part
    end
  end
  return "/" .. table.concat(parts, "/")
end

local function inside(path: string, root: string): boolean
  return path == root or path:sub(1, #root + 1) == root .. "/"
end

--- Every link under `dir`, as paths, walking real directories only.
local function links_under(dir: string, found: {string})
  local entries = sys.readdir(dir)
  if entries == nil then return end
  for name, kind in pairs(entries) do
    local path = dir .. "/" .. name
    if kind == "link" then
      found[#found + 1] = path
    elseif kind == "dir" then
      links_under(path, found)
    end
  end
end

local function test_extraction_stays_inside_its_destination(tmp: string)
  local base = Fs.absolute(tmp) or tmp
  local case = base .. "/case"
  Fuzz.run({
    name = "archive extraction contained",
    dir = tmp,
    gen = gen_extraction,
    check = function(input: string): boolean, string
      Fs.remove_tree(case)
      local outside = case .. "/outside"
      local dest = case .. "/dest"
      assert(Fs.mkdirs(outside))
      assert(Fs.write(outside .. "/sentinel", "untouched"))
      local fields = Fuzz.unpack(input)
      local archive = build(fields, outside)
      if archive == nil then return true, "" end
      local file = case .. "/archive"
      assert(Fs.write(file, archive))
      local strip: string | integer = nil
      if fields[3] == "1" then strip = 1 elseif fields[3] == "a" then strip = "a" end
      -- A shrunk input may hold any string here; extract treats every
      -- mode but "create" as "skip".
      local mode: Archive.Links = fields[2] == "create" and "create" or "skip"
      local written = Archive.extract(file, dest, { links = mode, strip = strip, mtimes = false })
      for _, rel in ipairs(written or {}) do
        if rel:sub(1, 1) == "/" or ("/" .. rel .. "/"):find("/../", 1, true) then
          return false, "reported writing " .. rel
        end
      end
      local names = Fs.list(case) or {}
      for _, name in ipairs(names) do
        if name ~= "archive" and name ~= "dest" and name ~= "outside" then
          return false, "wrote " .. case .. "/" .. name .. " beside the destination"
        end
      end
      local out_names = Fs.list(outside) or {}
      if #out_names ~= 1 or Fs.read(outside .. "/sentinel") ~= "untouched" then
        return false, "wrote into " .. outside .. ": " .. table.concat(out_names, ", ")
      end
      local real_dest = Fs.absolute(dest)
      if real_dest == nil then return true, "" end
      local links: {string} = {}
      links_under(real_dest, links)
      for _, link in ipairs(links) do
        local target = Fs.readlink(link)
        if target == nil then return false, "cannot read the link " .. link end
        local resolved = Fs.absolute(link)
        if resolved == nil then
          local from = link:match("^(.*)/[^/]*$") or real_dest
          if target:sub(1, 1) == "/" then
            resolved = lexical(target)
          else
            resolved = lexical(from .. "/" .. target)
          end
        end
        if not inside(resolved, real_dest) then
          return false, ("left %s -> %s, which leads to %s"):format(link, target, resolved)
        end
      end
      return true, ""
    end,
  })
end

--- Lists `input` as a file, where the format is detected: fails only
--- when an answer is one no archive could mean.
local function test_opening_any_bytes_is_total(tmp: string)
  local file = tmp .. "/input"
  Fuzz.run({
    name = "archive open total",
    dir = tmp,
    gen = function(src: Fuzz.Source): string
      local magic = Fuzz.pick(src, { "", "\31\139", "\253" .. "7zXZ\0", "BZh9", "PK\3\4", "PK\5\6" })
      local body = Fuzz.bytes(src, 600)
      if src:int(0, 1) == 1 then
        -- A real tar's header, so the tar path is reached too.
        local out = Stream.collect()
        local tw = Tar.writer(out, { deterministic = true })
        tw:add_file("a", Fuzz.bytes(src, 40))
        tw:close()
        body = Fuzz.mutate(src, out:result(), 4)
        magic = ""
      end
      return magic .. body
    end,
    check = function(input: string): boolean, string
      assert(Fs.write(file, input))
      local entries, trouble = Archive.list(file)
      if entries == nil and trouble == "" then return false, "list: nil without a reason" end
      local reader = Archive.open(file)
      if reader ~= nil then
        for _ = 1, 10000 do
          local e = reader:next()
          if e == nil then break end
          local entry: Archive.Entry = e
          local body = entry:open()
          if body ~= nil then Stream.read_all(body) end
        end
        reader:close()
      end
      return true, ""
    end,
  })
end
