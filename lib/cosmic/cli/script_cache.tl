--- Caches compiled Lua output for .tl scripts run directly (`cosmic
--- script.tl`), keyed by path + content + cosmic build version, so a
--- repeat run of an unchanged script skips Teal compilation entirely.
--- Reading the source to hash it is cheap next to a full Teal compile,
--- and (unlike an mtime-based key) can't produce a stale hit from
--- coarse filesystem mtime granularity. Best-effort: any cache
--- read/write failure (missing dir, no write permission, a race with
--- another process, etc.) is treated as a cache miss/no-op, never a
--- hard error — running the script must still work with no cache at all.
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
  local mod = "cosmic.version"
  local ok, ver = pcall(require, mod)
  if ok then
    return tostring((ver as {string: string}).cosmic)
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
