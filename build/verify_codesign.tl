--- Whether Zig's ad-hoc signature on a raw macOS core is one Apple's
--- own tooling accepts.
---
---     cosmic --standalone build/verify_codesign.tl <path-to-macos-binary>
---
--- Only macOS itself can judge that -- codesign is not something a
--- Linux host can run -- so every other host takes this as a no-op: the
--- same CI step runs unchanged on every target's own worker, and only
--- the macOS one does real work. `bin/verify-codesign` runs this on the
--- bootstrap cosmic, as bin/zig runs build/zig.tl: it requires
--- `cosmic.*` modules only.
local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local sys = require("cosmic.sys")

local record VerifyCodesign
  --- Where macOS keeps codesign.
  codesign: string
end

-- TODO: find codesign on PATH with Proc.find, as the sh did, once
-- ci/cosmic-driver.pin names a cosmic carrying it: this runs standalone
-- on the pinned release. macOS ships codesign at this path, which nothing
-- on PATH can shadow in the meantime.
VerifyCodesign.codesign = "/usr/bin/codesign"

--- Verifies `binary` on a host whose uname(2) sysname is `sysname`,
--- with codesign's own output passing straight through; the exit
--- status the shell script gave.
-- TODO: Log.new("verify-codesign") for these lines once
-- ci/cosmic-driver.pin names a cosmic carrying cosmic.log: bin/verify-codesign
-- runs this file on the pinned bootstrap.
function VerifyCodesign.verify(sysname: string, binary: string, codesign?: string): integer
  if sysname ~= "Darwin" then
    Fs.put(Fs.stdout, "verify-codesign: skipped (" .. binary .. " only verifies on macOS)\n")
    return 0
  end
  local tool = codesign or VerifyCodesign.codesign
  for _, args in ipairs({
    { "--verify", "--strict", "--verbose=2" },
    { "--display", "--verbose=4" },
  }) do
    local argv: {string} = { tool }
    for _, word in ipairs(args) do
      argv[#argv + 1] = word
    end
    argv[#argv + 1] = binary
    local result, trouble = Child.run(argv)
    -- A codesign that cannot be started is 127 whatever the reason, as
    -- for a missing command; the message says which.
    if result == nil then
      Fs.put(Fs.stderr, "verify-codesign: " .. tool .. ": " .. trouble .. "\n")
      return 127
    end
    if not result.ok then
      return result.code or 128 + (result.signal or 0)
    end
  end
  Fs.put(Fs.stdout, "verify-codesign: PASS (" .. binary .. ")\n")
  return 0
end

function VerifyCodesign.main(argv: {integer: string}): integer
  if argv[1] == nil or argv[2] ~= nil then
    Fs.put(Fs.stderr, "verify-codesign: usage: bin/verify-codesign <path-to-macos-binary>\n")
    return 2
  end
  local names, trouble = sys.uname()
  if names == nil then
    Fs.put(Fs.stderr, "verify-codesign: uname: " .. trouble .. "\n")
    return 1
  end
  return VerifyCodesign.verify(names.sysname, argv[1])
end

return VerifyCodesign
