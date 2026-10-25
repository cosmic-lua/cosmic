--- A cache, with a function assigned to a path of two dots: the fork's Teal reads it, the new grammar spells it otherwise.
local record Kv
  record Lru
    size: integer
  end
end

function Kv.Lru.get(self: Kv.Lru): integer
  return self.size
end

return Kv
