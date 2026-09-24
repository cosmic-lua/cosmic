--- Content hashes and message authentication, over the vendored
--- mbedtls.

local Codec = require("cosmic.codec")
local sys = require("cosmic.sys")

--- The raw module behind the streaming hasher lives under the reserved
--- `cosmic.internal.` namespace -- see cosmic/sqlite.tl for why this
--- indirection exists.
local type raw_hash = require("cosmic.internal.hash")

local extra: any = select(2, ...)
local raw: raw_hash
if type(extra) == "table" then
  raw = extra as raw_hash
else
  raw = require("cosmic.internal.hash")
end

local record Hash
  --- The digest algorithms the core knows, by the names the syscall
  --- table takes.
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

  --- An incremental digest: feed it chunks with `update`, then read the
  --- raw digest with `digest`, which answers `digest, ""` (or
  --- `nil, error`) and finishes it. Calling either method again
  --- afterward throws. A hasher is closeable: `local h <close> = ...`
  --- abandons an unfinished digest at the end of the scope.
  type Hasher = raw_hash.Hasher
end

--- The raw digest of some bytes under an algorithm: 16 bytes for MD5,
--- 20 for SHA-1, and 28 to 64 for the SHA-2 and SHA-3 sizes.
function Hash.digest(algorithm: Hash.Algorithm, data: string): string
  return sys.digest(algorithm, data)
end

--- The raw HMAC of some bytes under a key, over an algorithm. The code
--- is as long as the algorithm's digest.
function Hash.hmac(algorithm: Hash.Algorithm, key: string, data: string): string
  return sys.hmac(algorithm, key, data)
end

--- The 32 raw bytes of a SHA-256 digest.
function Hash.sha256(data: string): string
  return sys.digest("sha256", data)
end

--- The hexadecimal SHA-256 of some bytes, as `sha256sum` prints it,
--- which is the form the build writes into keys.
function Hash.hex_sha256(data: string): string
  return Codec.hex(sys.digest("sha256", data))
end

--- An incremental hasher over an algorithm, for data that arrives in
--- chunks rather than all at once; its raw digest equals
--- `Hash.digest(algorithm, ...)` over the whole of what was fed to it.
--- Answers `hasher, ""`, or `nil, error` when the digest cannot start.
--- Raises on an unknown algorithm, as `digest` and `hmac` do.
function Hash.hasher(algorithm: Hash.Algorithm): Hash.Hasher | nil, string
  return raw.hasher(algorithm)
end

--- The sum of the unsigned bytes of `data` from `first` through `last`
--- (1-based and inclusive; the whole string by default), as a tar
--- header checksum adds them up. Raises when `first` is below 1, `last`
--- is past the end, or `first` is more than one past `last`; an empty
--- range sums to 0.
-- TODO: a tar header checksum is no hash, and `cosmic.tar` is this
-- function's one caller: move it there once a module can be handed
-- another module's `cosmic.internal.` table, as this one is handed its
-- own (the C sum is what keeps a header's 512 bytes off the Lua loop).
function Hash.byte_sum(data: string, first?: integer, last?: integer): integer
  return raw.byte_sum(data, first, last)
end

return Hash
