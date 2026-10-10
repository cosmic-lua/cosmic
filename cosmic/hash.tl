--- Content hashes and message authentication codes (HMAC), returned as
--- raw bytes; [`Codec.hex`] spells one for a person.
---
--- - [`Hash.digest`] and [`Hash.hmac`] take the whole message at once, for
---   any [`Hash.Algorithm`].
--- - [`Hash.hasher`] and [`Hash.hmac_hasher`] take it in chunks, for a file
---   or a stream; [`cosmic.stream`]'s `hashing` feeds one as data passes.
--- - [`Hash.sha256`] and [`Hash.hex_sha256`] are the common case in one
---   call.
--- - [`Hash.siphash`] is SipHash, a keyed hash for short inputs: a hash
---   table's, or a cache key a format defines by it.
---
---     local hex = Hash.hex_sha256("cosmic")
---     local code = Hash.hmac("sha256", "key", "message")
---
--- MD5 and SHA-1 are here for checksums and formats that name them, not
--- for anything an attacker can choose the input of.

local Codec = require("cosmic.codec")

-- The raw module behind every function here lives under the reserved
-- `cosmic.internal.` namespace -- see cosmic/store.tl for why this
-- indirection exists.
local type raw_hash = require("cosmic.internal.hash")

local extra: any = select(2, ...)
local raw: raw_hash
if type(extra) == "table" then
  raw = extra as raw_hash
else
  raw = require("cosmic.internal.hash")
end

local record Hash
  --- The digest algorithms, by exactly these lower-case names: `md5`,
  --- `sha1`, the SHA-2 family (`sha224`, `sha256`, `sha384`, `sha512`)
  --- and the SHA-3 family with a hyphen (`sha3-224` through `sha3-512`).
  --- Another spelling (`SHA256`, `sha-256`) is not a name: the functions
  --- taking an algorithm raise on it.
  enum Algorithm
    "md5"
    "sha1"
    "sha224"
    "sha256"
    "sha384"
    "sha512"
    "sha3-224"
    "sha3-256"
    "sha3-384"
    "sha3-512"
  end

  --- An incremental digest, or HMAC from [`Hash.hmac_hasher`]: feed it
  --- chunks with `update`, then read the raw digest (or code) with
  --- `digest`, which answers `digest, ""` (or `nil, error`) and finishes
  --- it. Calling either method again afterward throws. A hasher is
  --- closeable: `local h <close> = ...` abandons an unfinished one at the
  --- end of the scope.
  type Hasher = raw_hash.Hasher

  --- The variant [`Hash.siphash`] computes, SipHash-c-d; each field is
  --- its default when absent.
  record SipHashOptions
    --- Rounds per 8-byte word of the message (`c`): 1 to 64, 2 by
    --- default.
    compression: integer
    --- Rounds once the message is in (`d`): 1 to 64, 4 by default.
    finalization: integer
    --- The tag's length in bytes: 8 (SipHash-64, the default) or 16
    --- (SipHash-128).
    size: integer
  end
end

--- The raw digest of some bytes under an algorithm: 16 bytes for MD5,
--- 20 for SHA-1, and 28 to 64 for the SHA-2 and SHA-3 sizes.
function Hash.digest(algorithm: Hash.Algorithm, data: string): string
  return raw.digest(algorithm, data)
end

--- The raw HMAC of some bytes under a key, over an algorithm. The code
--- is as long as the algorithm's digest.
function Hash.hmac(algorithm: Hash.Algorithm, key: string, data: string): string
  return raw.hmac(algorithm, key, data)
end

--- The 32 raw bytes of a SHA-256 digest.
function Hash.sha256(data: string): string
  return raw.digest("sha256", data)
end

--- The hexadecimal SHA-256 of some bytes, as `sha256sum` prints it,
--- which is the form the build writes into keys.
function Hash.hex_sha256(data: string): string
  return Codec.hex(raw.digest("sha256", data))
end

--- An incremental hasher over an algorithm, for data that arrives in
--- chunks rather than all at once; its raw digest equals
--- `Hash.digest(algorithm, ...)` over the whole of what was fed to it.
--- Answers `hasher, ""`, or `nil, error` when the digest cannot start.
--- Raises on an unknown algorithm, as `digest` and `hmac` do.
function Hash.hasher(algorithm: Hash.Algorithm): Hash.Hasher | nil, string
  return raw.hasher(algorithm)
end

--- An incremental HMAC (RFC 2104) under `key` over an algorithm, for a
--- message that arrives in chunks; its raw code equals
--- `Hash.hmac(algorithm, key, ...)` over the whole of what was fed to
--- it, for a key of any length. It is a [`Hash.Hasher`]: `update` and
--- `digest` as a digest's, `digest` answering the code and finishing it,
--- a `<close>` abandoning an unfinished one. Answers `mac, ""`, or
--- `nil, error` when the digest cannot start. Raises on an unknown
--- algorithm.
function Hash.hmac_hasher(algorithm: Hash.Algorithm, key: string): Hash.Hasher | nil, string
  return raw.hmac_hasher(algorithm, key)
end

--- The raw SipHash tag of `data` under a 16-byte `key`: SipHash-2-4's
--- 8 bytes by default, another variant through `options`
--- ([`Hash.SipHashOptions`]), as the reference implementation computes
--- it. Raises on a key of another length, or options out of range.
---
---     local tag = Hash.siphash(string.rep("k", 16), "message")
---     -- zig's build cache keys its manifests by SipHash128-1-3.
---     local wide = Hash.siphash(string.rep("k", 16), "message",
---       { compression = 1, finalization = 3, size = 16 })
function Hash.siphash(key: string, data: string, options?: Hash.SipHashOptions): string
  local o = options or {}
  return raw.siphash(key, data, o.compression, o.finalization, o.size)
end

return Hash
