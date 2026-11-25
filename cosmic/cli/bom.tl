--- `cosmic bom [list | licenses | cyclonedx [-o <path>]]`: the bill of materials
--- this binary ships under -- every third-party component its cores
--- and database carry, one line each: name, version, license, and
--- how many patches cosmic applies to it, or the files of the tree that
--- stand in for it (`modified:`) -- or, for data (the CA
--- roots, the time zones), that `cosmic refresh` updates it. `cosmic bom
--- list` is the same. `licenses` prints the notices those licenses ask a
--- copy to travel with; `cyclonedx` prints the list as a CycloneDX
--- document instead, or writes it to the path `-o` names. An executable `cosmic
--- build` writes carries the same rows
--- @public

local Flags = require("cosmic.flags")

local command: Flags.Command = {
  about = "third-party components in this binary",
  usage = "[list | licenses | cyclonedx] ...",
  examples = {
    { line = "", about = "the components this binary carries" },
    { line = "licenses", about = "their license notices" },
    { line = "cyclonedx -o bom.json", about = "a CycloneDX document of them" },
  },
  subcommands = {
    list = { about = "one line per component (what `cosmic bom` alone prints)" },
    licenses = { about = "the notices the components' licenses ask a copy to travel with" },
    cyclonedx = {
      about = "the components as a CycloneDX document",
      spec = { ["-o"] = { value = "path", about = "write it to path rather than to stdout", dash = "output" } },
    },
  },
}

return command
