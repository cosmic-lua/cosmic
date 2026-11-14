--- How far a mistyped word is from the one meant: the edit distance and the reach within which two words are
--- taken for one, shared by the names [`cosmic.flags`] suggests and the words [`cosmic.doc`] searches again for.

local record Distance
end

--- How many edits a mistyping of `word` may be from what was meant, by its length in characters: none under 3,
--- then 1, 2 from 8 and 3 from 12. A short word is near too many others for one edit to say which was meant.
function Distance.reach(word: string): integer
  local length = utf8.len(word) or #word
  return if length < 3 then 0 elseif length < 8 then 1 elseif length < 12 then 2 else 3 end
end

--- The edit distance between `a` and `b`, or `reach + 1` when it is past
--- `reach`: insertions, deletions, replacements and swaps of two adjacent
--- bytes, each counting one (optimal string alignment).
function Distance.between(a: string, b: string, reach: integer): integer
  if math.abs(#a - #b) > reach then
    return reach + 1
  end
  -- A row holds the distances from a prefix of `a` to each prefix of
  -- `b`, that of b's first `j` bytes at slot `j + 1`.
  local function cell(cells: {integer}, j: integer): integer
    return assert(cells[j + 1])
  end
  local before: {integer} = {}
  local row: mut {integer} = {}
  for j = 0, #b do row[#row + 1] = j end
  for i = 1, #a do
    local next_row: mut {integer} = { i }
    local least = i
    for j = 1, #b do
      local cost = if a:byte(i) == b:byte(j) then 0 else 1 end
      local best = math.min(cell(row, j) + 1, cell(next_row, j - 1) + 1, cell(row, j - 1) + cost)
      if i > 1 and j > 1 and a:byte(i) == b:byte(j - 1) and a:byte(i - 1) == b:byte(j) then
        best = math.min(best, cell(before, j - 2) + 1)
      end
      next_row[#next_row + 1] = best
      if best < least then least = best end
    end
    if least > reach then
      return reach + 1
    end
    before, row = row, next_row
  end
  return math.min(cell(row, #b), reach + 1)
end

return Distance
