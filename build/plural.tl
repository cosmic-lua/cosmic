--- A count with its noun, as the verbs' summary lines write one:
--- "1 use", "2 uses", "0 uses".

local String = require("cosmic.string")

local record plural
end

--- `count` and `singular`, the noun made plural (by an `s`, or by
--- `several` when the plural is not that) unless `count` is 1.
function plural.count(count: integer, singular: string, several?: string): string
  return String.counted(count, singular, several)
end

--- `singular`, or its plural, as `count` asks, for a line that prints the
--- number itself (a format's `%d`).
function plural.noun(count: integer, singular: string, several?: string): string
  return count == 1 and singular or several or singular .. "s"
end

return plural
