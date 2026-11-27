--- Fuzz properties for [`cosmic.git`], which reads files another program
--- wrote: a delta in a pack reads back as git applies it, and is refused
--- where git would refuse it; every call is total over a repository one
--- of whose files is damaged, and what `read` hands back hashes to the
--- name it was asked for; and what `add` and `commit` record reads back
--- as the files they were given, with nothing left to stage. No git is
--- needed: the repositories are made here, byte by byte.
--- `FUZZ_SEED` and `FUZZ_ITERS` pick the inputs (cosmic/fuzz.tl).

local Codec = require("cosmic.codec")
local Compress = require("cosmic.compress")
local Fs = require("cosmic.fs")
local Fuzz = require("cosmic.fuzz")
local Git = require("cosmic.git")
local Hash = require("cosmic.hash")

--- Who every commit here is by, at a fixed time, so a repository made
--- twice is the same bytes but for its index's stat data.
local PERSON <const>: Git.Person = { name = "Fuzz", email = "fuzz@example.com", time = 1700000000, tz = "+0000" }

--- An object's name: the SHA-1 of its header and data, in hex.
local function oid_of(kind: string, data: string): string
  return Codec.hex(Hash.digest("sha1", kind .. " " .. tostring(#data) .. "\0" .. data))
end

--- Writes `text` at `path`, making its directories.
local function put(path: string, text: string)
  local dir = path:match("^(.*)/[^/]*$")
  assert(Fs.mkdirs(dir!))
  assert(Fs.write(path, text))
end

--- A worktree at `root` with an empty repository in it, as `git init`
--- leaves one.
local function init(root: string)
  put(root .. "/.git/HEAD", "ref: refs/heads/main\n")
  put(root .. "/.git/config", "[core]\n\trepositoryformatversion = 0\n\tbare = false\n")
  assert(Fs.mkdirs(root .. "/.git/objects"))
  assert(Fs.mkdirs(root .. "/.git/refs/heads"))
end

--- A pack entry's header: its type and size.
local function entry_header(kind: integer, size: integer): string
  local c = (kind << 4) | (size & 0x0F)
  size = size >> 4
  local out: mut {string} = {}
  while size > 0 do
    out[#out + 1] = string.char(c | 0x80)
    c = size & 0x7F
    size = size >> 7
  end
  out[#out + 1] = string.char(c)
  return table.concat(out)
end

--- An OFS_DELTA's distance back to its base, as git writes it.
local function offset_bytes(n: integer): string
  local out = string.char(n & 0x7F)
  n = n >> 7
  while n > 0 do
    n = n - 1
    out = string.char(0x80 | (n & 0x7F)) .. out
    n = n >> 7
  end
  return out
end

--- A delta's size: little-endian base 128.
local function size_bytes(n: integer): string
  local out: mut {string} = {}
  repeat
    local c = n & 0x7F
    n = n >> 7
    out[#out + 1] = string.char(if n > 0 then c | 0x80 else c end)
  until n == 0
  return table.concat(out)
end

--- Writes a pack of a blob `base` and a delta on it, and its index, in
--- `root`'s store: the delta names its base by offset, or by name when
--- `by_name`. The index lists the delta under `result_oid`.
local function write_pack(root: string, base: string, delta: string, by_name: boolean, result_oid: string)
  local base_oid = oid_of("blob", base)
  local first = entry_header(3, #base) .. assert(Compress.encode("zlib", base))
  local second_at = 12 + #first
  local link = if by_name then Codec.unhex(base_oid)! else offset_bytes(second_at - 12) end
  local second = entry_header((if by_name then 7 else 6 end), #delta) .. link .. assert(Compress.encode("zlib", delta))
  local body = "PACK" .. string.pack(">I4I4", 2, 2) .. first .. second
  local pack = body .. Hash.digest("sha1", body)
  local listed: mut {{string}} = { { Codec.unhex(base_oid)!, "12" }, { Codec.unhex(result_oid)!, tostring(second_at) } }
  table.sort(listed, function(a: {string}, b: {string}): boolean return a[1]! < b[1]! end)
  local fanout: mut {string} = {}
  for byte = 0, 255 do
    local count = 0
    for _, row in ipairs(listed) do
      if (row[1]!):byte(1)! <= byte then count = count + 1 end
    end
    fanout[#fanout + 1] = string.pack(">I4", count)
  end
  local oids, crcs, offsets = "", "", ""
  for _, row in ipairs(listed) do
    oids = oids .. row[1]!
    crcs = crcs .. string.pack(">I4", 0)
    offsets = offsets .. string.pack(">I4", math.tointeger(tonumber(row[2]!))!)
  end
  local idx = "\255tOc" .. string.pack(">I4", 2) .. table.concat(fanout) .. oids .. crcs .. offsets ..
    Hash.digest("sha1", body)
  idx = idx .. Hash.digest("sha1", idx)
  put(root .. "/.git/objects/pack/pack-fuzz.pack", pack)
  put(root .. "/.git/objects/pack/pack-fuzz.idx", idx)
end

--- `delta` applied to `base` as git's patch_delta does, written apart
--- from the module's own: nil where git refuses it.
local function model_delta(base: string, delta: string): string?
  local at = 1
  local sizes: mut {integer} = {}
  for _ = 1, 2 do
    local value, shift = 0, 0
    repeat
      local c = delta:byte(at)
      if c == nil or shift > 56 then return nil end
      at = at + 1
      value = value | ((c & 0x7F) << shift)
      shift = shift + 7
    until c & 0x80 == 0
    sizes[#sizes + 1] = value
  end
  if sizes[1] ~= #base then return nil end
  local out = ""
  while at <= #delta do
    local op = delta:byte(at)!
    at = at + 1
    if op == 0 then return nil end
    if op & 0x80 ~= 0 then
      local offset, size = 0, 0
      for bit = 0, 6 do
        if op & (1 << bit) ~= 0 then
          local c = delta:byte(at)
          if c == nil then return nil end
          at = at + 1
          if bit < 4 then
            offset = offset | (c << (8 * bit))
          else
            size = size | (c << (8 * (bit - 4)))
          end
        end
      end
      if size == 0 then size = 0x10000 end
      if offset + size > #base then return nil end
      out = out .. base:sub(offset + 1, offset + size)
    else
      if at + op - 1 > #delta then return nil end
      out = out .. delta:sub(at, at + op - 1)
      at = at + op
    end
    if #out > sizes[2]! then return nil end
  end
  if #out ~= sizes[2] then return nil end
  return out
end

--- A base, a delta on it that copies and inserts, perhaps damaged, and
--- whether the pack names the base by name: as [`Fuzz.pack`] fields.
local function gen_delta(src: Fuzz.Source): string
  local base = Fuzz.bytes(src, 64)
  if base == "" then base = "x" end
  local ops: mut {string} = {}
  local made = 0
  local count = 0
  while Fuzz.more(src, count, 6) do
    count = count + 1
    if src:int(0, 1) == 0 then
      local offset = src:int(0, #base - 1)
      local size = src:int(1, #base - offset)
      local op = 0x80
      local args = ""
      for bit = 0, 3 do
        local b = (offset >> (8 * bit)) & 0xFF
        if b ~= 0 then
          op = op | (1 << bit)
          args = args .. string.char(b)
        end
      end
      for bit = 0, 2 do
        local b = (size >> (8 * bit)) & 0xFF
        if b ~= 0 then
          op = op | (1 << (4 + bit))
          args = args .. string.char(b)
        end
      end
      ops[#ops + 1] = string.char(op) .. args
      made = made + size
    else
      local text = Fuzz.bytes(src, 20)
      if text == "" then text = "i" end
      ops[#ops + 1] = string.char(#text) .. text
      made = made + #text
    end
  end
  local delta = size_bytes(#base) .. size_bytes(made) .. table.concat(ops)
  if src:int(0, 2) == 0 then delta = Fuzz.mutate(src, delta, 3) end
  return Fuzz.pack({ base, delta, if src:int(0, 1) == 0 then "ofs" else "ref" end })
end

local function test_a_delta_reads_back_as_git_applies_it(tmp: string)
  local case = 0
  Fuzz.run({
    name = "git delta",
    dir = tmp,
    gen = gen_delta,
    requires = { "applied", "refused", "by name" },
    shares = { applied = 0.3 },
    check = function(input: string): boolean, string
      local fields = Fuzz.unpack(input)
      local base, delta, how = fields[1]!, fields[2]!, fields[3]!
      if how == "ref" then Fuzz.label("by name") end
      case = case + 1
      local root = tmp .. "/delta" .. tostring(case)
      init(root)
      local want = model_delta(base, delta)
      local oid = if want ~= nil then oid_of("blob", want) else string.rep("ab", 20) end
      write_pack(root, base, delta, how == "ref", oid)
      local repo = assert(Git.open(root))
      local got, why = repo:read(oid)
      if want == nil then
        Fuzz.label("refused")
        if got ~= nil then return false, "read a delta git refuses" end
        return true, ""
      end
      Fuzz.label("applied")
      if got == nil then return false, "refused a delta git applies: " .. tostring(why) end
      if got.data ~= want or got.kind ~= "blob" then return false, "read back differently" end
      return true, ""
    end,
  })
end

--- The worktree files every damaged repository starts from.
local FILES <const>: {string: string} = { ["a.txt"] = "one\n", ["dir/b.txt"] = "two\n", ["dir-x/c"] = "three\n" }

--- A repository at `root` with two commits, the second on top of the
--- first, a packed-refs file and a pack: every file a reader reads.
--- The commit's name.
local function make_repo(root: string): string
  init(root)
  for path, text in pairs(FILES) do put(root .. "/" .. path, text) end
  local repo = assert(Git.open(root))
  assert(repo:add({ "a.txt", "dir/b.txt", "dir-x/c" }))
  assert(repo:commit({ message = "first", author = PERSON, committer = PERSON }))
  put(root .. "/a.txt", "one\nmore\n")
  assert(repo:add({ "a.txt" }))
  local head = assert(repo:commit({ message = "second", author = PERSON, committer = PERSON }))
  put(root .. "/.git/packed-refs", "# pack-refs with: peeled fully-peeled sorted \n" .. head .. " refs/tags/t\n")
  local base = "a base of some length\n"
  local delta = size_bytes(#base) .. size_bytes(7) .. "\x90\x07"
  write_pack(root, base, delta, false, oid_of("blob", "a base "))
  return head
end

--- The files of the repository [`make_repo`] makes, by their path in it,
--- and their bytes: what a damaged input starts from.
local function samples(root: string): {string: string}
  local head = make_repo(root)
  local commit_path = ".git/objects/" .. head:sub(1, 2) .. "/" .. head:sub(3)
  local made: mut {string: string} = {}
  for _, path in ipairs({ ".git/HEAD", ".git/config", ".git/index", ".git/refs/heads/main", ".git/packed-refs",
      commit_path, ".git/objects/pack/pack-fuzz.pack", ".git/objects/pack/pack-fuzz.idx", ".git/logs/HEAD" }) do
    made[path] = assert(Fs.read(root .. "/" .. path))
  end
  return made
end

--- Every call of the module, on the repository at `root`: none may
--- raise, and what `read` hands back must hash to its name.
local function exercise(root: string): boolean, string
  local repo, _ = Git.open(root)
  if repo == nil then
    Fuzz.label("open refused")
    return true, ""
  end
  local _h, _ht = repo:head()
  local _r, _rt = repo:head_ref()
  local _s, _st = repo:status()
  local log, _ = repo:log({ limit = 5 })
  for _, spec in ipairs({ "HEAD", "HEAD~1", "HEAD^2", "main", "t", "abcd" }) do
    local oid, _ = repo:rev(spec)
    if oid ~= nil then
      local object, _ = repo:read(oid)
      if object ~= nil and oid_of(object.kind, object.data) ~= oid then
        return false, "read " .. oid .. " handed back other bytes"
      end
    end
  end
  if log ~= nil then
    Fuzz.label("log read")
    for _, c in ipairs(log) do
      local _t, _tt = repo:tree(c.tree)
    end
  end
  local blob, _ = repo:read(oid_of("blob", "a base "))
  if blob ~= nil and blob.data ~= "a base " then
    return false, "the packed delta read back differently"
  end
  local added, _ = repo:add({ "a.txt" })
  if added ~= nil then
    local _c, _ct = repo:commit({ message = "again", author = PERSON, committer = PERSON, allow_empty = true })
  end
  return true, ""
end

local function test_every_call_is_total_over_a_damaged_repository(tmp: string)
  local sample = samples(tmp .. "/template")
  local paths: mut {string} = {}
  for path in pairs(sample) do paths[#paths + 1] = path end
  table.sort(paths)
  local case = 0
  Fuzz.run({
    name = "git damaged",
    dir = tmp,
    gen = function(src: Fuzz.Source): string
      local path = Fuzz.pick(src, paths)
      local signed = if path == ".git/index" and src:int(0, 1) == 0 then "signed" else "as is" end
      return Fuzz.pack({ path, Fuzz.mutate(src, sample[path]!, 4), signed })
    end,
    requires = { "open refused", "log read", "index re-signed" },
    max_iters = 1000,
    check = function(input: string): boolean, string
      local fields = Fuzz.unpack(input)
      case = case + 1
      local root = tmp .. "/damaged" .. tostring(case)
      make_repo(root)
      local bytes = fields[2]!
      -- An index whose checksum no longer matches is refused whole: one
      -- re-signed reaches the entries.
      if fields[3] == "signed" and #bytes >= 20 then
        Fuzz.label("index re-signed")
        bytes = bytes:sub(1, -21) .. Hash.digest("sha1", bytes:sub(1, -21))
      end
      assert(Fs.write(root .. "/" .. fields[1]!, bytes))
      return exercise(root)
    end,
  })
end

--- Path parts that sort around each other in a tree: `a-b` and `a.b`
--- before `a/`, `a0` after it.
local PARTS <const> = { "a", "b", "a-b", "a.b", "a0", "A", "a b", "\xc3\xa9" }

--- A set of files as [`Fuzz.pack`] fields, a path then its bytes; a path
--- that is a directory of an earlier one, or under an earlier file, is
--- left out, as a worktree cannot hold both.
local function gen_files(src: Fuzz.Source): string
  local fields: mut {string} = {}
  local count = 0
  while Fuzz.more(src, count, 8) do
    count = count + 1
    local parts: mut {string} = {}
    repeat parts[#parts + 1] = Fuzz.pick(src, PARTS) until not Fuzz.more(src, #parts, 3)
    fields[#fields + 1] = table.concat(parts, "/")
    fields[#fields + 1] = Fuzz.bytes(src, 40)
  end
  return Fuzz.pack(fields)
end

--- The files [`gen_files`] packed, by path, with clashing paths left out.
local function files_of(input: string): {string: string}
  local fields = Fuzz.unpack(input)
  local files: mut {string: string} = {}
  for i = 1, #fields - 1, 2 do
    local path = fields[i]!
    local clash = false
    for other in pairs(files) do
      if other == path or other:sub(1, #path + 1) == path .. "/" or path:sub(1, #other + 1) == other .. "/" then
        clash = true
      end
    end
    if not clash then files[path] = fields[i + 1]! end
  end
  return files
end

--- The files the tree `oid` holds, by path under `prefix`, into `into`.
local function walk(repo: Git.Repo, oid: string, prefix: string, into: mut {string: string}): boolean, string
  local entries, why = repo:tree(oid)
  if entries == nil then return false, tostring(why) end
  local last = ""
  for _, entry in ipairs(entries) do
    local key = if entry.mode == "40000" then entry.name .. "/" else entry.name end
    if key <= last then return false, "tree out of order at " .. entry.name end
    last = key
    if entry.mode == "40000" then
      local ok, trouble = walk(repo, entry.oid, prefix .. entry.name .. "/", into)
      if not ok then return false, trouble end
    else
      local blob, btrouble = repo:read(entry.oid)
      if blob == nil then return false, tostring(btrouble) end
      into[prefix .. entry.name] = blob.data
    end
  end
  return true, ""
end

local function test_what_is_committed_reads_back(tmp: string)
  local case = 0
  Fuzz.run({
    name = "git commit",
    dir = tmp,
    gen = gen_files,
    requires = { "nested", "several" },
    max_iters = 1000,
    check = function(input: string): boolean, string
      local files = files_of(input)
      case = case + 1
      local root = tmp .. "/commit" .. tostring(case)
      init(root)
      local paths: mut {string} = {}
      for path, text in pairs(files) do
        put(root .. "/" .. path, text)
        paths[#paths + 1] = path
        if path:find("/", 1, true) ~= nil then Fuzz.label("nested") end
      end
      if #paths > 2 then Fuzz.label("several") end
      table.sort(paths)
      local repo = assert(Git.open(root))
      local added, why = repo:add(paths)
      if added == nil then return false, "add refused: " .. tostring(why) end
      local oid, cwhy = repo:commit({ message = "m", author = PERSON, committer = PERSON, allow_empty = true })
      if oid == nil then return false, "commit refused: " .. tostring(cwhy) end
      local commit = assert(repo:commit_info(oid))
      local back: mut {string: string} = {}
      local ok, trouble = walk(repo, commit.tree, "", back)
      if not ok then return false, trouble end
      for path, text in pairs(files) do
        if back[path] ~= text then return false, path .. " read back differently" end
      end
      for path in pairs(back) do
        if files[path] == nil then return false, path .. " read back but never written" end
      end
      local status, _ = assert(Git.open(root)):status()
      if status == nil then return false, "status refused" end
      if #status.staged + #status.unstaged ~= 0 then
        return false, "left changes after the commit"
      end
      return true, ""
    end,
  })
end
