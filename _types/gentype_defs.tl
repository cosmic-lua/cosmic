--- Where the cosmo binding annotations come from.
---
--- One module because two callers need the same answer and a second
--- resolution can disagree with the first: the generator reads these to
--- produce the committed `.d.tl` files, and the drift test reads them to
--- check the committed files still match.

local fs = require("cosmic.fs")
local zip = require("cosmic.zip")

--- The pinned cosmos runtime, which carries `definitions.lua`.
---
--- `cosmic --make fetch` lands it in its unit's output directory; the
--- Makefile's fetch pipeline symlinks `o/cosmos/.staged` at a
--- version-stamped copy. The second arm goes with the Makefile.
--- @return string Path to the pinned `lua`
local function runtime_path(): string
  local fetched = fs.join("o", "3p", "cosmos", "lua")
  if fs.isfile(fetched) then
    return fetched
  end
  return fs.join("o", "cosmos", ".staged", "lua")
end

--- Read the annotations the committed `.d.tl` files describe.
---
--- Out of the PINNED runtime, which is the release those types were
--- generated against. The RUNNING binary's copy
--- (`/zip/.lua/definitions.lua`) looks equivalent and is not: a cosmic
--- built by `cosmic --make` strips `definitions.lua` off its base by
--- design, so reading from `/zip` makes the answer depend on which
--- binary happens to be driving. GENTYPE_DEFS overrides, for validating
--- against a cosmopolitan checkout before a release is cut.
--- @return string|nil The definitions.lua source
--- @return string The error message
local function read(): string | nil, string
  local override = os.getenv("GENTYPE_DEFS")
  if override then
    local source = fs.read(override)
    if not source then
      return nil, "Failed to read " .. override
    end
    return source
  end
  local runtime = runtime_path()
  local reader, oerr = zip.reader(runtime)
  if not reader then
    return nil, "Failed to open " .. runtime ..
    " (run `cosmic --make fetch`): " .. (oerr or "unknown error")
  end
  -- cast: Reader | nil, and an early-exit guard does not narrow
  local source, rerr = (reader as zip.Reader):read(".lua/definitions.lua")
  if not source then
    return nil, "Failed to read .lua/definitions.lua from " .. runtime ..
    ": " .. (rerr or "unknown error")
  end
  return source
end

local record GentypeDefsModule
  read: function(): string | nil, string
  runtime_path: function(): string
end

local M: GentypeDefsModule = {
  read = read,
  runtime_path = runtime_path,
}

return M
