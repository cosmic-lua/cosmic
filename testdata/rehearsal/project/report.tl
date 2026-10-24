--- A report of a queue as JSON, through the standard library of cosmic.
local Json = require("cosmic.json")
local Queue = require("queue")

local record Report
  --- What a report says.
  record Summary
    count: integer
    words: string
  end
end

--- The JSON text that says how many words wait and which.
function Report.of(queue: Queue): string | nil, string
  local summary: Report.Summary = { count = #queue.items, words = queue:line() }
  local text, why = Json.encode_any(summary)
  if text == nil then
    return nil, why
  end
  return text, ""
end

return Report
