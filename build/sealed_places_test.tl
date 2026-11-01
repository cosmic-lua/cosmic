--- A worker's sealed database holds the `places` of the modules its test's
--- import closure holds (build/test_key.tl's `sealed_fill`, from the
--- closure store's `closed`), which `cosmic lsp` answers a go to
--- definition of a standard-library symbol from
--- ([`build.lsp.source`]'s `carried_places`), and none of a module beyond
--- the closure (build/sealed_worker_test.tl).
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local Test = require("cosmic.test")

local function test_a_sealed_database_holds_the_places_of_the_closure_s_modules()
  local relaunch = Proc.relaunch()
  if relaunch == nil or relaunch.argv[2] ~= "--database" then
    Test.skip("this worker does not run on a sealed database")
  end
  -- A module of the closure, by value: this file's own require.
  assert(Fs.exists(".") == true and Store.bytecode("cosmic.fs") ~= nil, "cosmic.fs is in the closure")
  local databases = Store.databases()
  local held = assert(databases[#databases])
  local placed = assert(Sqlite.text_rows(held,
    "SELECT symbol, kind FROM places WHERE module = 'cosmic.fs' AND symbol = 'Fs.read'"))
  assert(#placed == 1 and placed[1]:text(2) == "function", "the place of Fs.read is carried")
  local beyond = assert(Sqlite.text_rows(held, "SELECT count(*) FROM places WHERE module = 'cosmic.zip'"))
  assert(assert(beyond[1]):text(1) == "0", "the places of a module beyond the closure are not")
end
