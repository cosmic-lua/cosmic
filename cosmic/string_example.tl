--- Worked examples for `cosmic.string`, shown by `cosmic docs` under the
--- symbol each one demonstrates and run by `cosmic test` like any
--- other test -- see doc/design.md's `examples` table.

local String = require("cosmic.string")

local Example = {}

--- Fields of a record, empty ones kept; the separator is plain text.
function Example.split()
  local fields = String.split("name.tl..3", ".")
  print(#fields)
  assert(#fields == 4 and fields[3] == "" and fields[4] == "3")
end

--- Numbered lines, blank ones included.
function Example.lines()
  local n = 0
  for line in String.lines("first\n\nthird") do
    n = n + 1
    print(n, line)
  end
  assert(n == 3)
end

--- A value read from a file, without its surrounding whitespace.
function Example.trim()
  local value = String.trim("  v1.2.3\n")
  print(value)
  assert(value == "v1.2.3")
end

--- The Teal sources among some paths.
function Example.ends_with()
  local found: {string} = {}
  for _, path in ipairs({ "a.tl", "b.lua", "c.d.tl" }) do
    if String.ends_with(path, ".tl") then found[#found + 1] = path end
  end
  print(table.concat(found, " "))
  assert(#found == 2)
end

--- Flags among arguments.
function Example.starts_with()
  assert(String.starts_with("--check", "--"))
  assert(not String.starts_with("-", "--"))
end

return Example
