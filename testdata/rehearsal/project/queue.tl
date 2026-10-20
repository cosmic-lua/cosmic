--- A queue of words, in the Teal both checkers read.
local record Queue
  --- The words waiting, first in line first.
  items: {string}
end

--- A queue with nothing in it.
function Queue.new(): Queue
  return { items = {} }
end

--- Puts `word` at the end of the line.
function Queue.push(self: Queue, word: string)
  table.insert(self.items, word)
end

--- Takes the word at the front, nil when none waits.
function Queue.pop(self: Queue): string | nil
  return table.remove(self.items, 1)
end

--- Puts the words waiting in order, the smallest first.
function Queue.sort(self: Queue)
  table.sort(self.items, function(a: string, b: string): boolean
    return a < b
  end)
end

--- The words waiting, joined by commas.
function Queue.line(self: Queue): string
  return table.concat(self.items, ",")
end

-- TODO: call these as methods (`queue:push(word)`) in the tests and the report, once the new checker types a value of a record
-- that another module declares (the TODO of `declaration_value` in lang/check.tl): a call of a method on such a value is
-- refused today (`field_unknown`) with no change of the program that fixes it.
return Queue
