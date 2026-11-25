--- A fake's main for [`cosmic.fake`]'s test of `Fake.build(dir, main)`:
--- it prints its arguments joined by spaces and ends with status 3.

local function main(argv: {string}): integer
  print(table.concat(argv, " "))
  return 3
end

return main
