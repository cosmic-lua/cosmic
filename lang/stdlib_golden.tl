--- Writes the golden of the standard library's declarations, [`testdata/stdlib/globals.txt`]: every global and library member
--- the new checker lowers [`lang/prelude.d.tl`] and [`lang/stdlib.d.tl`] to, with its type ([`Programs.dump`]), which
--- [`lang/stdlib_test.tl`] holds the declarations to. Run it from the tree's root after an edit of either file, as
--- `bin/cosmic lang/stdlib_golden.tl`, and read the diff: a type that gets wider, or a member that goes, shows there.
local Fs = require("cosmic.fs")
local Programs = require("lang.check_programs")

local function main()
  local prelude = assert(Fs.read("lang/prelude.d.tl"))
  local stdlib = assert(Fs.read("lang/stdlib.d.tl"))
  assert(Fs.mkdirs("testdata/stdlib"))
  assert(Fs.write("testdata/stdlib/globals.txt", Programs.dump(prelude, stdlib)))
  print("written to testdata/stdlib/globals.txt")
end

main()
