local function f(): string
  return "a", "b"
end
print(f())

local function one(): string
  return "a"
end
local x, y = one()
print(x, y)
