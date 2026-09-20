local Catalog = require("cosmic.catalog")
local Errno = require("cosmic.errno")

local function test_every_row_has_a_module_symbol_message_and_file()
  for _, row in ipairs(Catalog.rows) do
    assert(row.module ~= "", "a row's module is empty")
    assert(row.symbol ~= "", "a row's symbol is empty")
    assert(row.message ~= "", row.module .. " " .. row.symbol .. ": empty message")
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

--- Every row's message is exactly the `cosmic.errno` field it names,
--- the strerror() text `core/main.c`'s reactive matcher looks for --
--- if these ever drifted apart, a real ENOENT would stop finding its
--- own guidance, silently.
local function test_every_row_matches_its_own_errno_field()
  local by_symbol: {string: string} = {}
  for _, row in ipairs(Catalog.rows) do
    by_symbol[row.symbol] = row.message
  end
  assert(by_symbol["Errno.ENOENT"] == Errno.ENOENT)
  assert(by_symbol["Errno.EACCES"] == Errno.EACCES)
  assert(by_symbol["Errno.EEXIST"] == Errno.EEXIST)
  assert(by_symbol["Errno.ENOTDIR"] == Errno.ENOTDIR)
  assert(by_symbol["Errno.EISDIR"] == Errno.EISDIR)
  assert(by_symbol["Errno.ENOSPC"] == Errno.ENOSPC)
  assert(by_symbol["Errno.EMFILE"] == Errno.EMFILE)
end
