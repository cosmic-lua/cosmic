local record RowsA
  x: integer
end
local record RowsB
  x: integer
end
local a: RowsA = {x = 1}
local b: RowsB = a
print(b)
