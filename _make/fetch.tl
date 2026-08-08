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
local patch = require("_make.patch")
local pin = require("_make.pin")
local project = require("_make.project")
local records = require("_tool.records")
local selection = require("_make.select")
local types = require("_make.types")

local type Edit = patch.Edit
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
--- characters in member names (`cosmic.fs.is_unsafe_entry_name`,
--- `fs.is_unsafe_entry_name`) — archive members are
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
  for line in listed:gmatch("([^\n]+)") do
    if not fs.is_present(fs.join(dir, line)) then
      return false
    end
  end
  return true
end

--- The pin's carried patch, read, or nil when it carries none.
---
--- A patch is only admitted on a pin that unpacks: a formatless pin's
--- single output IS the content-addressed file, so editing it would
--- fail its own digest check on every later fetch, forever. The
--- archive/products split is what makes patching sound — the archive
--- stays pristine and verifiable, and the products are re-derivable
--- from it at any time.
--- @param p Pin The resolved pin
--- @return {Edit}|nil The edits, when the pin carries a readable patch
--- @return string The error when the patch is unreadable or misplaced
local function patch_of(p: Pin): {Edit} | nil, string
  local pp = patch.of_pin(p.source)
  if not pp then
    return nil
  end
  if not p.format then
    return nil, "make: " .. pp .. ": a patch rides an archive pin only — " ..
    "editing a bare pinned file would fail its own digest check forever"
  end
  return patch.read(pp)
end

