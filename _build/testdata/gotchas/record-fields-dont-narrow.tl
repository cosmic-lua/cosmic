local record Inner
  x: integer
end
local record Outer
  sub: Inner | nil
end
local o: Outer = {sub = {x = 1}}

if o.sub then
  print(o.sub.x)
end
