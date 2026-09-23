--- Shared caching over `cosmic.http`, used by `build/vendor.tl` and
--- `build/zig.tl` alike: a per-tool directory under
--- `$XDG_CACHE_HOME/cosmic` (default `$HOME/.cache/cosmic`), and a
--- download that trusts an existing cached file only when its sha256
--- still matches what the caller wants -- a stale or corrupt cache
--- entry is refetched, never silently reused.

local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Http = require("cosmic.http")

local record Fetch
end

--- `$XDG_CACHE_HOME/cosmic/<tool>`, or `$HOME/.cache/cosmic/<tool>`
--- when `XDG_CACHE_HOME` is unset or empty -- the same layout the
--- shell scripts this replaces used.
function Fetch.cache_dir(tool: string): string
  local base = Env.get("XDG_CACHE_HOME")
  if base == nil or base == "" then
    base = Env.get_or("HOME", "/tmp") .. "/.cache"
  end
  return base .. "/cosmic/" .. tool
end

--- True when `path` exists and its sha256 is `sha256` (case-insensitive
--- on `sha256`'s own hex, never on the file's bytes).
function Fetch.matches(path: string, sha256: string): boolean
  local data = Fs.read(path)
  if data == nil then
    return false
  end
  return Hash.hex_sha256(data) == sha256:lower()
end

--- `path`, downloading `url` into it first unless it is already there
--- with the right sha256. A stale cached file (wrong hash) is removed
--- before the download, so a caller never sees a half-verified reuse;
--- `Http.download` itself never leaves a partial file at `path`.
function Fetch.file(url: string, path: string, sha256: string): string | nil, string
  if Fetch.matches(path, sha256) then
    return path, ""
  end
  Fs.remove(path)
  local dir = path:match("^(.*)/[^/]+$")
  if dir ~= nil then
    local made, mtrouble = Fs.mkdirs(dir)
    if not made then
      return nil, mtrouble
    end
  end
  local ok, dtrouble = Http.download(url, path, { sha256 = sha256 })
  if not ok then
    return nil, dtrouble
  end
  return path, ""
end

return Fetch
