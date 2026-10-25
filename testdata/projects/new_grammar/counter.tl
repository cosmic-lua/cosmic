--- A count of the words seen, as a class.
local class Counter
  --- What the words are counted for.
  label: string
  --- How many have been counted.
  mut count: integer
  --- The words, in the order they came.
  seen: mut {string}

  --- Counts `word` and answers how many have been counted.
  function add(self, word: string): integer
    self.count = self.count + 1
    table.insert(self.seen, word)
    return self.count
  end

  --- The words counted, joined by commas.
  function line(self): string
    return table.concat(self.seen, ",")
  end
end

local record Counters
  new: function(label: string): Counter
end

local function new(label: string): Counter
  return { label = label, count = 0, seen = {} }
end

local counters: Counters = { new = new }
return counters
