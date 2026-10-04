--- Fuzz properties for [`cosmic.archive`]: opening is total over any bytes,
--- plain or behind a compressor's magic, and extraction never writes
--- outside its destination or leaves a link there that leads out of it,
--- whatever paths, links and options an archive combines, and never
--- writes more than `max_bytes` in all or `max_entry_bytes` to a file,
--- whatever the archive's bodies expand to.
--- `FUZZ_SEED` and `FUZZ_ITERS` pick the inputs (build/fuzz/init.tl).

local Archive = require("cosmic.archive")
local Compress = require("cosmic.compress")
local Fs = require("cosmic.fs")
local Fuzz = require("build.fuzz")
local Stream = require("cosmic.stream")
local String = require("cosmic.string")
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
  repeat parts[#parts + 1] = Fuzz.pick(src, from) until not Fuzz.more(src, #parts, 3)
  return table.concat(parts, "/")
end

--- Parts and link targets extract accepts on their own: a path of these
--- is relative with no `..`, and a link to one of these stays inside
--- wherever it sits, so an archive of such entries is refused, if at
--- all, only for how they combine (a file where a directory must go, a
--- path through a link, a `link/..` whose `link` is no real
--- directory). More targets through another name would leave few
--- archives making a link.
local SAFE_PARTS <const> = { "a", "b", "link", "." }
local SAFE_TARGETS <const> = { "a", "b", "link", ".", "link/.." }

--- An extraction as [`Fuzz.pack`] fields: a format, the `links` option,
--- a strip (`1` for `strip_components`, `a` for `strip_prefix`), then
--- a kind, a path and a body per entry. Entries are well formed but for
--- at most one hostile one, drawn from anything: extract refuses a
--- whole archive at its first unsafe path, so archives of several
--- hostile entries would rarely make the writes containment is about.
--- A pair of hostile entries that escapes only together (`a/x ->
--- link/..` with `a/link -> ..`) is therefore never drawn.
-- TODO: the escape `target_crosses_link` refuses -- a top-level
-- `link -> .` then `x -> link/..`, which leads to dest's parent -- is
-- drawn about once in 6000 inputs ("refused a link through a link");
-- drawing a top-level `link -> .` more often, and requiring the label,
-- would exercise it in every run.
local function gen_extraction(src: Fuzz.Source): string
  local format = Fuzz.pick(src, { "tar", "tar.gz", "zip" })
  -- Links, what containment is most about, are drawn twice as often.
  local fields: {string} = { format, Fuzz.pick(src, { "skip", "create", "create" }), Fuzz.pick(src, { "", "1", "a" }) }
  local hostile_left = true
  repeat
    -- One entry in eight, until one is; the high end is the hostile
    -- one, so shrinking toward the low end makes an entry well formed.
    -- Drawn for every entry, so an entry cut in shrinking leaves the
    -- draws after it aligned.
    local roll = src:int(0, 7)
    local hostile = hostile_left and roll == 7
    if hostile then hostile_left = false end
    local kind = Fuzz.pick(src, { "file", "dir", "symlink", "symlink" })
    if format == "zip" and kind == "symlink" then kind = "file" end
    fields[#fields + 1] = kind
    fields[#fields + 1] = gen_path(src, hostile and PARTS or SAFE_PARTS)
    fields[#fields + 1] = kind == "symlink" and Fuzz.pick(src, hostile and TARGETS or SAFE_TARGETS) or
      (kind == "file" and Fuzz.bytes(src, 8) or "")
  until not Fuzz.more(src, (#fields - 3) // 3, 6)
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

--- Every link under `dir`, as paths, walking real directories only:
--- `readdir` names a link as one, so a link to a directory is found,
--- not walked into.
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
    -- "linked": links are what containment is most about, and an
    -- archive of several hostile entries almost never makes one.
    requires = { "built", "extracted", "linked" },
    check = function(input: string): boolean, string
      Fs.remove_tree(case)
      local outside = case .. "/outside"
      local dest = case .. "/dest"
      assert(Fs.mkdirs(outside))
      assert(Fs.write(outside .. "/sentinel", "untouched"))
      local fields = Fuzz.unpack(input)
      local archive = build(fields, outside)
      if archive == nil then return true, "" end
      Fuzz.label("built")
      local file = case .. "/archive"
      assert(Fs.write(file, archive))
      local strip_components: integer = fields[3] == "1" and 1 or nil
      local strip_prefix: string = fields[3] == "a" and "a" or nil
      -- A shrunk input may hold any string here; extract treats every
      -- mode but "create" as "skip".
      local mode: Archive.Links = fields[2] == "create" and "create" or "skip"
      local written, trouble = Archive.extract(file, dest, { links = mode, strip_prefix = strip_prefix,
        strip_components = strip_components })
      if written ~= nil and #written > 0 then Fuzz.label("extracted") end
      -- What a hostile entry among well-formed ones reaches: the
      -- writes before it, left in place when it is refused.
      if written == nil and (Fs.list(dest) or {})[1] ~= nil then
        Fuzz.label("refused after writing")
      end
      -- The escape `target_crosses_link` exists for: `link -> .` made,
      -- then a link through it (`x -> link/..`, which leads to dest's
      -- parent) refused.
      if written == nil and trouble:find("another symlink", 1, true) ~= nil and
          Fs.readlink(dest .. "/link") == "." then
        Fuzz.label("refused a link through a link")
      end
      for _, rel in ipairs(written or {}) do
        if Fs.readlink(dest .. "/" .. rel) ~= nil then
          Fuzz.label("linked")
          break
        end
      end
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
    requires = { "listed" },
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
      if entries ~= nil then Fuzz.label("listed") end
      local reader = Archive.open(file)
      if reader ~= nil then
        for _ = 1, 10000 do
          local e = reader:next()
          if e == nil then break end
          local entry: Archive.Entry = e
          local body = entry:open()
          if body ~= nil and Stream.read_all(body) ~= nil then Fuzz.label("body read") end
        end
        reader:close()
      end
      return true, ""
    end,
  })
end

--- What walking `reader` yields: one line per entry, then "ok" or
--- "trouble" for how the walk ended; closes it. A stream's entries
--- before its trouble depend on how its bytes were chunked (a
--- decompressor refuses a bad chunk whole), so `trouble` stands for
--- the walk, not for what was read before it.
local function walk_summary(reader: Archive.Reader): string
  local lines: {string} = {}
  local ended = "ok"
  for _ = 1, 10000 do
    local e, why = reader:next()
    if e == nil then
      if why ~= "" then
        ended = "trouble"
        lines = {}
      end
      break
    end
    local entry: Archive.Entry = e
    lines[#lines + 1] = entry.kind .. " " .. entry.path .. " " .. tostring(entry.size)
  end
  reader:close()
  lines[#lines + 1] = ended
  return table.concat(lines, "\n")
end

--- A Reader over `bytes` that answers in chunks of the sizes `bytes`
--- itself spells (1 to 300, cycling), so the sniff and the tar's header
--- reads land across reads wherever the input puts them.
local function chunked(bytes: string): Stream.Reader
  local at, turn = 1, 0
  local r: Stream.Reader = {}
  r.read = function(_self: Stream.Reader, max_bytes?: integer): string | nil, string
    if at > #bytes then return nil, "" end
    turn = turn + 1
    local size = bytes:byte(turn % math.max(#bytes, 1) + 1) % 300 + 1
    if max_bytes ~= nil and max_bytes < size then size = max_bytes end
    local chunk = bytes:sub(at, at + size - 1)
    at = at + #chunk
    return chunk, ""
  end
  r.close = function(_self: Stream.Reader): boolean, string return true, "" end
  return r
end

--- `open_stream` answers as `open` does for the same bytes, however the
--- stream splits them: the same entries and the same end, a tar or a
--- compressed tar alike, and a zip refused rather than misread.
local function test_open_stream_answers_as_open_does_for_the_same_bytes(tmp: string)
  local file = tmp .. "/input"
  Fuzz.run({
    name = "archive open_stream parity",
    dir = tmp,
    requires = { "walked" },
    gen = function(src: Fuzz.Source): string
      local magic = Fuzz.pick(src, { "", "\31\139", "\253" .. "7zXZ\0", "BZh9", "PK\3\4", "PK\5\6" })
      local body = Fuzz.bytes(src, 600)
      if src:int(0, 2) > 0 then
        local out = Stream.collect()
        local tw = Tar.writer(out, { deterministic = true })
        tw:add_file("a", Fuzz.bytes(src, 40))
        tw:add_file("b/c", Fuzz.bytes(src, 700))
        tw:close()
        local sample = out:result()
        if src:int(0, 1) == 1 then
          local enc = Compress.deflater("gzip")
          if enc ~= nil then
            local head = enc:update(sample) as string
            local tail = enc:finish()
            if tail ~= nil then sample = head .. tail end
          end
        end
        body = Fuzz.mutate(src, sample, 3)
        magic = ""
      end
      return magic .. body
    end,
    check = function(input: string): boolean, string
      assert(Fs.write(file, input))
      local streamed, why = Archive.open_stream(chunked(input))
      local zip = input:sub(1, 4) == "PK\3\4" or input:sub(1, 4) == "PK\5\6"
      if zip then
        if streamed ~= nil then return false, "open_stream took a zip" end
        if why:find("zip", 1, true) == nil then return false, "zip refusal: " .. why end
        return true, ""
      end
      local opened = Archive.open(file)
      if (opened == nil) ~= (streamed == nil) then
        return false, "open " .. (opened == nil and "refused" or "took") .. " what open_stream " .. (streamed == nil and "refused" or "took")
      end
      if opened == nil or streamed == nil then return true, "" end
      local from_file, from_stream = walk_summary(opened), walk_summary(streamed)
      if from_file ~= from_stream then
        return false, "file: " .. from_file .. "\nstream: " .. from_stream
      end
      Fuzz.label("walked")
      return true, ""
    end,
  })
end

--- What `dir` holds, as lines: every path with its kind and its body or
--- link target, sorted.
local function snapshot(dir: string): string
  local lines: {string} = {}
  local function walk(at: string, prefix: string)
    local entries = sys.readdir(at)
    if entries == nil then return end
    for name, kind in pairs(entries) do
      local path = at .. "/" .. name
      local line = prefix .. name .. " " .. kind
      if kind == "link" then
        local target = Fs.readlink(path)
        line = line .. " " .. tostring(target)
      elseif kind == "file" then
        local body = Fs.read(path)
        line = line .. " " .. tostring(body)
      end
      lines[#lines + 1] = line
      if kind == "dir" then walk(path, prefix .. name .. "/") end
    end
  end
  walk(dir, "")
  table.sort(lines)
  return table.concat(lines, "\n")
end

--- `extract_reader` over a stream, however it chunks its bytes, writes
--- what `extract` of the same bytes as a file does, and refuses what it
--- refuses with the same words: one code path, read two ways.
-- TODO: fuzz the verb's staged extraction too (`resolve_in` and the
-- move into a destination that already holds files) against a direct
-- extract into the same destination; only its unit tests reach it now.
local function test_extract_reader_answers_as_extract_does_for_the_same_bytes(tmp: string)
  local base = Fs.absolute(tmp) or tmp
  local case = base .. "/case"
  Fuzz.run({
    name = "archive extract_reader parity",
    dir = tmp,
    gen = gen_extraction,
    requires = { "both wrote", "both refused" },
    check = function(input: string): boolean, string
      Fs.remove_tree(case)
      local outside = case .. "/outside"
      assert(Fs.mkdirs(outside))
      local fields = Fuzz.unpack(input)
      if fields[1] == "zip" then return true, "" end
      local archive = build(fields, outside)
      if archive == nil then return true, "" end
      local file = case .. "/archive"
      assert(Fs.write(file, archive))
      local opts: Archive.ExtractOptions = {
        links = fields[2] == "create" and "create" or "skip",
        strip_prefix = fields[3] == "a" and "a" or nil,
        strip_components = fields[3] == "1" and 1 or nil,
      }
      local from_file, file_why = Archive.extract(file, case .. "/by-file", opts)
      local reader = Archive.open_stream(chunked(archive))
      if reader == nil then return false, "open_stream refused what open took" end
      local from_stream, stream_why = Archive.extract_reader(reader, case .. "/by-stream", opts)
      if (from_file == nil) ~= (from_stream == nil) then
        return false, "file: " .. tostring(file_why) .. "\nstream: " .. tostring(stream_why)
      end
      -- The directory is a pattern's text: escaped, a "-" in its name
      -- (as a test's scratch directory's has) means itself.
      local at = case:gsub("%p", "%%%0")
      local file_words = file_why:gsub(at .. "/by%-file", "DEST")
      local stream_words = stream_why:gsub(at .. "/by%-stream", "DEST")
      if file_words ~= stream_words then return false, file_words .. "\n" .. stream_words end
      if from_file ~= nil and from_stream ~= nil and table.concat(from_file, "\n") ~= table.concat(from_stream, "\n") then
        return false, "wrote " .. table.concat(from_file, ",") .. " / " .. table.concat(from_stream, ",")
      end
      local by_file, by_stream = snapshot(case .. "/by-file"), snapshot(case .. "/by-stream")
      if by_file ~= by_stream then
        return false, "file:\n" .. by_file .. "\nstream:\n" .. by_stream
      end
      Fuzz.label(from_file ~= nil and "both wrote" or "both refused")
      return true, ""
    end,
  })
end

--- An archive of files `f1`, `f2`... as [`Fuzz.pack`] fields: a format,
--- `max_entry_bytes` and `max_bytes` ("" for neither), then a size and a
--- fill per file. The fills compress to almost nothing, so a body is
--- far larger than the archive that holds it, as a bomb is.
local function gen_capped(src: Fuzz.Source): string
  local fields: {string} = { Fuzz.pick(src, { "tar", "tar.gz", "zip" }) }
  -- None is the low end, so a shrunk input falls back to the defaults.
  local function cap(small: integer, large: integer): string
    local kind = src:int(0, 2)
    if kind == 0 then return "" end
    return tostring(src:int(0, kind == 1 and small or large))
  end
  fields[#fields + 1] = cap(400, 100000)
  fields[#fields + 1] = cap(1000, 200000)
  repeat
    -- A body past the 64 KiB a read takes at most, one in eight.
    local big = src:int(0, 7) == 7
    fields[#fields + 1] = tostring(big and src:int(65000, 140000) or src:int(0, 300))
    fields[#fields + 1] = Fuzz.pick(src, { "z", "p" })
  until not Fuzz.more(src, (#fields - 3) // 2, 6)
  return Fuzz.pack(fields)
end

--- The limit a field spells, nil for none or for text no limit is.
local function limit_of(field: string): integer | nil
  local n = math.tointeger(tonumber(field))
  if n ~= nil and n >= 0 then return n end
  return nil
end

--- The archive `fields` describe, as [`gen_capped`] draws them, and the
--- sizes of its files in order.
local function build_capped(fields: {string}): string | nil, {integer}
  local out = Stream.collect()
  local zip = fields[1] == "zip"
  local w: Stream.ArchiveWriter
  if zip then
    w = Zip.writer(out, { deterministic = true })
  else
    w = Tar.writer(out, { deterministic = true })
  end
  local sizes: {integer} = {}
  for i = 4, #fields - 1, 2 do
    local size = math.tointeger(tonumber(fields[i])) or 0
    if size < 0 then size = 0 end
    local unit = fields[i + 1] == "z" and "\0" or "pq1"
    local body = unit:rep(size // #unit + 1):sub(1, size)
    sizes[#sizes + 1] = size
    if not w:add_file("f" .. #sizes, body) then return nil, sizes end
  end
  if not w:close() then return nil, sizes end
  local archive = out:result()
  if fields[1] == "tar.gz" then
    local enc = Compress.deflater("gzip")
    if enc == nil then return nil, sizes end
    local head = enc:update(archive) as string
    local tail = enc:finish()
    if tail == nil then return nil, sizes end
    archive = head .. tail
  end
  return archive, sizes
end

--- `reader`, its entries claiming to hold nothing: the sizes a header
--- states are the archive's to lie about, so a limit that read them
--- alone would pass any body.
local function understating(reader: Archive.Reader): Archive.Reader
  local r: Archive.Reader = {}
  r.next = function(_self: Archive.Reader): Archive.Entry | nil, string
    local entry, why = reader:next()
    if entry == nil then return nil, why end
    local real: Archive.Entry = entry
    local lie: Archive.Entry = {
      path = real.path, kind = real.kind, mode = real.mode, size = 0, mtime = real.mtime,
      linkpath = real.linkpath,
      open = function(_self: Archive.Entry): Stream.Reader | nil, string return real:open() end,
    }
    return lie, ""
  end
  r.close = function(_self: Archive.Reader): boolean, string return reader:close() end
  return r
end

--- Extraction under `max_entry_bytes` and `max_bytes` refuses exactly the
--- first file that passes one, leaves the files before it whole and no
--- trace of it, and never has written more than a limit allows.
local function test_extraction_stays_under_its_byte_limits(tmp: string)
  local base = Fs.absolute(tmp) or tmp
  local case = base .. "/case"
  Fuzz.run({
    name = "archive extraction byte limits",
    dir = tmp,
    gen = gen_capped,
    requires = { "extracted", "refused by entry limit", "refused by total limit" },
    shares = { ["refused by entry limit"] = 0.15, ["refused by total limit"] = 0.04 },
    check = function(input: string): boolean, string
      Fs.remove_tree(case)
      assert(Fs.mkdirs(case))
      local fields = Fuzz.unpack(input)
      if #fields < 5 then return true, "" end
      local archive, sizes = build_capped(fields)
      if archive == nil then return true, "" end
      local file = case .. "/archive"
      assert(Fs.write(file, archive))
      local per_file, total = limit_of(fields[2]), limit_of(fields[3])
      local opts: Archive.ExtractOptions = { max_entry_bytes = per_file, max_bytes = total }

      -- What the limits allow, from the sizes the archive was built of.
      local kept, used = 0, 0
      local refusal = ""
      -- What a body that outgrows its header is refused for, if it hits
      -- the other limit first, as it does when both are in reach.
      local either: {string} = {}
      for i, size in ipairs(sizes) do
        local entry_says = "archive: f" .. i .. " is larger than max_entry_bytes (" ..
          String.counted(per_file or 0, "byte") .. ")"
        local total_says = "archive: extracting f" .. i .. " would write more than max_bytes (" ..
          String.counted(total or 0, "byte") .. ")"
        if per_file ~= nil and size > per_file then
          refusal = entry_says
          Fuzz.label("refused by entry limit")
        elseif total ~= nil and used + size > total then
          refusal = total_says
          Fuzz.label("refused by total limit")
        end
        if refusal ~= "" then
          either = { entry_says, total_says }
          break
        end
        used = used + size
        kept = i
      end
      if refusal == "" then Fuzz.label("extracted") end

      local function check_dest(dest: string, written: {string} | nil, trouble: string,
                                says: {string}): boolean, string
        if (written == nil) ~= (refusal ~= "") then
          return false, "extract " .. (written == nil and "refused" or "took") .. " what the limits " ..
            (refusal ~= "" and "refuse" or "allow") .. ": " .. trouble
        end
        if written == nil and trouble ~= says[1] and trouble ~= says[2] then
          return false, "refused as '" .. trouble .. "', not '" .. table.concat(says, "' or '") .. "'"
        end
        local names = Fs.list(dest) or {}
        table.sort(names)
        local want: {string} = {}
        for i = 1, kept do want[i] = "f" .. i end
        table.sort(want)
        if table.concat(names, ",") ~= table.concat(want, ",") then
          return false, "left " .. table.concat(names, ",") .. ", not " .. table.concat(want, ",")
        end
        local wrote = 0
        for i = 1, kept do
          local body = Fs.read(dest .. "/f" .. i)
          if body == nil or #body ~= sizes[i] then return false, "f" .. i .. " is not whole" end
          wrote = wrote + #body
          if per_file ~= nil and #body > per_file then
            return false, "f" .. i .. " passes max_entry_bytes"
          end
        end
        if total ~= nil and wrote > total then
          return false, "wrote " .. wrote .. ", past max_bytes"
        end
        return true, ""
      end

      local written, trouble = Archive.extract(file, case .. "/by-file", opts)
      local ok, why = check_dest(case .. "/by-file", written, trouble, { refusal })
      if not ok then return false, why end
      -- Entries that state no size: only the bytes read tell.
      local opened = Archive.open(file)
      if opened == nil then return false, "open refused what extract took" end
      written, trouble = Archive.extract_reader(understating(opened), case .. "/understated", opts)
      ok, why = check_dest(case .. "/understated", written, trouble, either)
      if not ok then return false, "understating its sizes: " .. why end
      if fields[1] == "zip" then return true, "" end
      local reader = Archive.open_stream(chunked(archive))
      if reader == nil then return false, "open_stream refused what open took" end
      written, trouble = Archive.extract_reader(reader, case .. "/by-stream", opts)
      return check_dest(case .. "/by-stream", written, trouble, { refusal })
    end,
  })
end
