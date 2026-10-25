--- A queue of words, in the new grammar.
local record Queue
  --- The words waiting, first in line first. The queue changes them in place.
  items: mut {string}
  --- How many wait, which changes with every push and pop.
  mut length: integer
  --- Puts `word` at the end of the line.
  push: function(self: Queue, word: string)
  --- Takes the word at the front, nil when none waits.
  pop: function(self: Queue): string?
end

local function push(self: Queue, word: string)
  table.insert(self.items, word)
  self.length = self.length + 1
end

local function pop(self: Queue): string?
  if self.length == 0 then
    return nil
  end
  self.length = self.length - 1
  return table.remove(self.items, 1)
end

--- A queue with nothing in it. Each function is a field of the queue, so that `queue:push(word)` finds it in the value
--- (a record's value has no metatable).
function Queue.new(): Queue
  return { items = {}, length = 0, push = push, pop = pop }
end

return Queue
