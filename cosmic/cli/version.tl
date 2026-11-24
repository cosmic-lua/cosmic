--- `cosmic --version`: prints `cosmic <hex>`, the SHA-256 of the file
--- this binary runs from -- the digest a release's SHA256SUMS names
--- it by and its notes cite -- with nothing built or checked
--- @public

local Flags = require("cosmic.flags")

local command: Flags.Command = {
  about = "print this binary's digest",
  usage = "",
  examples = {
    { line = "", about = "print this binary's digest" },
  },
}

return command
