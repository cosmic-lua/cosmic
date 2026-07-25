--- The strip floor: what a stripped artifact keeps, and the epoch its
--- entries carry.
---
--- Split out of cosmic.embed for the 500-line cap. Both halves of
--- reproducible, minimal artifacts live here: the positive keep-list
--- (so a base that grows a directory does not silently start shipping
--- it) and the fixed mtime (so two builds of one tree agree).

--- Reproducible-build epoch: `SOURCE_DATE_EPOCH` when the environment
--- sets it, else the DOS timestamp floor a zip entry can represent
--- (1980-01-01). Anything earlier is unrepresentable, so the floor is
--- both the safe default and a visibly synthetic one.
local DOS_EPOCH < const > = 315532800

--- The positive floor a stripped artifact keeps. Prefix match; a name
--- equal to a prefix minus its trailing slash counts too, so the
--- directory marker survives with its contents.
---
--- This is a KEEP list rather than a strip list on purpose: a base that
--- grows a new directory must not silently start shipping it in every
--- artifact anyone builds.
local FLOOR < const >: {string} = {
  ".lua/cosmic/", -- the standard library, compiled
  "usr/", -- TLS roots and zoneinfo
  ".args", -- default argv
  ".cosmo", -- cosmopolitan's own marker
}

--- Resolve the reproducible-build epoch.
--- @return integer SOURCE_DATE_EPOCH if set and numeric, else the DOS floor
local function epoch(): integer
  local named = os.getenv("SOURCE_DATE_EPOCH")
  if named then
    local n = math.tointeger(tonumber(named))
    if n and n >= DOS_EPOCH then
      return n
    end
  end
  return DOS_EPOCH
end

--- Is this base entry on the floor?
--- @param name string A zip entry name
--- @return boolean True when a stripped artifact keeps it
local function in_floor(name: string): boolean
  for _, prefix in ipairs(FLOOR) do
    if name == prefix or name:sub(1, #prefix) == prefix then
      return true
    end
    -- The directory marker for a kept prefix ("usr/" keeps "usr").
    if prefix:sub(-1) == "/" and name == prefix:sub(1, -2) then
      return true
    end
  end
  return false
end

local record FloorModule
  DOS_EPOCH: integer
  FLOOR: {string}
  epoch: function(): integer
  in_floor: function(name: string): boolean
end

local M: FloorModule = {
  DOS_EPOCH = DOS_EPOCH,
  FLOOR = FLOOR,
  epoch = epoch,
  in_floor = in_floor,
}

return M
