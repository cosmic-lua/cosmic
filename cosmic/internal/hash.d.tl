-- Digests, HMACs and streaming digests at the Lua boundary, as the
-- core provides them. Every fallible function answers `value, ""` on
-- success and `nil, error` on failure.

local record hash
  record Hasher
    userdata

    -- Raises on a finished hasher.
    update: function(Hasher, data: string)
    -- The raw digest; the hasher is finished after this and every
    -- further call to it throws.
    digest: function(Hasher): string | nil, string
    -- `local h <close> = ...`: an unfinished digest is abandoned and
    -- the hasher finished.
    metamethod __close: function(Hasher, any)
  end

  -- The raw digest of data, 16 to 64 bytes by algorithm (md5, sha1,
  -- sha224, sha256, sha384, sha512, sha3-224, sha3-256, sha3-384,
  -- sha3-512). Raises when no algorithm has that name.
  digest: function(algorithm: string, data: string): string
  -- The raw HMAC of data under key, as long as the algorithm's digest.
  -- Raises when no algorithm has that name.
  hmac: function(algorithm: string, key: string, data: string): string
  -- Raises when no algorithm has that name; nil, error when the
  -- digest cannot start.
  hasher: function(algorithm: string): Hasher | nil, string
  -- The sum of the unsigned bytes of data[first..last] (1-based,
  -- inclusive; the whole string by default). Raises when first < 1,
  -- last > #data, or first > last + 1; an empty range sums to 0.
  byte_sum: function(data: string, first?: integer, last?: integer): integer
end

return hash
