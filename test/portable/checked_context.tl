--- Proves that a checked portable artifact actually selected its checked core.

local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Store = require("cosmic.store")

return function(argv: {string}): integer
  local core, target = argv[1], argv[2]
  assert(core ~= nil and target ~= nil,
    "usage: checked_context.tl RAW_CHECKED_CORE TARGET")
  local bytes = assert(Fs.read(core))
  assert(Store.meta("runtime_context") == "portable-v1")
  assert(Store.meta("host") == target)
  assert(Store.meta("host_image") == Hash.hex_sha256(bytes),
    "checked artifact did not execute the checked raw core")
  return 0
end
