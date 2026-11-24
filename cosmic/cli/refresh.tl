--- `cosmic refresh -o <path> [--binary <path>] [--<dataset> <file>...]
--- [dataset...]`: the way to update the CA certificates a binary
--- trusts, the certificates it refuses as revoked, and the time zone
--- database it carries when they go out of date, with no rebuild. It
--- writes to path a copy of this binary -- or of the one --binary
--- names, a program `cosmic build` wrote, say -- whose
--- data is replaced with a newer release: the CA roots it trusts
--- (cacert, Mozilla's root store as NSS's newest release holds it in
--- certdata.txt, with the dates after which it trusts a root for no
--- server certificate issued; a file may be that or a PEM bundle, which
--- names no dates) and the time zones
--- it carries (tzdata, as PyPI's tzdata sdist holds them), and the
--- certificates it refuses as revoked (onecrl, Mozilla's OneCRL, as its
--- remote settings feed serves it). Each named
--- dataset is fetched upstream, its newest release; one given a file is
--- read from it, with no network; with neither, every dataset is
--- fetched. Every row is checked before anything is written, the
--- bill of materials records the release each came from, and the
--- binary it reads is never written
--- @public

local Flags = require("cosmic.flags")

local command: Flags.Command = {
  about = "update a binary's certificates and time zones",
  usage = "-o <path>",
  examples = {
    { line = "-o cosmic.new", about = "a copy with newer CA roots, revocations and time zones" },
  },
  spec = {
    ["-o"] = { value = "path", about = "write the refreshed binary here" },
    ["--binary"] = { value = "path", about = "refresh this binary rather than the running one" },
    ["--cacert"] = { value = "file", about = "read the CA roots from this certdata.txt (NSS's) or PEM bundle" },
    ["--onecrl"] = { value = "file", about = "read the revoked certificates from this OneCRL changeset" },
    ["--tzdata"] = { value = "file", about = "read the time zones from this tzdata sdist" },
  },
}

return command
