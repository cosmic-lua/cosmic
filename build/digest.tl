--- SHA-256 as the build keys and lays out with it: raw, as lowercase
--- hexadecimal, and a chunk at a time, straight over the core's raw hash
--- table, which this module is handed as it loads (core/store.c's
--- `raw_modules`).
---
--- It stands in for cosmic.hash and cosmic.codec in the modules that
--- compute a verdict key and in what a test worker loads (build.test's
--- `harness`), so a key's value turns on this module and the core's C,
--- which the runtime's identity keys, and no edit to either library
--- moves the harness. Nothing here is taken through a table a test can
--- replace once it has loaded: the raw functions and build.key_parts'
--- `hex` are locals from the start.

local key_parts = require("build.key_parts")

--- The raw module the store hands this one. Boot mode falls back to
--- requiring it by name, which only boot's own preload answers.
local type raw_hash = require("cosmic.internal.hash")

local extra: any = select(2, ...)
local raw: raw_hash
if type(extra) == "table" then
  raw = extra as raw_hash
else
  raw = require("cosmic.internal.hash")
end

local digest_of, hasher_of, hex = raw.digest, raw.hasher, key_parts.hex

local record digest
  --- An incremental SHA-256: `update` with each chunk, then `digest`
  --- for the 32 raw bytes, as cosmic.hash's [`Hasher`] is.
  type Hasher = raw_hash.Hasher
end

--- The 32 raw bytes of the SHA-256 of `data`.
function digest.sha256(data: string): string
  return digest_of("sha256", data)
end

--- The SHA-256 of `data` in lowercase hexadecimal, as `sha256sum`
--- prints it: the form the build writes into keys.
function digest.hex_sha256(data: string): string
  return hex(digest_of("sha256", data))
end

--- An incremental SHA-256, whose digest equals `sha256` over the whole
--- of what was fed to it; or nil and why when it cannot start.
function digest.sha256_hasher(): digest.Hasher | nil, string
  return hasher_of("sha256")
end

return digest
