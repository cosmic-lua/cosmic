--- UUID generation utilities.
--- Wraps cosmo UUID functions for generating unique identifiers.
---
--- Example usage:
---   local uuid = require("cosmic.uuid")
---   local id = uuid.v4()   -- random UUID
---   local id = uuid.v7()   -- time-ordered UUID
local cosmo = require("cosmo")

--- Generate a random UUID (version 4).
--- Returns a string in standard UUID format (e.g., "550e8400-e29b-41d4-a716-446655440000").
--- @return string A random UUID string
local function v4(): string
  return cosmo.UuidV4()
end

--- Generate a time-ordered UUID (version 7).
--- Returns a string in standard UUID format with embedded timestamp.
--- UUIDv7 is useful for database primary keys since time-ordering provides better index locality.
--- @return string A time-ordered UUID string
local function v7(): string
  return cosmo.UuidV7()
end

local record UuidModule
  v4: function(): string
  v7: function(): string
end

local M: UuidModule = {
  v4 = v4,
  v7 = v7,
}

return M
