-- Welcome message state tracking for first-run experience.
--
-- The "shown" marker lives in the user's per-user config directory,
-- never inside the executable (step 10): zip-appending it to the
-- running binary made released binaries fail SHA256SUMS verification,
-- and on Windows — where the running exe is locked — the banner
-- reprinted forever. An embedded /zip marker still counts as shown, so
-- a distributor can pre-seed a binary and copies mutated by older
-- cosmic versions stay quiet.

local fs = require("cosmic.fs")
local sys = require("cosmic.sys")

local MARKER < const > = "welcome-shown"

--- Per-user directory for cosmic state: %LOCALAPPDATA%\cosmic on
--- Windows, else $XDG_CONFIG_HOME/cosmic or $HOME/.config/cosmic.
--- @return string | nil The directory, or nil when no base dir is set
local function config_dir(): string | nil
  if sys.host_os() == "windows" then
    local base = os.getenv("LOCALAPPDATA")
    if base and base ~= "" then
      return fs.join(base, "cosmic")
    end
    return nil
  end
  local xdg = os.getenv("XDG_CONFIG_HOME")
  if xdg and xdg ~= "" then
    return fs.join(xdg, "cosmic")
  end
  local home = os.getenv("HOME")
  if home and home ~= "" then
    return fs.join(home, ".config", "cosmic")
  end
  return nil
end

--- Check if welcome has been shown.
--- @return boolean True when the config-dir marker or an embedded /zip marker exists
local function was_shown(): boolean
  local dir = config_dir()
  if dir and fs.isfile(fs.join(dir, MARKER)) then
    return true
  end
  return fs.read("/zip/.cosmic/" .. MARKER) ~= nil
end

--- Mark welcome as shown by writing the config-dir marker.
--- Failures (no resolvable home, unwritable directory) are ignored:
--- showing welcome again is acceptable, and the binary itself is
--- never modified.
local function mark_shown()
  local dir = config_dir()
  if not dir then
    return
  end
  fs.makedirs(dir)
  fs.write(fs.join(dir, MARKER), "")
end

return {was_shown = was_shown, mark_shown = mark_shown}
