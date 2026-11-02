--- Reads of an array that must be there. `xs[i]` is `T?` because Lua answers
--- nil past either end, and `xs[i] or 0` turns that nil into a wrong value
--- that nothing reports. Where `for i = 1, #xs do` cannot say the index is
--- a key (an index that is computed, a loop that calls a function or
--- changes the array), [`Array.at`] reads the element or raises with the
--- index and the length in the message.
---
---     local third = Array.at({ 10, 20, 30 }, 3) -- 30

local record Array
end

--- The element of `xs` at `i`, counted from 1. For an index the caller has
--- already bounded (a computed offset, a length it read first): the read
--- is an element, not an optional, and a miss fails where it is made.
--- It raises, blaming its caller, when `i` is 0, negative or past
--- `#xs`, which is a bug in the caller (its bound was wrong), not a
--- condition for it to handle: a function that must answer a missing index
--- returns `xs[i]` itself, a `T?`, or its own `nil, why`.
--- @param xs {T} The array to read
--- @param i integer The position, 1 to `#xs`
--- @return T The element
function Array.at<T>(xs: {T}, i: integer): T
  local element = xs[i]
  if element == nil then
    if #xs == 0 then
      error(("array: at(%d) reads an empty array"):format(i), 2)
    end
    error(("array: at(%d) is outside the array of %d (1 to %d)"):format(i, #xs, #xs), 2)
  end
  return element
end

return Array
