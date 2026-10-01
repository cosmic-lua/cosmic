--- Whether Zig's ad-hoc signature on a raw macOS core is one Apple's
--- own tooling accepts.
---
---     cosmic --standalone build/verify_codesign.tl <path-to-macos-binary>
---
--- Only macOS itself can judge that -- codesign is not something a
--- Linux host can run -- so every other host takes this as a no-op: the
--- same CI step runs unchanged on every target's own worker, and only
--- the macOS one does real work. [`bin/verify-codesign`] runs this on the
--- bootstrap cosmic, as bin/zig runs build/zig.tl: it requires
--- `cosmic.*` modules only.
local Child = require("cosmic.child")
local Flags = require("cosmic.flags")
local Log = require("cosmic.log")
local Proc = require("cosmic.proc")
local sys = require("cosmic.sys")

local record VerifyCodesign
end

local log = Log.new("verify-codesign")

--- What `bin/verify-codesign --help` says.
local usage = "bin/verify-codesign <path-to-macos-binary>"
local about = "Checks the ad-hoc signature on a raw macOS core with codesign;\n" ..
  "on any other host, says it skipped."
local spec: {string:boolean | Flags.Option} = {
  ["--help"] = { about = "show this help" },
  ["-h"] = { about = "show this help" },
}

--- Verifies `binary` with codesign when `sysname` (uname(2)'s) is
--- "Darwin", and skips on any other host. codesign is found on `path`
--- (PATH when nil), and its output passes straight through. Returns 0
--- when the signature passes or the check is skipped, codesign's own
--- exit status when it fails, and 127 when codesign cannot be found or
--- started.
function VerifyCodesign.verify(sysname: string, binary: string, path?: string): integer
  if sysname ~= "Darwin" then
    log:say("verify-codesign: skipped (" .. binary .. " only verifies on macOS)")
    return 0
  end
  -- Nothing runnable named codesign is 127, as for a missing command,
  -- whether there is none or one without execute permission; the
  -- message says which.
  local tool, missing = Proc.find("codesign", path)
  if tool == nil then
    log:complain(missing)
    return 127
  end
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
    -- 127 whatever the reason it did not start; the message says which.
    if result == nil then
      log:complain(tool .. ": " .. trouble)
      return 127
    end
    if not result.ok then
      return result.code or 128 + (result.signal or 0)
    end
  end
  log:verdict("verify-codesign", true, binary)
  return 0
end

function VerifyCodesign.main(argv: {integer: string}): integer
  local parsed, parse_trouble = Flags.parse(argv, 1, spec)
  if parsed == nil then
    log:complain(parse_trouble .. "; usage: " .. usage)
    return 2
  end
  if parsed.set["--help"] or parsed.set["-h"] then
    -- TODO: once ci/cosmic-driver.pin names a release whose Flags.help
    -- takes a Flags.Command, call it with `spec`, `about` and the words
    -- of `usage` after the program's name. The pinned release, which
    -- runs this script, takes the whole usage line and the spec, and
    -- the tree's takes the command, so the layout is written out here.
    log:say("usage: " .. usage .. "\n\n" .. about .. "\n\noptions:\n" .. Flags.options(spec))
    return 0
  end
  if #parsed.words ~= 1 then
    log:complain("usage: " .. usage)
    return 2
  end
  local names, trouble = sys.uname()
  if names == nil then
    log:complain("uname: " .. trouble)
    return 1
  end
  return VerifyCodesign.verify(names.sysname, parsed.words[1])
end

return VerifyCodesign
