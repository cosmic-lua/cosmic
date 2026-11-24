--- `cosmic bom [--licenses | --json <path>]`: the bill of materials
--- this binary ships under -- every third-party component its cores
--- and database carry, one line each: name, version, license, and
--- how many patches cosmic applies to it, or the files of the tree that
--- stand in for it (`modified:`) -- or, for data (the CA
--- roots, the time zones), that `cosmic refresh` updates it. `--licenses` prints the
--- notices those licenses ask a copy to travel with; `--json` writes
--- the list as a CycloneDX document instead. An executable `cosmic
--- build` writes carries the same rows
--- @public

local Flags = require("cosmic.flags")

local command: Flags.Command = {
  about = "third-party components in this binary",
  usage = "",
  examples = {
    { line = "", about = "the components this binary carries" },
    { line = "--licenses", about = "with their licenses" },
  },
  spec = {
    ["--licenses"] = { about = "print each component's license notices" },
    ["--json"] = { value = "path", about = "write a CycloneDX document to path" },
  },
}

return command
