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
---
--- A branch's push saves its trimmed cache too, under a key of the
--- branch's own, where its builds compiled many modules the entry it
--- restored did not hold: a change to the compiler's identity
--- moves every row's key, so each later push of that branch would
--- otherwise compile the whole tree again on every leg.

local CacheTrim = require("cosmic_ci.cache_trim")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")

local record Compiles
end

--- Trims through the running driver, preserving its format ownership.
--- RESTORED is an owned snapshot, cleaned before signal redelivery even
--- on failure. Invalid arguments fail; maintenance remains best effort.
function Compiles.command(argv: {string}, env: {string:string}): integer, string, string
  local since = CacheTrim.since(argv)
  if since == nil then return 2, "", "compiles-trim: SINCE must be bounded Unix seconds\n" end
  local restored = argv[2]
  if restored ~= nil and (restored:sub(1, 1) ~= "/" or restored:find("\0", 1, true)) then
    return 2, "", "compiles-trim: RESTORED must be an absolute path without NUL\n"
  end
  local path = env.COSMIC_BUILD_CACHE or ""
  local paths: {string} = {}
  if path:sub(1, 1) == "/" then
    if path:find("\0", 1, true) then return 2, "", "compiles-trim: cache path contains NUL\n" end
    if restored ~= nil then
      local safe, why = CacheTrim.snapshot_safe(path, restored)
      if safe == false then return 2, "", "compiles-trim: " .. why .. "\n" end
      if safe == nil then return 0, "", "compiles-trim: snapshot retained: " .. why .. "\n" end
    end
    paths[1] = path
  end
  local out, err = CacheTrim.run({ family = "compiles", paths = paths,
    since_ns = since, whole = false, restored = restored }, env)
  if #paths == 0 then out = "compiles-trim: COSMIC_BUILD_CACHE names no file; nothing to trim\n" .. out end
  return 0, out, err
end

--- `driver.tl compiles-trim SINCE [RESTORED]` in the driver's environment.
function Compiles.trim_command(argv: {string}): integer
  local code, out, err = Compiles.command(argv, Env.all())
  if out ~= "" then local _, _ = Fs.put(Fs.stdout, out) end
  if err ~= "" then local _, _ = Fs.put(Fs.stderr, err) end
  return code
end

return Compiles
