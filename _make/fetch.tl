--- The `fetch` verb: resolve `*_pin.tl` into bytes under `o/`.
---
--- The only verb with a network. That is the whole posture, and it is
--- structural rather than aspirational: this is the one module in
--- `_make` that requires `cosmic.fetch` at all, so "does a build
--- phone home" is answered by grepping the imports of five files.
---
--- Verification is not optional and not after the fact — bytes that do
--- not hash to the pin are never written. A build therefore either runs
--- on the bytes you named or does not run.

local cfetch = require("cosmic.fetch")
local env = require("cosmic.env")
local extract = require("_make.extract")
local fs = require("cosmic.fs")
local hash = require("cosmic.hash")
local pin = require("_make.pin")
local project = require("_make.project")
local selection = require("_make.select")
local types = require("_make.types")

local type File = types.File
local type Pin = pin.Pin
local type Project = types.Project

--- Transport limits, matching the older `_build` fetcher so the two
--- readers of the same committed pins behave the same way: a transient
--- blip retries instead of failing the verb, and an unexpectedly huge
--- response is refused rather than buffered whole.
local ATTEMPTS < const > = 8
local MAX_BODY < const > = 100 * 1024 * 1024

--- Where a pin's bytes land: under the build directory, mirroring the
--- pin's position in the tree.
---
--- A fetched archive is generated content, and nothing generated
--- belongs in the tree — beside its pin it would be a file `check`
--- sees, `lint` scans, and a clean checkout does not have. The pin
--- names the asset; the build says where it goes.
--- @param p Pin The resolved pin
--- @return string The output path, relative to the project root
local function landing(p: Pin): string
  return fs.join(project.BUILD_DIR, p.output)
end

--- The manifest written after a format pin's archive is unpacked: one
--- unpacked path per line, relative to the archive's directory.
---
--- A pin that unpacks has two outputs, and only one of them is
--- content-addressed. Hashing the archive alone answered "did the
--- bytes arrive", never "did they come out" — so an unpack that failed
--- once (ENOSPC, a kill, a bad member), or products deleted later
--- while the archive survived, left a state where every `fetch` hashed
--- the archive, said PASS, and never unpacked again. The tree stayed
--- missing and nothing pointed back at fetch.
---
--- It records the paths rather than a bare "done" flag because the two
--- failure shapes need different evidence: a flag answers "did unpack
--- finish", and only the list answers "is what it produced still
--- there".
---
--- The line delimiter is safe because the extractors refuse control
--- characters in member names (`cosmic.tar.unsafe_path`,
--- `cosmic.embed.extract.unsafe_entry`) — archive members are
--- attacker-shaped input, and a member called `a\nb.txt` would be
--- recorded as two names, neither of which exists, so every later fetch
--- would decide the pin needs repair. Forever, silently. That guard is
--- what this format rests on; weakening it re-opens this.
--- @param archive string The verified archive's path
--- @return string The manifest path
local function manifest_of(archive: string): string
  return archive .. ".unpacked"
end

--- Are all of an unpack's products still on disk?
--- @param archive string The verified archive's path
--- @return boolean True when the manifest exists and every path does
local function products_present(archive: string): boolean
  local listed = fs.read(manifest_of(archive))
  if not listed then
    return false
  end
  local dir = fs.dirname(archive)
  for line in (listed as string):gmatch("([^\n]+)") do -- cast: scalar narrowing
    if not fs.exists(fs.join(dir, line)) then
      return false
    end
  end
  return true
end

--- Unpack a pin that declares a format, beside the archive.
---
--- Only after the digest matched: an archive is a program for a
--- decompressor, and running one on unverified bytes is what pinning
--- exists to prevent.
--- @param p Pin The resolved pin
--- @param archive string The verified archive's path
--- @return boolean, string Success, or false plus the reason
local function unpacked(p: Pin, archive: string): boolean, string
  if not p.format then
    return true
  end
  -- Clear any previous run's manifest first, so a re-unpack that fails
  -- cannot leave the old claim standing over a tree it did not produce.
  fs.rmrf(manifest_of(archive))
  local produced, err = extract.unpack(archive, fs.dirname(archive), p.format,
    p.strip_components)
  if not produced then
    return false, err
  end
  local wok, werr = fs.write(manifest_of(archive),
    table.concat(produced as {string}, "\n") .. "\n") -- cast: record union after the guard
  if not wok then
    return false, "make: cannot write " .. manifest_of(archive) .. ": " ..
    (werr or "unknown error")
  end
  return true
end

--- Is this pin already satisfied? A pin is content-addressed, so the
--- question is about bytes, never about mtimes: an output that hashes
--- correctly is the output, whenever it was written. For a pin that
--- unpacks, its products must also still be there — see `manifest_of`.
--- @param p Pin The resolved pin
--- @return boolean True when the output is present and verified
local function satisfied(p: Pin): boolean
  local out = landing(p)
  local have = fs.read(out)
  if not have then
    return false
  end
  if hash.sha256_hex(have) ~= p.sha256 then
    return false
  end
  if p.format and not products_present(out) then
    return false
  end
  return true
end

