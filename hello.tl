--- The smallest thing a cosmic binary can build and run.

local function hello(_argv: {integer:string}): integer
  print("hello from the database")
  return 0
end

return hello
