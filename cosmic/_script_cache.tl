--- Caches compiled Lua output for `.tl` sources, keyed by path +
--- content + cosmic build version, so a repeat compile of an unchanged
--- source skips Teal entirely.
---
--- One caller: `cosmic.teal.compile_cached`, which is what the runtime
--- `.tl` searcher and the script runner both go through. That is why
--- this is internal to `cosmic/`
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
  local info = st as fs_types.Stat -- cast: record union after guard
  if info:uid() ~= user.getuid() then
    return false
  end
  return info:mode() & SHARED_WRITE == 0
end

--- Build identifier included in the cache key, so a different cosmic
--- binary (embedded Teal compiler may differ) never reuses another
--- build's cached output.
---
--- The version stamp answers for a RELEASE. It does not answer for a
--- dev build, where it is "unknown" for every binary anyone builds --
--- so two locally built cosmics with different embedded compilers
--- shared one key, which is the collision this id exists to prevent.
--- The binary's own size and mtime answer there: `--make build`
--- replaces the artifact only when its bytes change, so the stamp moves
--- exactly when the compiler might have.
--- @return string
local function build_id(): string
  local mod = "cosmic._version"
  local ok, ver = pcall(require, mod)
  if ok then
    local stamp = (ver as {string: string}).cosmic -- cast: from any
    if stamp and stamp ~= "" and stamp ~= "unknown" then
      return stamp
    end
  end
  local self = arg and arg[-1]
  local info = self and fs.stat(self)
  if info then
    local st = info
    local secs = st:modify_time().secs
    return "dev-" .. tostring(st:size()) .. "-" .. tostring(secs)
  end
  return "unknown"
end

--- The cache path for a script, keyed by its CONTENT.
---
--- `content` is passed in rather than read here, because the two
--- callers hold different bytes at different moments: the reader has
--- just read the file it is about to compile, and the writer must key
--- on the bytes it actually COMPILED. Re-reading at store time binds
--- the compiled code to the NEW key whenever the file changed in
--- between — a narrow window, and a silent one: every later run then
--- executes code the source does not contain.
---
--- `mode` names the COMPILE CONFIGURATION, and it is in the key for the
--- same reason the build id is: the same bytes compiled two ways are
--- two different programs, and a key that cannot tell them apart hands
--- one caller the other's output. Lax passes "" so its keys are
--- unchanged.
--- @param script_path string Path to the .tl script
--- @param content string The script's bytes
--- @param mode? string The compile configuration ("" for lax)
--- @return string Cache file path
local function cache_file(script_path: string, content: string,
    mode?: string): string
  local key = hash.sha256_hex(script_path .. "\0" .. content .. "\0"
    .. build_id() .. "\0" .. (mode or ""))
  return fs.join(cache_dir(), key .. ".lua")
end

--- Load cached compiled Lua code for a .tl script, if present.
--- @param script_path string Path to the .tl script
--- @param content string The script's bytes, as read by the caller
--- @param mode? string The compile configuration ("" for lax)
--- @return string | nil Cached Lua code, or nil on any cache miss
local function load_cached(script_path: string, content: string,
    mode?: string): string | nil
  local dir = cache_dir()
  if not trusted(dir) then
    return nil
  end
  local path = cache_file(script_path, content, mode)
  if not fs.is_file(path) then
    return nil
  end
  return (fs.read(path))
end

--- Store compiled Lua code for a .tl script in the cache.
--- @param script_path string Path to the .tl script
--- @param content string The bytes that were compiled
--- @param code string Compiled Lua code to cache
--- @param mode? string The compile configuration ("" for lax)
local function store(script_path: string, content: string, code: string,
    mode?: string)
  local path = cache_file(script_path, content, mode)
  local dir = cache_dir()
  if not fs.is_present(dir) then
    -- 0700 at creation, not chmod after: a window in which the
    -- directory exists group-writable is a window in which an entry
    -- can be planted.
    if not fs.make_dirs(dir, OWNER_ONLY) then
      return
    end
  end
  if not trusted(dir) then
    return
  end
  local _ok, _err = fs.write(path, code, {mode = OWNER_FILE})
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
---
--- `strict` selects the in-project configuration: type errors fail the
--- compile, warnings do NOT. The two halves are deliberate and are
--- argued in `cosmic.searcher`. It keys its own cache entries, so the
--- two configurations cannot serve each other's output.
--- @param input_path string Path to the .tl file to compile
--- @param strict? boolean Type-check strictly before generating
--- @return string|nil The generated Lua code, or nil when compilation failed
--- @return string The formatted issues when compilation failed
local function compile_cached(input_path: string,
    strict?: boolean): string | nil, string
  local content = fs.read(input_path)
  if not content then
    return nil, "cannot read " .. input_path
  end
  local source = content
  local mode = strict and "strict" or ""
  local code = load_cached(input_path, source, mode)
  if code then
    return code
  end
  local teal = require("cosmic.teal")
  local result = teal.compile_file(input_path,
    strict and {strict = true, werror = false} or {})
  if not result.ok then
    -- With hints: a script run is many authors' first contact with the
    -- checker, and the un-narrowed `T | nil` traps have known fixes the
    -- bare message does not teach.
    return nil, teal.format_issues(result.errors, {hints = true})
  end
  local generated = result.code as string -- cast: set whenever ok
  store(input_path, source, generated, mode)
  return generated
end

return {
  build_id = build_id,
  -- Exported for the security test that plants an entry: it must key
  -- the plant exactly as this module would, and rebuilding the key
  -- shape over there means a plant that silently stops reproducing the
  -- attack whenever the shape changes (the build id and, since
  -- in-project resolution, the compile configuration). A security test
  -- that passes because it planted the wrong file is worse than one
  -- that fails.
  key = cache_file,
  load = load_cached,
  store = store,
  compile_cached = compile_cached,
}