--- Unpack a pin that declares a format, beside the archive.
---
--- Only after the digest matched: an archive is a program for a
--- decompressor, and running one on unverified bytes is what pinning
--- exists to prevent. A carried patch applies last, onto the pristine
--- products this unpack just produced.
--- @param p Pin The resolved pin
--- @param archive string The verified archive's path
--- @return boolean, string Success, or false plus the reason
local function unpacked(p: Pin, archive: string): boolean, string
  local edits, perr = patch_of(p)
  if perr then
    return false, perr
  end
  if not p.format then
    return true
  end
  -- Clear any previous run's manifest first, so a re-unpack that fails
  -- cannot leave the old claim standing over a tree it did not produce.
  local _ok, _err = fs.remove_all(manifest_of(archive))
  local produced, err = extract.unpack(archive, fs.dirname(archive), p.format,
    p.strip_components)
  if not produced then
    return false, err
  end
  local wok, werr = fs.write(manifest_of(archive),
    table.concat(produced, "\n") .. "\n")
  if not wok then
    return false, "make: cannot write " .. manifest_of(archive) .. ": " ..
    (werr or "unknown error")
  end
  if edits then
    return patch.apply(fs.dirname(archive), edits)
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
  -- A patch is part of the pin's contract: products missing its edits
  -- are as unsatisfied as products missing outright, and the repair is
  -- the same — re-unpack pristine, then apply. An unreadable or
  -- misplaced patch also lands here, so the repair path reports it.
  local edits, perr = patch_of(p)
  if perr then
    return false
  end
  if edits and not patch.applied(fs.dirname(out), edits) then
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
  local ok, merr = fs.make_dirs(fs.dirname(out))
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
  -- TRANSITIONAL SHAPE DISPATCH — delete at the next pin advance
  -- (alongside errno's #981 aliases). This file executes under the
  -- PINNED binary at cold start, where cosmic.fetch's record still
  -- says fetch returns the old Result (ok/status/body and the
  -- maxresponse option), while the tree's fetch returns
  -- Response | nil, err (and reads max_response_bytes). The casts
  -- erase the signature so both generations type-check; the options
  -- table carries both size keys so each implementation honors its
  -- own; the result dispatch reads whichever shape arrived.
  local fetch_opts: {string: any} = {
    allow_private = true, max_attempts = ATTEMPTS,
    maxresponse = MAX_BODY, max_response_bytes = MAX_BODY,
  }
  -- cast: transitional dual-shape call (pin Result vs tree Response)
  local do_fetch = cfetch.fetch as function(string, any): (any, any)
  local r1, r2 = do_fetch(p.url, fetch_opts)
  if r1 == nil then
    return false, "make: " .. p.source .. ": " .. p.url .. ": " ..
    tostring(r2 or "fetch failed")
  end
  local result = r1 as {string: any} -- cast: transitional dual-shape result
  if result.ok == false then
    -- Pinned-era Result carrying a transport failure.
    return false, "make: " .. p.source .. ": " .. p.url .. ": " ..
    tostring(result.error or "fetch failed")
  end
  local status = result.status as integer -- cast: transitional dual-shape field
  local body = result.body as string -- cast: transitional dual-shape field
  -- An HTTP error page is a response, not a transport failure, so the
  -- status is checked before hashing. Without that, the commonest
  -- failure -- a typo'd version in the url -- reports itself as a
  -- sha256 mismatch against the hash of an HTML page, pointing at the
  -- digest, which is fine, instead of at the url.
  if status < 200 or status >= 300 then
    return false, "make: " .. p.source .. ": " .. p.url .. ": HTTP " ..
    tostring(status)
  end
  local got = hash.sha256_hex(body)
  if got ~= p.sha256 then
    return false, "make: " .. p.source .. ": sha256 mismatch for " .. p.url ..
    "\n  want " .. p.sha256 .. "\n  got  " .. got
  end
  local wok, werr = fs.write(out, body)
  if not wok then
    return false, "make: cannot write " .. out .. ": " ..
    (werr or "unknown error")
  end
  return unpacked(p, out)
end

--- Repair carried patches locally, without a network.
---
--- The bootstrap: a cold tree's fetch may have run under the PINNED
--- release, which can predate a patch (or the mechanism itself). The
--- archive it landed is pristine and digest-verified, so applying the
--- patch needs no network — every graph-touching verb calls this, and
--- the first build under the tree's own code patches what the pinned
--- fetch could not. Pins without a patch cost nothing here; a missing
--- or mismatched archive is left for `fetch` to report.
--- @param proj Project The scanned project
--- @return boolean, string Success, or false plus the reason
local function repair(proj: Project): boolean, string
  for _, f in ipairs(project.of_kind(proj, {"pin"})) do
    if patch.of_pin(f.path) then
      local p, err = pin.read(f.path)
      if not p then
        return false, err or ("make: " .. f.path .. ": not a pin")
      end
      local rp = p
      if not satisfied(rp) then
        local out = landing(rp)
        local have = fs.read(out)
        if have and hash.sha256_hex(have) == rp.sha256 then
          io.write("patch " .. rp.output .. "\n")
          local uok, uerr = unpacked(rp, out)
          if not uok then
            return false, uerr
          end
        end
      end
    end
  end
  return true
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
    pins[#pins + 1] = p
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
  local _ok, _err = env.set("SSL_USE_SYSTEM_CERTS", "1", false)
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
    io.write(records.format_verdict("fetch", false, "bad selection") .. "\n")
    return records.exit_code(false)
  end
  local files = picked

  local pins, rerr = resolve(files)
  if not pins then
    io.stderr:write((rerr or "make: cannot read the pins") .. "\n")
    io.write(records.format_verdict("fetch", false, "bad pin") .. "\n")
    return records.exit_code(false)
  end

  use_system_certs()
  local failed = 0
  for _, p in ipairs(pins) do
    local ok, err = one(p)
    if not ok then
      io.stderr:write((err or "make: fetch failed") .. "\n")
      failed = failed + 1
    end
  end
  local n = #(pins)
  io.write(records.format_verdict("fetch", failed == 0,
      records.detail(failed, n, "pin")) .. "\n")
  return records.exit_code(failed == 0)
end

local record FetchModule
  satisfied: function(p: Pin): boolean
  repair: function(proj: Project): boolean, string
  resolve: function(files: {File}): {Pin} | nil, string
  run: function(proj: Project, paths: {string}): integer
end

local M: FetchModule = {
  satisfied = satisfied,
  repair = repair,
  resolve = resolve,
  run = run,
}

return M