--- Fetch one pin, verifying before it lands.
--- @param p Pin The resolved pin
--- @return boolean, string Success, or false plus the reason
local function one(p: Pin): boolean, string
  if satisfied(p) then
    return true
  end
  local out = landing(p)
  -- Not satisfied can still mean "the archive is right, the products
  -- are not" -- a failed or half-deleted unpack. Re-unpacking is the
  -- whole repair, so do that rather than re-downloading bytes the
  -- digest already vouched for.
  local have = fs.read(out)
  if have and hash.sha256_hex(have) == p.sha256 then
    io.write("unpack " .. p.output .. "\n")
    return unpacked(p, out)
  end
  local ok, merr = fs.makedirs(fs.dirname(out))
  if not ok then
    return false, "make: cannot create " .. fs.dirname(out) .. ": " ..
    (merr or "unknown error")
  end
  io.write("fetch " .. p.url .. "\n")
  -- allow_private: the SSRF guard exists because an ATTACKER-CONTROLLED
  -- url can aim a fetch at an internal service. A pin's url is none of
  -- those things — it is a literal in a committed file that the
  -- extractor has already refused to let compute itself, and the bytes
  -- it returns are digest-verified before they land. Meanwhile an
  -- internal artifact mirror on a private address is exactly what
  -- pinning is for, and the guard would block it. The threat the guard
  -- addresses is absent here by construction; the case it breaks is
  -- real.
  local result = cfetch.fetch(p.url,
    {allow_private = true, max_attempts = ATTEMPTS, maxresponse = MAX_BODY})
  if not result.ok then
    return false, "make: " .. p.source .. ": " .. p.url .. ": " ..
    (result.error or ("status " .. tostring(result.status)))
  end
  -- `Result.ok` is transport-level: a 404 error page arrives "ok", so
  -- the status is checked before hashing. Without that, the commonest
  -- failure -- a typo'd version in the url -- reports itself as a
  -- sha256 mismatch against the hash of an HTML page, pointing at the
  -- digest, which is fine, instead of at the url.
  if result.status < 200 or result.status >= 300 then
    return false, "make: " .. p.source .. ": " .. p.url .. ": HTTP " ..
    tostring(result.status)
  end
  local got = hash.sha256_hex(result.body)
  if got ~= p.sha256 then
    return false, "make: " .. p.source .. ": sha256 mismatch for " .. p.url ..
    "\n  want " .. p.sha256 .. "\n  got  " .. got
  end
  local wok, werr = fs.write(out, result.body)
  if not wok then
    return false, "make: cannot write " .. out .. ": " ..
    (werr or "unknown error")
  end
  return unpacked(p, out)
end

--- Every pin in the project, resolved.
---
--- The pin unit's scope is one file — itself. It reads nothing else,
--- which is why a pin can be resolved from a checkout with no build in
--- it and why `fetch` needs no compiled tree.
--- @param files {File} The selected pin files
--- @return {Pin}|nil The resolved pins
--- @return string The first error
local function resolve(files: {File}): {Pin} | nil, string
  local pins: {Pin} = {}
  for _, f in ipairs(files) do
    local p, err = pin.read(f.path)
    if not p then
      return nil, err or ("make: " .. f.path .. ": not a pin")
    end
    pins[#pins + 1] = p as Pin -- cast: record union after the guard
  end
  return pins
end

--- Use the host's CA store unless the caller said otherwise.
---
--- Cosmopolitan ships a deliberately narrow set of roots, too narrow
--- for the hosts real pins live on (github.com among them), so a
--- default `--make fetch` failed certificate verification on every
--- pin. TLS is transport here, not the trust root — the digest is —
--- so widening to the system store costs nothing the pin was relying
--- on. `overwrite = false`: an operator who set it to 0 deliberately
--- keeps that.
local function use_system_certs()
  env.set("SSL_USE_SYSTEM_CERTS", "1", false)
end

--- Run `fetch` over the selected pins.
--- @param proj Project The scanned project
--- @param paths {string} Selection paths (empty for every pin)
--- @return integer Exit code
local function run(proj: Project, paths: {string}): integer
  local candidates = project.of_kind(proj, {"pin"})
  local picked, serr = selection.files(candidates, paths, proj.root)
  if not picked then
    io.stderr:write((serr or "make: no such selection") .. "\n")
    io.write("fetch: FAIL (bad selection)\n")
    return 1
  end
  local files = picked as {File} -- cast: record union after the guard

  local pins, rerr = resolve(files)
  if not pins then
    io.stderr:write((rerr or "make: cannot read the pins") .. "\n")
    io.write("fetch: FAIL (bad pin)\n")
    return 1
  end

  use_system_certs()
  local failed = 0
  for _, p in ipairs(pins as {Pin}) do -- cast: record union after the guard
    local ok, err = one(p)
    if not ok then
      io.stderr:write((err or "make: fetch failed") .. "\n")
      failed = failed + 1
    end
  end
  local n = #(pins as {Pin}) -- cast: record union after the guard
  if failed > 0 then
    io.write(string.format("fetch: FAIL (%d of %d pins)\n", failed, n))
    return 1
  end
  io.write(string.format("fetch: PASS (%d %s)\n", n,
      n == 1 and "pin" or "pins"))
  return 0
end

local record FetchModule
  satisfied: function(p: Pin): boolean
  resolve: function(files: {File}): {Pin} | nil, string
  run: function(proj: Project, paths: {string}): integer
end

local M: FetchModule = {
  satisfied = satisfied,
  resolve = resolve,
  run = run,
}

return M
