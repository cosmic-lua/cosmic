--- The board's trust root stays two plain lines and one script: the
--- pin names one gitboard release of cosmic-lua/work by url and a
--- 64-hex sha256, and bin/gitboard is the POSIX sh that reads it.
--- No network: the shape is what is ratcheted, the download is the
--- script's own job.
local fs = require("cosmic.fs")

local PIN < const > = "bin/gitboard.pin"
local SCRIPT < const > = "bin/gitboard"
local RELEASES < const > = "https://github.com/cosmic-lua/work/releases/download/"

local function fields(): {string: string}
  local text = assert(fs.read(PIN))
  local out: {string: string} = {}
  for line in text:gmatch("[^\n]+") do
    local k, v = line:match("^(%w+) *= *(.+)$")
    if k then
      out[k] = v
    end
  end
  return out
end

local function test_pin_names_one_gitboard_release_by_url_and_sha256()
  local f = fields()
  assert(f.url, "pin has no url line")
  assert(f.sha256, "pin has no sha256 line")
  assert(f.url:sub(1, #RELEASES) == RELEASES, "url is not a cosmic-lua/work release: " .. f.url)
  assert(f.url:match("/gitboard$"), "url does not name the gitboard asset: " .. f.url)
  assert(#f.sha256 == 64 and f.sha256:match("^%x+$"), "sha256 is not 64 hex: " .. f.sha256)
end

local function test_script_is_posix_sh_reading_the_pin()
  local text = assert(fs.read(SCRIPT))
  assert(text:sub(1, 10) == "#!/bin/sh\n", "bin/gitboard is not POSIX sh")
  assert(text:find("gitboard.pin", 1, true), "bin/gitboard does not name its pin")
  assert(text:find("GITBOARD_DIR", 1, true), "bin/gitboard does not export GITBOARD_DIR")
end
