--- A count with its noun, for the driver's messages: "1 asset", "2 assets".
--- ci/ runs on the pinned driver release, which cannot require the tree's
--- own build.plural.

local record Plural
end

--- `count` and `singular`, the noun made plural (by an `s`, or by
--- `several` when the plural is not that) unless `count` is 1.
function Plural.count(count: integer, singular: string, several?: string): string
  -- TODO: once ci/cosmic-driver.pin names a release whose cosmic.string has
  -- `counted`, return that.
  return count .. " " .. (count == 1 and singular or several or singular .. "s")
end

--- `singular`, or its plural, as `count` asks, for a line that prints the
--- number itself (a format's `%d`).
function Plural.noun(count: integer, singular: string, several?: string): string
  return count == 1 and singular or several or singular .. "s"
end

return Plural
