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
---
--- The cache is CODE THAT WILL BE EXECUTED, which is what makes its
--- location a security property rather than a preference. The key is
--- `sha256(path .. content .. build id)` and every one of those is
--- public, so any local user can compute the key for a script someone
--- else is about to run. In a world-shared directory that is a
--- pre-planted `<key>.lua` the victim's cosmic loads and runs with no
--- compile and no error -- and the reach is wide, since `cosmic.searcher`
--- goes through here for every `.tl` module every embedded artifact
--- requires at boot. So: a per-user directory, created 0700, and a
--- refusal to use one that is not ours or is group/world-writable.
local fs = require("cosmic.fs")
local fs_types = require("cosmic.fs.types")
local hash = require("cosmic.hash")
local user = require("cosmic.user")

--- Bits that must not be set on the cache directory: group and other
--- write. If anyone else can create files there, they can choose what
--- this process executes.
local SHARED_WRITE < const > = tonumber("022", 8) as integer -- cast: octal is integral
local OWNER_ONLY < const > = tonumber("700", 8) as integer -- cast: octal is integral
local OWNER_FILE < const > = tonumber("600", 8) as integer -- cast: octal is integral

--- @return string The cache directory (override with COSMIC_TL_CACHE_DIR)
local function cache_dir(): string
  local named = os.getenv("COSMIC_TL_CACHE_DIR")
  if named and named ~= "" then
    return named
  end
  local xdg = os.getenv("XDG_CACHE_HOME")
  if xdg and xdg ~= "" then
    return fs.join(xdg, "cosmic", "tl")
  end
  -- Under TMPDIR the name has to carry the uid: a fixed name in a
  -- shared /tmp is first-come-first-served, and the loser then reads
  -- from a directory the winner owns.
  return fs.join(os.getenv("TMPDIR") or "/tmp",
    "cosmic-tl-cache-" .. tostring(user.getuid()))
end

--- Is this directory safe to load executable code out of?
---
--- Ours, and writable by nobody else. A directory that fails either
--- test is not repaired -- another user may be holding it open -- it is
--- simply not used, which costs a recompile and nothing else.
--- @param dir string The cache directory
--- @return boolean True when the directory may be trusted
local function trusted(dir: string): boolean
  local st = fs.stat(dir)
  if not st then
    return false
  end
  local info = st as fs_types.Stat -- cast: mixed-representation Stat
  if info:uid() ~= user.getuid() then
    return false
  end
  return info:mode() & SHARED_WRITE == 0
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

--- The cache path for a script, keyed by its CONTENT.
---
--- `content` is passed in rather than read here, because the two
--- callers hold different bytes at different moments: the reader has
--- just read the file it is about to compile, and the writer must key
--- on the bytes it actually COMPILED. Re-reading at store time binds
--- the old code to the new key whenever the file changed in between —
--- a narrow window, and a silent one: every later run then executes
--- code the source no longer says.
--- @param script_path string Path to the .tl script
--- @param content string The script's bytes
--- @return string Cache file path
local function cache_file(script_path: string, content: string): string
  local key = hash.sha256_hex(script_path .. "\0" .. content .. "\0" .. build_id())
  return fs.join(cache_dir(), key .. ".lua")
end

--- Load cached compiled Lua code for a .tl script, if present.
--- @param script_path string Path to the .tl script
--- @param content string The script's bytes, as read by the caller
--- @return string | nil Cached Lua code, or nil on any cache miss
local function load_cached(script_path: string, content: string): string | nil
  local dir = cache_dir()
  if not trusted(dir) then
    return nil
  end
  local path = cache_file(script_path, content)
  if not fs.isfile(path) then
    return nil
  end
  return (fs.read(path))
end

--- Store compiled Lua code for a .tl script in the cache.
--- @param script_path string Path to the .tl script
--- @param content string The bytes that were compiled
--- @param code string Compiled Lua code to cache
local function store(script_path: string, content: string, code: string)
  local path = cache_file(script_path, content)
  local dir = cache_dir()
  if not fs.exists(dir) then
    -- 0700 at creation, not chmod after: a window in which the
    -- directory exists group-writable is a window in which an entry
    -- can be planted.
    if not fs.makedirs(dir, OWNER_ONLY) then
      return
    end
  end
  if not trusted(dir) then
    return
  end
  fs.write(path, code, OWNER_FILE)
end

--- Compile a Teal file, reusing cached output when the source has not
--- changed.
---
--- The load/compile/store loop for both callers — the runtime `.tl`
--- searcher and the script runner — while what to do with a failure
--- stays theirs (one raises, one returns). Nothing reports a cache
--- problem: the cache is best-effort by contract, so a miss and a
--- broken cache both mean "compile".
---
--- One read, keying both halves: re-reading the source at store time
--- would cache this code under the NEXT edit's key, and every run after
--- that edit would execute code the file no longer contains.
--- @param input_path string Path to the Teal file to compile
--- @return string|nil The generated Lua code, or nil when compilation failed
--- @return string The formatted issues when compilation failed
local function compile_cached(input_path: string): string | nil, string
  local content = fs.read(input_path)
  if not content then
    return nil, "cannot read " .. input_path
  end
  local source = content as string -- cast: scalar narrowing after the guard
  local code = load_cached(input_path, source)
  if code then
    return code
  end
  local teal = require("cosmic.teal")
  local result = teal.compile(input_path, {})
  if not result.ok then
    return nil, teal.format_issues(result.errors)
  end
  local generated = result.code as string -- cast: set whenever ok
  store(input_path, source, generated)
  return generated
end

return {
  load = load_cached,
  store = store,
  compile_cached = compile_cached,
}
