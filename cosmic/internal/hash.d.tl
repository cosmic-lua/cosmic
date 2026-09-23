-- Streaming digests at the Lua boundary, as the core provides them.
-- Every fallible function answers `value, ""` on success and
-- `nil, error` on failure.

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

  -- Raises when no algorithm has that name; nil, error when the
  -- digest cannot start.
  hasher: function(algorithm: string): Hasher | nil, string
  -- The sum of the unsigned bytes of data[first..last] (1-based,
  -- inclusive; the whole string by default). Raises when first < 1,
  -- last > #data, or first > last + 1; an empty range sums to 0.
  byte_sum: function(data: string, first?: integer, last?: integer): integer
end

return hash
