--- A test whose module declares `store` is given the whole projection,
--- keyed by its contents, and no hold: `Store.meta` answers every row,
--- the tree-wide ones and the compiler's among them
--- (`build.test_worker`'s `held_meta`, which holds a module that does
--- not declare it).

local Store = require("cosmic.store")
local Test = require("cosmic.test")

--- Its key holds the projection, which holds these rows.
Test.needs{ store = true }

local function test_every_row_is_read_without_a_hold()
  for _, key in ipairs({ "boot_hash", "projected", "compiler", "compiled_by" }) do
    local ok, why = pcall(Store.meta, key)
    assert(ok, "meta " .. key .. " is held: " .. tostring(why))
    assert(why ~= nil, "the projection holds " .. key)
  end
end
