--- A count with its noun, as the verbs' summary lines write one:
--- "1 use", "2 uses", "0 uses".

local record plural
end

--- `count` and `singular`, the noun made plural (by an `s`, or by
--- `several` when the plural is not that) unless `count` is 1.
function plural.count(count: integer, singular: string, several?: string): string
  return tostring(count) .. " " .. (if count == 1 then singular else several or singular .. "s" end)
end

--- `singular`, or its plural, as `count` asks, for a line that prints the
--- number itself (a format's `%d`).
function plural.noun(count: integer, singular: string, several?: string): string
  -- TODO: once cosmic.string has a helper for the noun without its count,
  -- delegate to it as `count` does, so the plural rule is written once.
  return if count == 1 then singular else several or singular .. "s" end
end

return plural
