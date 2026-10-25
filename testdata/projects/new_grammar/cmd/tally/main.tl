local Fs = require("cosmic.fs")
local Counter = require("counter")
local Queue = require("queue")

return function(argv: {string}): integer
  local queue = Queue.new()
  for _, word in ipairs(argv) do
    queue:push(word)
  end
  local counter = Counter.new("words")
  while true do
    local word = queue:pop()
    if word == nil then
      break
    end
    counter:add(word)
  end
  local _, _ = Fs.put(Fs.stdout, counter:line() .. "\n")
  return counter.count
end
