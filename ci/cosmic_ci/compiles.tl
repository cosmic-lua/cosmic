--- The compiles and parses a leg keeps from one run to the next: the file
--- COSMIC_BUILD_CACHE names (build/shared_compiles.tl in the candidate),
--- which ci.yml restores before the leg's builds and saves after them.
---
--- The file bounds itself only at 256 MB and thirty days, and a change
--- to the build's own modules moves every row's key. A file that each
--- run saved back whole would grow by a tree's worth of compiles (about
--- 3 MB) with most commits to main, up to that bound, and the
--- repository's cache, which holds 10 GB in all, would hold that much
--- again with each save. So a leg keeps only what its own run used or
--- compiled (`trim`): what the next run of the tree it built needs.
---
--- Like the builds, which never fail over this cache, a trim that cannot
--- read it never fails the leg (cosmic_ci/cache_trim.tl, which the
--- verdicts' trim shares).

local CacheTrim = require("cosmic_ci.cache_trim")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Predicate = require("cosmic_ci.fs_predicate")

local record Compiles
end

--- The tables of build/shared_compiles.tl's formats (`compiled_v<n>`,
--- `parsed_v<n>`), every row of which goes where no build used or made
--- it since.
local tables: CacheTrim.Tables = { patterns = { "compiled_v[0-9]*", "parsed_v[0-9]*" },
  whole_unless_reached = false }

--- Removes from the cache at `path` every compile and parse no build
--- has used or made since `since_ns` (the wall clock, as the cache's
--- `used_ns` is), then rewrites the file without the space they took
--- ([`CacheTrim.trim`]). Nil and "" for a file that is not there, which a
--- leg whose builds never started leaves, and nil and why where the
--- file could not be trimmed.
function Compiles.trim(path: string, since_ns: integer): CacheTrim.Trimmed | nil, string
  return CacheTrim.trim(path, since_ns, tables)
end

--- `driver.tl compiles-trim SINCE` in `env`: its exit status, and what
--- it says on standard output and on standard error. It trims the cache
--- `env.COSMIC_BUILD_CACHE` names to what was used since SINCE, in Unix
--- seconds, and removes the caches set aside beside it
--- ([`CacheTrim.file`]), then writes `digest=<hex>` of the rows left
--- ([`CacheTrim.digest`]) to the step's outputs ([`CacheTrim.output`]), the
--- tail of the key ci.yml saves the cache under. Nothing to do, and no
--- digest, where the variable names no file or the file is not there.
--- Only a SINCE that is no count of seconds fails it (2): a cache it
--- cannot trim is said so, on standard error, and left, or removed where
--- it is no database.
function Compiles.command(argv: {string}, env: {string:string}): integer, string, string
  local since = CacheTrim.since(argv)
  if since == nil then
    return 2, "", "compiles-trim: SINCE must be Unix seconds\n"
  end
  local path = env.COSMIC_BUILD_CACHE or ""
  if path:sub(1, 1) ~= "/" then
    return 0, "compiles-trim: COSMIC_BUILD_CACHE names no file ('" .. path ..
      "'); nothing to trim\n", ""
  end
  local out, err = CacheTrim.file("compiles-trim", path, since, tables)
  if Predicate.exists(path) then
    local digest, trouble = CacheTrim.digest({ path })
    if trouble ~= "" then err = err .. "compiles-trim: " .. trouble .. "\n" end
    out = out .. "compiles-trim: digest " .. digest .. "\n"
    local unsaid = CacheTrim.output(env, "digest", digest)
    if unsaid ~= "" then err = err .. "compiles-trim: " .. unsaid .. "\n" end
  end
  return 0, out, err
end

--- `driver.tl compiles-trim SINCE`, in the driver's environment
--- (`command`).
function Compiles.trim_command(argv: {string}): integer
  local code, out, err = Compiles.command(argv, Env.all())
  if out ~= "" then local _, _ = Fs.put(Fs.stdout, out) end
  if err ~= "" then local _, _ = Fs.put(Fs.stderr, err) end
  return code
end

return Compiles
