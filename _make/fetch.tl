--- The `fetch` verb: resolve `*.pin.tl` into bytes under `o/`.
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
local fs = require("cosmic.fs")
local hash = require("cosmic.hash")
local pin = require("_make.pin")
local project = require("_make.project")
local types = require("_make.types")

local type File = types.File
local type Pin = pin.Pin
local type Project = types.Project

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

--- Is this pin already satisfied? A pin is content-addressed, so the
--- question is about bytes, never about mtimes: an output that hashes
--- correctly is the output, whenever it was written.
--- @param p Pin The resolved pin
--- @return boolean True when the output is present and verified
local function satisfied(p: Pin): boolean
  local have = fs.read(landing(p))
  if not have then
    return false
  end
  return hash.sha256_hex(have) == p.sha256
end

--- Fetch one pin, verifying before it lands.
--- @param p Pin The resolved pin
--- @return boolean, string Success, or false plus the reason
local function one(p: Pin): boolean, string
  if satisfied(p) then
    return true
  end
  local out = landing(p)
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
  local result = cfetch.fetch(p.url, {allow_private = true})
  if not result.ok then
    return false, "make: " .. p.source .. ": " .. p.url .. ": " ..
    (result.error or ("status " .. tostring(result.status)))
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
    pins[#pins + 1] = p as Pin -- cast: record union after the guard
  end
  return pins
end

--- Run `fetch` over the selected pins.
--- @param proj Project The scanned project
--- @param paths {string} Selection paths (empty for every pin)
--- @return integer Exit code
local function run(proj: Project, paths: {string}): integer
  local candidates = project.of_kind(proj, {"pin"})
  local picked, serr = project.select(candidates, paths, proj.root)
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
