--- Caches compiled Lua output for `.tl` sources, keyed by path +
--- content + cosmic build version, so a repeat compile of an unchanged
--- source skips Teal entirely.
---
--- One caller: `cosmic.teal.compile_cached`, which is what the runtime
--- `.tl` searcher and the script runner both go through. That is why
--- this is internal to `cosmic/` again — 3h briefly made it public
--- because the script runner reached past `cosmic.teal` to it, and the
--- right fix was to stop reaching rather than to publish the reach.
---
--- Hashing the content rather than trusting an mtime is deliberate: it
--- costs one read next to a full Teal compile, and it cannot produce a
--- stale hit from coarse filesystem mtime granularity. The build id is
--- in the key because a different cosmic embeds a different compiler.
---
--- Best-effort by contract: any cache read/write failure (missing
--- directory, no write permission, a race with another process) is a
--- miss or a no-op, never an error. Compiling must still work with no
--- cache at all, so nothing here returns one.
local fs = require("cosmic.fs")
local hash = require("cosmic.hash")

--- @return string The cache directory (override with COSMIC_TL_CACHE_DIR)
local function cache_dir(): string
  return os.getenv("COSMIC_TL_CACHE_DIR") or
  fs.join(os.getenv("TMPDIR") or "/tmp", "cosmic-tl-cache")
end

--- Build identifier included in the cache key, so a different cosmic
--- binary (embedded Teal compiler may differ) never reuses another
--- build's cached output. Falls back to a constant when unavailable
--- (e.g. a dev build without the generated version module).
--- @return string
local function build_id(): string
  local mod = "cosmic._version"
  local ok, ver = pcall(require, mod)
  if ok then
    return tostring((ver as {string: string}).cosmic) -- cast: from any
  end
  return "unknown"
end

--- @param script_path string Path to the .tl script
--- @return string Cache file path, or nil if the script can't be read
local function cache_file(script_path: string): string | nil
  local content = fs.read(script_path)
  if not content then
    return nil
  end
  local key = hash.sha256_hex(script_path .. "\0" .. content .. "\0" .. build_id())
  return fs.join(cache_dir(), key .. ".lua")
end

--- Load cached compiled Lua code for a .tl script, if present and fresh.
--- @param script_path string Path to the .tl script
--- @return string | nil Cached Lua code, or nil on any cache miss
local function load_cached(script_path: string): string | nil
  local path = cache_file(script_path)
  if not path or not fs.isfile(path) then
    return nil
  end
  return (fs.read(path))
end

--- Store compiled Lua code for a .tl script in the cache.
--- @param script_path string Path to the .tl script
--- @param code string Compiled Lua code to cache
local function store(script_path: string, code: string)
  local path = cache_file(script_path)
  if not path then
    return
  end
  if fs.makedirs(cache_dir()) then
    fs.write(path, code)
  end
end

return {load = load_cached, store = store}
