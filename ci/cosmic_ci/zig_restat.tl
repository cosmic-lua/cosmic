--- zig's caches as a restore leaves them, made to read as zig left them
--- (`driver.tl zig-restat`, run by the driver's boot before it builds).
---
--- A manifest records each file it read with the size, inode and mtime
--- zig saw and the file's digest. zig 0.17 takes a file whose stat
--- matches as unchanged and re-hashes one whose stat moved; for a
--- direct input -- every C source a compile names -- it then compares
--- the fresh hash with a digest it never computed
--- (std/Build/Cache.zig's `checkInputPath`), so the compile misses
--- though the file is what it was. A cache restored from a tarball, as
--- ci.yml restores zig's, gives every file a new inode, and the build
--- recompiles every C file it compiles (a boot of 100 s where one on a
--- cache whose inodes held takes 8 s).
---
--- `restat` takes, into each manifest, the stat of each file it lists
--- that is still what the manifest says: one whose size and mtime are
--- as recorded (a restore keeps both) has its new inode taken; one
--- whose mtime moved (a fresh checkout's) and whose bytes still hash to
--- the recorded digest has its size, inode and mtime taken, as a zig
--- that compared the right digest would; any other is left, for zig to
--- miss on as it should. A file a restore kept the size and mtime of is
--- trusted as unchanged without reading it, as zig trusts a restored
--- output it never reads at all.

-- TODO: remove this module, and its call in cosmic_ci/orchestration.tl's
-- boot, once the pinned zig's `checkInputPath` compares a re-hashed
-- direct input against the digest its manifest holds (zig 0.17.0 and
-- master compare one never computed; unreported upstream as of 0.17.0).

local Child = require("cosmic.child")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Plural = require("cosmic_ci.plural")
local Predicate = require("cosmic_ci.fs_predicate")
local ZigPrune = require("cosmic_ci.zig_prune")
local sys = require("cosmic.sys")

local record ZigRestat
  --- What `restat` did: how many files the manifests list, how many it
  --- took a new inode for, how many it re-hashed and took the stat of,
  --- how many it left, and how many manifests it rewrote.
  record Result
    records: integer
    adopted: integer
    rehashed: integer
    left: integer
    manifests: integer
  end
end

-- A record's flags: bit 0 a directory, bit 1 a stat-only file, whose
-- digest zig makes from the stat; zig handles both itself.
local directory_flag <const> = 1
local metadata_flag <const> = 2

--- The path a record names: its own when absolute, else under the root
--- of its prefix -- the manifest's own cache for 2, `roots[prefix]`
--- otherwise -- or nil where no root is known.
local function located(record: ZigPrune.Record, own: string,
    roots: {integer:string}): string | nil
  if record.path:sub(1, 1) == "/" then return record.path end
  local root = record.prefix == 2 and own or roots[record.prefix]
  if root == nil then return nil end
  if record.path == "" then return root end
  return root .. "/" .. record.path
end

--- Takes into every manifest of `caches` the stat of each file still
--- what the manifest says (the module's doc). `roots` names each prefix's
--- directory but a cache's own (std/Build/Cache.zig's `prefixes`: 0 the
--- directory zig ran in, 1 zig's lib directory, 3 the global cache, 4
--- the build root); a file under a prefix it does not name is left.
--- nil and why where a cache cannot be read or a manifest does not read
--- as zig's, having rewritten none.
function ZigRestat.restat(caches: {ZigPrune.Cache}, roots: {integer:string}): ZigRestat.Result | nil, string
  local result: ZigRestat.Result = { records = 0, adopted = 0, rehashed = 0, left = 0,
    manifests = 0 }
  -- Each path's stat, or false where there is none; each re-hashed
  -- path's digest.
  local stats: {string:sys.Stat | boolean} = {}
  local digests: {string:string} = {}
  local writes: {{string}} = {}
  for _, cache in ipairs(caches) do
    local names, names_trouble = Fs.list(cache.path .. "/h")
    if names == nil then return nil, cache.path .. "/h: " .. names_trouble end
    for _, name in ipairs(names) do
      if #name == 32 and name:match("^%x+$") then
        local path = cache.path .. "/h/" .. name
        local text, text_trouble = Fs.read(path)
        if text == nil then return nil, path .. ": " .. text_trouble end
        -- An empty manifest, a step's that never finished, lists nothing.
        if text ~= "" then
          local records, trouble = ZigPrune.records(text)
          if records == nil then return nil, path .. ": " .. trouble end
          local pieces: {string} = {}
          local from = 1
          for _, record in ipairs(records) do
            result.records = result.records + 1
            local file = located(record, cache.path, roots)
            local stat: sys.Stat | boolean = false
            if file ~= nil and record.flags & (directory_flag | metadata_flag) == 0 then
              stat = stats[file]
              if stat == nil then
                local found, _ = sys.stat(file)
                stat = found ~= nil and found.kind == "file" and found or false
                stats[file] = stat
              end
            end
            local taken, unchanged = false, false
            if stat is sys.Stat and stat.size == record.size then
              local mtime = stat.mtime * 1000000000 + stat.mtime_ns
              if mtime == record.mtime and stat.ino == record.inode then
                unchanged = true
              elseif mtime == record.mtime then
                result.adopted = result.adopted + 1
                taken = true
              else
                local digest = digests[file]
                if digest == nil then
                  local bytes, _ = Fs.read(file)
                  digest = bytes and ZigPrune.siphash128(ZigPrune.key, bytes) or ""
                  digests[file] = digest
                end
                if digest == record.digest then
                  result.rehashed = result.rehashed + 1
                  taken = true
                end
              end
              if taken then
                pieces[#pieces + 1] = text:sub(from, record.at - 1)
                pieces[#pieces + 1] = string.pack("<i8i8i8", stat.size, stat.ino, mtime)
                from = record.at + 24
              end
            end
            if not taken and not unchanged then result.left = result.left + 1 end
          end
          if from > 1 then
            pieces[#pieces + 1] = text:sub(from)
            writes[#writes + 1] = { path, table.concat(pieces) }
          end
        end
      end
    end
  end
  for _, write in ipairs(writes) do
    local ok, trouble = Fs.write(write[1], write[2])
    if not ok then return nil, write[1] .. ": " .. trouble end
    result.manifests = result.manifests + 1
  end
  return result, ""
end

--- The lib directory `bin/zig env` names, from its output `text`.
function ZigRestat.lib_dir(text: string): string | nil
  return text:match('%.lib_dir = "([^"]*)"')
end

--- Restats the project cache `project` and, when named, the global
--- cache `shared` ([`ZigRestat.restat`]), with `root` as the directory
--- zig runs in and its build root and `lib` as zig's lib directory: its
--- exit status, and what it says on standard output and on standard
--- error. Nothing to do where `project` holds no manifests. It never
--- fails (0): a cache it cannot read is left as it was and said so,
--- since a cache left so costs only time.
function ZigRestat.command(project: string, shared: string | nil, root: string,
    lib?: string): integer, string, string
  if not Predicate.is_dir(project .. "/h") then
    return 0, "zig-restat: no zig cache at '" .. project .. "'; nothing to restat\n", ""
  end
  local caches: {ZigPrune.Cache} = { { path = project, prefix = 2 } }
  local roots: {integer:string} = { [0] = root, [1] = lib, [4] = root }
  if shared ~= nil and Predicate.is_dir(shared .. "/h") then
    caches[2] = { path = shared, prefix = 3 }
    roots[3] = shared
  end
  local result, trouble = ZigRestat.restat(caches, roots)
  if result == nil then
    return 0, "", "zig-restat: left as restored: " .. trouble .. "\n"
  end
  return 0, "zig-restat: " .. Plural.count(result.records, "file") .. " listed: " ..
    result.adopted .. " given their new inode, " .. result.rehashed ..
    " re-hashed and taken, " .. result.left .. " left; " ..
    Plural.count(result.manifests, "manifest") .. " rewritten\n", ""
end

--- [`ZigRestat.command`] for the tree at `root`, asking its `bin/zig
--- env` for zig's lib directory -- in the tree, with `project` the
--- cache bin/zig names, so that asking makes no cache of its own --
--- only where `project` holds manifests to restat, and leaving the files
--- under the lib directory where zig cannot say.
function ZigRestat.run(root: string, project: string, shared: string | nil): integer, string, string
  if not Predicate.is_dir(project .. "/h") then return ZigRestat.command(project, shared, root) end
  local env = Env.all()
  env.COSMIC_ZIG_CACHE = project
  if shared ~= nil then env.COSMIC_ZIG_GLOBAL_CACHE = shared end
  local lib: string | nil = nil
  local ran, _ = Child.run({ root .. "/bin/zig", "env" }, { cwd = root, env = env,
    stdout = "capture", stderr = "capture" })
  if ran ~= nil and ran.ok then lib = ZigRestat.lib_dir(ran.stdout or "") end
  return ZigRestat.command(project, shared, root, lib)
end

--- `driver.tl zig-restat`: [`ZigRestat.run`] for the tree the driver runs
--- in, over the caches CI restores, the `zig-cache` under
--- COSMIC_ZIG_CACHE_SEED and the global cache COSMIC_ZIG_GLOBAL_CACHE
--- names, as `driver.tl zig-prune` takes them.
function ZigRestat.restat_command(_argv: {string}): integer
  local seed = Env.get("COSMIC_ZIG_CACHE_SEED") or ""
  local shared = Env.get("COSMIC_ZIG_GLOBAL_CACHE")
  local code, out, err = ZigRestat.run(assert(Fs.absolute(".")), seed .. "/zig-cache",
    shared ~= "" and shared or nil)
  if out ~= "" then local _, _ = Fs.put(Fs.stdout, out) end
  if err ~= "" then local _, _ = Fs.put(Fs.stderr, err) end
  return code
end

return ZigRestat
