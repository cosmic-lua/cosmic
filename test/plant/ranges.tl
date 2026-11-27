--- Merges ranges of integers, a planted bug for the agent evals: [`Ranges.merge`] answers the ranges of its input with
--- each overlapping or touching pair joined (`{1, 3}` and `{4, 6}` touch: they cover 1 to 6 with no gap), sorted by start.
local record Ranges
  record Range
    first: integer
    mut last: integer
  end
end

--- The ranges of `list` with those that overlap or touch joined, sorted by `first`. A new list: `list` is not changed.
function Ranges.merge(list: {Ranges.Range}): {Ranges.Range}
  local sorted: mut {Ranges.Range} = {}
  for _, r in ipairs(list) do sorted[#sorted + 1] = { first = r.first, last = r.last } end
  table.sort(sorted, function(a: Ranges.Range, b: Ranges.Range): boolean
    return a.first < b.first
  end)
  local out: mut {Ranges.Range} = {}
  for _, r in ipairs(sorted) do
    local top = out[#out]
    if top ~= nil and r.first < top.last then
      if r.last > top.last then top.last = r.last end
    else
      out[#out + 1] = r
    end
  end
  return out
end

return Ranges
