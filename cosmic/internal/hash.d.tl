-- Streaming digests at the Lua boundary, as the core provides them.

local record hash
  record Hasher
    userdata

    update: function(Hasher, data: string)
    -- The raw digest; the hasher is finished after this and every
    -- further call to it throws.
    digest: function(Hasher): string | nil, string
  end

  -- nil, error when no algorithm has that name.
  hasher: function(algorithm: string): Hasher | nil, string
end

return hash
