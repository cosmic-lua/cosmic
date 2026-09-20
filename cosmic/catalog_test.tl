local Catalog = require("cosmic.catalog")

local function test_every_row_has_a_symbol_module_hint_and_file()
  for _, row in ipairs(Catalog.rows) do
    assert(row.module ~= "", "a row's module is empty")
    assert(row.symbol ~= "", "a row's symbol is empty")
    assert(row.hint ~= "", row.module .. " " .. row.symbol .. ": empty hint")
    assert(row.file ~= "", row.module .. " " .. row.symbol .. ": empty file")
  end
end

local function test_no_two_rows_share_a_module_and_symbol()
  local seen: {string: boolean} = {}
  for _, row in ipairs(Catalog.rows) do
    local key = row.module .. "\n" .. row.symbol
    assert(not seen[key], "duplicate row: " .. key)
    seen[key] = true
  end
end

--- A row with `message` set is matched reactively (`core/main.c`'s
--- `catalog_guidance`) against a real uncaught error's own text, so
--- its `hint` must be able to add something beyond that text -- see
--- `cosmic/catalog.tl`'s own doc comment for why the removed-global
--- and convention rows opt out with an empty `message` instead.
local function test_a_row_with_a_message_has_a_different_hint()
  for _, row in ipairs(Catalog.rows) do
    if row.message ~= "" then
      assert(row.hint ~= row.message,
        row.module .. " " .. row.symbol ..
        ": hint repeats message, so a reactive match would print it twice")
    end
  end
end
