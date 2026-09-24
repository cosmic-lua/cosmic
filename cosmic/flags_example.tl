--- Worked examples for `cosmic.flags`, shown by `cosmic docs` under the
--- symbol each one demonstrates and run by `cosmic test` like any
--- other test -- see doc/design.md's `examples` table.

local Flags = require("cosmic.flags")

local Example = {}

--- A command's options and paths: a flag, a value after "=", and a word.
function Example.parse()
  local argv = { "fix", "--check", "--jobs=2", "a.tl" }
  local got = assert(Flags.parse(argv, 2, { ["--check"] = false, ["--jobs"] = true }))
  print(got.set["--check"], got.values["--jobs"], got.words[1])
  assert(got.set["--check"] and got.values["--jobs"] == "2" and got.words[1] == "a.tl")
  local _, why = Flags.parse({ "fix", "--chek" }, 2, { ["--check"] = false })
  print(why)
  assert(why == "no such option: --chek")
end

return Example
