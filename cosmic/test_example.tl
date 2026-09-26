--- Worked examples for `cosmic.test`, shown by `cosmic docs` under the
--- symbol each one demonstrates and run by `cosmic test` like any
--- other test -- see doc/design.md's `examples` table.

local Test = require("cosmic.test")

-- What these examples read beyond their module's own sources: a
-- variable, which a test would read with `Env.get`.
Test.needs{ env = { "COSMIC_TEST_EXAMPLE" } }

local Example = {}

--- `needs` is called once, as a statement at the top of the module,
--- on the local `require("cosmic.test")` is bound to -- the call above
--- -- so the build can read it without running the module.
function Example.needs()
  local needs = assert(Test.declared())
  assert(needs.env[1] == "COSMIC_TEST_EXAMPLE")
  print(needs.env[1])
end

--- What the module's one `needs` call was handed.
function Example.declared()
  local needs = Test.declared()
  assert(needs ~= nil and needs.reads == nil and needs.processes == nil)
end

return Example
