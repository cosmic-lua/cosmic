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
  "cosmic/", -- the standard library, compiled
  -- the `cosmic` module itself: cosmic/init.tl flattens to the zip
  -- root, OUTSIDE the cosmic/ prefix, and without it a stripped
  -- artifact cannot require("cosmic") (cosmic.main, the taught entry
  -- point)
  "cosmic.lua",
  "usr/", -- TLS roots and zoneinfo
  ".args", -- default argv
  ".cosmo", -- cosmopolitan's own marker
}

--- Floor entries a project can supersede by providing the module
--- namespace itself, keyed by that namespace's import path.
---
--- The keep-list stays positive and stays the default: a claim
--- *subtracts* from it rather than replacing it, so a base that grows a
--- directory still cannot silently start shipping it. Only namespaces
--- the floor actually carries appear here — `tl` is providable too, but
--- a stripped artifact never keeps the base's copy of it, so claiming
--- `tl` has nothing to subtract.
local SUPERSEDABLE < const >: {string: string} = {
  cosmic = "cosmic/",
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
---
--- `provides` names module namespaces the artifact supplies itself. A
--- supplied namespace leaves the floor: keeping the base's copy beside
--- the project's would ship two standard libraries in one binary, with
--- `package.path` silently deciding which one every require() gets.
--- @param name string A zip entry name
--- @param provides {string: boolean} Namespaces the artifact provides
--- @return boolean True when a stripped artifact keeps it
local function in_floor(name: string, provides?: {string: boolean}): boolean
  if provides then
    for ns, prefix in pairs(SUPERSEDABLE) do
      -- The flattened module file (`cosmic.lua`) is part of the
      -- namespace a claim supersedes, same as the directory.
      if provides[ns] and
      (name == prefix or name:sub(1, #prefix) == prefix or
        name == prefix:sub(1, -2) or name == ns .. ".lua") then
        return false
      end
    end
  end
  for _, prefix in ipairs(FLOOR) do
    -- An exact match, or a match under a DIRECTORY prefix. Testing the
    -- prefix for every entry regardless of separator lets a
    -- file-shaped entry like `.args` also match `.argsX` -- and a
    -- keep list that keeps more than it names silently ships whatever
    -- a base grows next to a kept file. Harmless today
    -- (nothing in a base is named that way); wrong in the direction
    -- this list exists to be right in.
    if name == prefix then
      return true
    end
    if prefix:sub(-1) == "/" then
      if name:sub(1, #prefix) == prefix then
        return true
      end
      -- The directory marker itself ("usr/" keeps "usr").
      if name == prefix:sub(1, -2) then
        return true
      end
    end
  end
  return false
end

local record FloorModule
  DOS_EPOCH: integer
  FLOOR: {string}
  SUPERSEDABLE: {string: string}
  epoch: function(): integer
  in_floor: function(name: string, provides?: {string: boolean}): boolean
end

local M: FloorModule = {
  DOS_EPOCH = DOS_EPOCH,
  FLOOR = FLOOR,
  SUPERSEDABLE = SUPERSEDABLE,
  epoch = epoch,
  in_floor = in_floor,
}

return M
