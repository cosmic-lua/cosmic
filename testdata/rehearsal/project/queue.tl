--- A queue of words, in the Teal both checkers read.
local record Queue
  --- The words waiting, first in line first.
  items: {string}
  --- Puts `word` at the end of the line.
  push: function(self: Queue, word: string)
  --- Takes the word at the front, nil when none waits.
  pop: function(self: Queue): string | nil
  --- Puts the words waiting in order, the smallest first.
  sort: function(self: Queue)
  --- The words waiting, joined by commas.
  line: function(self: Queue): string
end

local function push(self: Queue, word: string)
  table.insert(self.items, word)
end

local function pop(self: Queue): string | nil
  return table.remove(self.items, 1)
end

local function sort(self: Queue)
  table.sort(self.items, function(a: string, b: string): boolean
    return a < b
  end)
end

local function line(self: Queue): string
  return table.concat(self.items, ",")
end

--- A queue with nothing in it. Each function is a field of the queue, so that `queue:push(word)` finds it in the value
--- (a record's value has no metatable, and a function the module alone holds is not reached through the value).
function Queue.new(): Queue
  return { items = {}, push = push, pop = pop, sort = sort, line = line }
end

return Queue
