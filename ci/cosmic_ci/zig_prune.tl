--- What a leg's zig build outputs no longer vouch for, cut before ci.yml
--- saves them (`driver.tl zig-prune`).
---
--- zig keeps two caches, each a directory of manifests (`h/<name>.txt`)
--- and of outputs (`o/<digest>/`). A step's manifest is named by the
--- step's own inputs (its command, the paths of its files) and lists
--- each file it read with that file's digest; the output directory it
--- vouches for is named by the manifest's name and those digests, in the
--- manifest's order, under zig's SipHash128-1-3 (std/Build/Cache.zig's
--- `hit` and `final`). zig trusts a manifest's output whole: on a hit it
--- uses the directory without looking inside, so a build fails where a
--- manifest is kept and its output is not. It finds a missing input a
--- miss, though, and builds again.
---
--- A step whose inputs change writes its manifest again, under the same
--- name, vouching for a new directory: the old one is then no manifest's
--- (an orphan), and no hit returns it. A core change does this to the
--- copies of core/ every compile reads (a WriteFile step's output), so
--- each compile and link of the old core lists an orphan's file as its
--- input, and no build of the tree hits it again short of the old core
--- itself; their outputs, every target's linked core among them, are
--- most of what the queue's runs add to an entry. `plan` finds them: the
--- orphans superseded so, each holding only files by names some
--- directory a manifest vouches for holds too (the newer copy's), then
--- every manifest that lists a file in a directory being removed, with
--- the output it vouches for (unless another manifest kept vouches for
--- it too), until none is left. What it removes costs a later build
--- only a compile; what it keeps is whole. An orphan that matches no
--- such directory is kept, and nothing is removed for it: zig writes
--- some outputs with no manifest at all (`zig build`'s
--- `dependencies.zig`, which its build runner's manifest lists), and
--- removing one would cost every later build its runner.
---
--- It removes nothing at all where a manifest does not read as one or
--- vouches for no directory there: zig's format is then not the one
--- read here (a new zig), and nothing it says can be trusted.

local Codec = require("cosmic.codec")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Plural = require("cosmic_ci.plural")
local Predicate = require("cosmic_ci.fs_predicate")

local record ZigPrune
  --- One of zig's caches: its directory and the prefix by which zig's
  --- manifests name a file in it (std/Build/Cache.zig's `prefixes`:
  --- 2 the project's cache, 3 the global one).
  record Cache
    path: string
    prefix: integer
  end

  --- What `plan` found: the manifests and output directories to remove,
  --- by path, and how many of each it saw.
  record Plan
    manifests: {string}
    outputs: {string}
    manifests_seen: integer
    outputs_seen: integer
    --- How many outputs no manifest vouches for, and how many of them
    --- it keeps (no newer copy of theirs found).
    orphans: integer
    orphans_kept: integer
  end

  zig_version: string
end

--- The zig whose caches this reads (bin/zig.pin's `version`), which
--- cosmic_ci/zig_prune_test.tl holds the pin to: a new one may name its
--- outputs otherwise, and then `plan` keeps every cache whole.
ZigPrune.zig_version = "0.16.0"

--- zig's `hasher_init` key (std/Build/Cache.zig), which a zig that
--- changes its manifests' format changes too.
local key <const> = string.char(0x33, 0x52, 0xa2, 0x84, 0xcf, 0x17, 0x56, 0x57,
  0x01, 0xbb, 0xcd, 0xe4, 0x77, 0xd6, 0xf0, 0x60)

local function rotl(x: integer, b: integer): integer
  return (x << b) | (x >> (64 - b))
end

--- SipHash128-1-3 of `message` under the 16-byte `k`: zig's
--- `crypto.auth.siphash.SipHash128(1, 3)`, 16 raw bytes.
function ZigPrune.siphash128(k: string, message: string): string
  local k0, k1 = string.unpack("<i8<i8", k)
  local v0 = k0 ~ 0x736f6d6570736575
  local v1 = k1 ~ 0x646f72616e646f6d
  local v2 = k0 ~ 0x6c7967656e657261
  local v3 = k1 ~ 0x7465646279746573
  v1 = v1 ~ 0xee
  local function round()
    v0 = v0 + v1; v1 = rotl(v1, 13); v1 = v1 ~ v0; v0 = rotl(v0, 32)
    v2 = v2 + v3; v3 = rotl(v3, 16); v3 = v3 ~ v2
    v0 = v0 + v3; v3 = rotl(v3, 21); v3 = v3 ~ v0
    v2 = v2 + v1; v1 = rotl(v1, 17); v1 = v1 ~ v2; v2 = rotl(v2, 32)
  end
  local n = #message
  local whole = n - n % 8
  local at = 1
  while at <= whole do
    local m = string.unpack("<i8", message, at)
    v3 = v3 ~ m; round(); v0 = v0 ~ m
    at = at + 8
  end
  local tail = message:sub(whole + 1) .. string.rep("\0", 8 - (n - whole))
  local b = string.unpack("<i8", tail) | ((n & 0xff) << 56)
  v3 = v3 ~ b; round(); v0 = v0 ~ b
  v2 = v2 ~ 0xee
  round(); round(); round()
  local first = v0 ~ v1 ~ v2 ~ v3
  v1 = v1 ~ 0xdd
  round(); round(); round()
  return string.pack("<i8<i8", first, v0 ~ v1 ~ v2 ~ v3)
end

--- A manifest, as `read` finds it: the output it vouches for and the
--- outputs, of either cache, it lists a file of, each as
--- "<prefix>/<digest>".
local record Manifest
  output: string
  inputs: {string}
end

--- The manifest `name` (its file's name, `<hex>.txt`) whose text is
--- `text`, in a cache of `prefix`: nil and why where it does not read
--- as zig's (a header of "0", then a line a file:
--- `size inode mtime digest prefix path`).
local function read(name: string, text: string, prefix: integer): Manifest | nil, string
  local hex = name:match("^(%x+)%.txt$")
  local named = hex and #hex == 32 and Codec.unhex(hex) or nil
  if named == nil then return nil, "not named as a manifest" end
  local parts: {string} = { named }
  local inputs: {string} = {}
  local first = true
  for line in text:gmatch("([^\n]*)\n?") do
    if first then
      if line ~= "0" then return nil, "a header of '" .. line:sub(1, 40) .. "'" end
      first = false
    elseif line ~= "" then
      local digest, file_prefix, path = line:match("^%d+ %d+ %-?%d+ (%x+) (%d+) (.*)$")
      local raw = digest and #digest == 32 and Codec.unhex(digest) or nil
      if raw == nil then return nil, "a line '" .. line:sub(1, 80) .. "'" end
      parts[#parts + 1] = raw
      local within = path:match("^o/(%x+)/") or path:match("^o/(%x+)$")
      if within and (file_prefix == "2" or file_prefix == "3") then
        inputs[#inputs + 1] = file_prefix .. "/" .. within
      end
    end
  end
  if first then return nil, "empty" end
  local output = prefix .. "/" .. Codec.hex(ZigPrune.siphash128(key, table.concat(parts)))
  return { output = output, inputs = inputs }, ""
end

--- The output directory, by its name under `o/`, that the manifest
--- `name` (its file's name, `<hex>.txt`) whose text is `text` vouches
--- for: nil and why where it does not read as zig's.
function ZigPrune.vouches(name: string, text: string): string | nil, string
  local manifest, trouble = read(name, text, 0)
  if manifest == nil then return nil, trouble end
  return (manifest.output:match("/(.*)$")), ""
end

--- What to remove from `caches` (see the module's doc): nil and why
--- where one of them cannot be read whole, a manifest does not read as
--- zig's, or one vouches for an output that is not there.
function ZigPrune.plan(caches: {ZigPrune.Cache}): ZigPrune.Plan | nil, string
  local manifests: {string:Manifest} = {}
  local vouching: {string:{string}} = {}
  local outputs: {string:string} = {}
  -- Each output's files, as paths under it.
  local files: {string:{string}} = {}
  local where: {integer:string} = {}
  local outputs_seen = 0
  for _, cache in ipairs(caches) do
    where[cache.prefix] = cache.path
    local dirs, dirs_trouble = Fs.list(cache.path .. "/o")
    if dirs == nil then return nil, cache.path .. "/o: " .. dirs_trouble end
    for _, dir in ipairs(dirs) do
      outputs[cache.prefix .. "/" .. dir] = cache.path .. "/o/" .. dir
      files[cache.prefix .. "/" .. dir] = {}
      outputs_seen = outputs_seen + 1
    end
    local walked, walk_trouble = Fs.walk(cache.path .. "/o")
    if walked == nil then return nil, cache.path .. "/o: " .. walk_trouble end
    for _, path in ipairs(walked) do
      local dir, under = path:match("^([^/]+)/(.+)$")
      local list = dir and files[cache.prefix .. "/" .. dir] or nil
      if list then list[#list + 1] = under end
    end
  end
  for _, cache in ipairs(caches) do
    local names, names_trouble = Fs.list(cache.path .. "/h")
    if names == nil then return nil, cache.path .. "/h: " .. names_trouble end
    for _, name in ipairs(names) do
      -- `timestamp`, zig's clock's mark, is no manifest.
      if name:sub(-4) == ".txt" then
        local path = cache.path .. "/h/" .. name
        local text, text_trouble = Fs.read(path)
        if text == nil then return nil, path .. ": " .. text_trouble end
        local manifest, trouble = read(name, text, cache.prefix)
        if manifest == nil then return nil, path .. ": " .. trouble end
        if outputs[manifest.output] == nil then
          return nil, path .. " vouches for " .. where[cache.prefix] .. "/o/" ..
            manifest.output:match("/(.*)$") .. ", which is not there"
        end
        manifests[path] = manifest
        local list = vouching[manifest.output] or {}
        list[#list + 1] = path
        vouching[manifest.output] = list
      end
    end
  end
  -- The names of the files of every output some manifest vouches for.
  local vouched_files: {string:boolean} = {}
  for output in pairs(vouching) do
    for _, under in ipairs(files[output]) do vouched_files[under] = true end
  end
  local removed: {string:boolean} = {}
  local orphans, orphans_kept = 0, 0
  for output in pairs(outputs) do
    if vouching[output] == nil then
      orphans = orphans + 1
      local superseded = #files[output] > 0
      for _, under in ipairs(files[output]) do
        if not vouched_files[under] then superseded = false; break end
      end
      if superseded then removed[output] = true else orphans_kept = orphans_kept + 1 end
    end
  end
  local gone: {string:boolean} = {}
  local moved = true
  while moved do
    moved = false
    for path, manifest in pairs(manifests) do
      if not gone[path] then
        for _, input in ipairs(manifest.inputs) do
          if removed[input] then
            gone[path] = true
            moved = true
            break
          end
        end
      end
    end
    for output, list in pairs(vouching) do
      if not removed[output] then
        local all = true
        for _, path in ipairs(list) do
          if not gone[path] then all = false; break end
        end
        if all then removed[output] = true; moved = true end
      end
    end
  end
  local plan: ZigPrune.Plan = { manifests = {}, outputs = {}, orphans = orphans,
    orphans_kept = orphans_kept,
    outputs_seen = outputs_seen, manifests_seen = 0 }
  for path in pairs(manifests) do
    plan.manifests_seen = plan.manifests_seen + 1
    if gone[path] then plan.manifests[#plan.manifests + 1] = path end
  end
  for output in pairs(removed) do plan.outputs[#plan.outputs + 1] = outputs[output] end
  table.sort(plan.manifests)
  table.sort(plan.outputs)
  return plan, ""
end

--- Removes what `plan` named: each manifest before any output, so that
--- a removal cut short leaves no manifest whose output is gone; false
--- and why where one could not be removed.
function ZigPrune.apply(plan: ZigPrune.Plan): boolean, string
  for _, path in ipairs(plan.manifests) do
    local ok, trouble = Fs.remove(path)
    if not ok then return false, path .. ": " .. trouble end
  end
  for _, path in ipairs(plan.outputs) do
    local ok, trouble = Fs.remove_tree(path)
    if not ok then return false, path .. ": " .. trouble end
  end
  return true, ""
end

--- `driver.tl zig-prune` in `env`: its exit status, and what it says on
--- standard output and on standard error. It prunes the project cache
--- under `env.COSMIC_ZIG_CACHE_SEED` (its `zig-cache`, where ci.yml
--- restores it and the driver's builds use it) and the global cache
--- `env.COSMIC_ZIG_GLOBAL_CACHE` names, together, since a manifest of
--- one may list a file of the other. Nothing to do where either is not
--- there. It never fails (0): a cache it cannot read is left whole and
--- said so, on standard error, since a cache too large costs only time.
function ZigPrune.command(env: {string:string}): integer, string, string
  local seed = env.COSMIC_ZIG_CACHE_SEED or ""
  local shared = env.COSMIC_ZIG_GLOBAL_CACHE or ""
  local project = seed ~= "" and seed .. "/zig-cache" or ""
  if project == "" or shared == "" or not Predicate.is_dir(project .. "/h") or
      not Predicate.is_dir(shared .. "/h") then
    return 0, "zig-prune: no zig caches at '" .. project .. "' and '" .. shared ..
      "'; nothing to prune\n", ""
  end
  local plan, trouble = ZigPrune.plan({ { path = project, prefix = 2 }, { path = shared, prefix = 3 } })
  if plan == nil then
    return 0, "", "zig-prune: kept whole: " .. trouble .. "\n"
  end
  local ok, apply_trouble = ZigPrune.apply(plan)
  if not ok then
    return 0, "", "zig-prune: stopped: " .. apply_trouble .. "\n"
  end
  return 0, "zig-prune: removed " .. Plural.count(#plan.manifests, "manifest") .. " of " ..
    plan.manifests_seen .. " and " .. Plural.count(#plan.outputs, "output") .. " of " ..
    plan.outputs_seen .. " (" .. Plural.count(plan.orphans, "orphan") .. ", " ..
    plan.orphans_kept .. " kept)\n", ""
end

--- `driver.tl zig-prune`, in the driver's environment (`command`).
function ZigPrune.prune_command(_argv: {string}): integer
  local code, out, err = ZigPrune.command(Env.all())
  if out ~= "" then local _, _ = Fs.put(Fs.stdout, out) end
  if err ~= "" then local _, _ = Fs.put(Fs.stderr, err) end
  return code
end

return ZigPrune
