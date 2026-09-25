--- Worked examples for `cosmic.errors`, shown by `cosmic docs` under
--- the symbol each one demonstrates and run by `cosmic test` like any
--- other test -- see doc/design.md's `examples` table.

local Errors = require("cosmic.errors")

local Example = {}

--- The call stack as text, under the message, for a failure a person
--- will read.
function Example.trace()
  local text = Errors.trace("could not load the config")
  print(text)
  assert(text:find("could not load the config", 1, true) == 1, text)
  assert(text:find("traceback", 1, true) ~= nil, text)
end

--- What cosmic prints beneath an error nothing caught: the doc comment
--- of the function the message came from, found in the error catalog by
--- the words the two share.
function Example.guidance()
  local text = Errors.guidance("coverage collection is already active")
  print(text)
  assert(text ~= nil and text:find("Coverage.start (cosmic/coverage.tl:", 1, true) ~= nil,
    tostring(text))
  assert(Errors.guidance("nothing whatever like any message") == nil)
end

return Example
