local record Inner
  y: integer
end
local record Middle
  inner: Inner | nil
end
local record Outer
  mid: Middle
end
local o: Outer = {mid = {inner = {y = 1}}}

if o.mid.inner then
  print(o.mid.inner.y)
end
