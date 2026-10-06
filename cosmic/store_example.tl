--- Worked examples for [`cosmic.store`], shown by `cosmic docs` under the
--- symbol each one demonstrates and run by `cosmic test` like any other
--- test -- see doc/design.md's `examples` table.

local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local Test = require("cosmic.test")

--- `store`: both read every module's rows through [`Store.databases()`].
Test.policy{ grants = { { path = "o/cosmic.db", letters = "r" } } }

local Example = {}

--- The modules a program that requires `cosmic.json` needs: the module
--- itself and, sorted, everything it loads. A module the store does not
--- hold raises, naming it.
function Example.closure()
  local names = Store.closure({ "cosmic.json" })
  print(#names, names[1])
  assert(#names >= 1)
  local ok, why = pcall(Store.closure, { "nowhere.at.all" })
  assert(not ok)
  print(why)
end

--- A program's own database: the closure of its roots, sealed. The
--- digest names the bytes, so sealing the same modules again writes the
--- same file.
function Example.seal()
  local dir = assert(Fs.mkdtemp("seal-example-"))
  local path = dir .. "/program.db"
  local digest = assert(Store.seal(Store.closure({ "cosmic.json" }), path))
  assert(Store.seal(Store.closure({ "cosmic.json" }), dir .. "/again.db") == digest)
  local db = assert(Sqlite.open(path))
  local rows = assert(Sqlite.text_rows(db, "SELECT count(*) FROM modules"))
  print(digest:sub(1, 12), rows[1][1])
  assert(db:close())
  assert(Fs.remove_tree(dir))
end

return Example
