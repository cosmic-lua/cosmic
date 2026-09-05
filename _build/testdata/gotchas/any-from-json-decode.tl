local json = require("cosmic.json")

local d1 = json.decode("[]")
for _, v in ipairs(d1) do
  print(v)
end

local d2 = json.decode("{}")
print(d2.x)
