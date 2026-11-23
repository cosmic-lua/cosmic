--- `cosmic release [--commit hex] [--until time] [--list [-n count] | -o file | --cache] [--pin file | --launcher file] [--json]`:
--- finds cosmic's own releases, picks one and verifies it. The releases
--- are the `YYYYMMDD-<commit>` prereleases of cosmic-lua/cosmic on GitHub
--- (older ones are `next-<commit>`).
---
--- Finding a release:
---
--- Releases are found by their tags and main's history, newest commit
--- first, because the API's list of releases serves only 1000, and not by
--- time.
---
--- - With no criterion, it picks the release of the latest commit on main
---   that has one.
--- - `--commit` picks the release whose commit starts with the hex (7 to
---   40 digits). It reads only the releases of the tags whose commit
---   starts with that prefix, and refuses a prefix that matches more than
---   10.
--- - `--until` picks the latest release published at or before an RFC
---   3339 time, or by the end of a date in UTC.
--- - `--commit` and `--until` may be given together.
---
--- A release is verified first: its SHA256SUMS must give one digest for
--- cosmic, and its source.json the same commit and digest.
---
--- What it does with the release:
---
--- - With nothing more, it prints the release as the three lines of
---   ci/cosmic-driver.pin (commit, URL, sha256), or as an object with
---   `--json`. It downloads no binary.
--- - `--list` prints the matches instead, latest commit first, up to `-n`
---   (default 20, one request each): the time each was published and its
---   commit, or an array with `--json`. It verifies none of them.
--- - `-o` writes the binary to a file. `--cache` writes it where
---   bin/cosmic-bootstrap caches the pin's binary
---   (`$XDG_CACHE_HOME/cosmic/bootstrap/cosmic-<sha256>`), and prints that
---   path. Each renames the file into place only when its sha256 is the
---   release's digest.
--- - `--pin` writes the three pin lines to a file after the binary's bytes
---   are verified.
--- - `--launcher` sets up a project to run on the release. It writes the
---   pin as `<file>.pin`, and at the file a shell script, a project's
---   bin/cosmic, that runs the release the pin names with the arguments
---   given. The script downloads the release once, runs it only when its
---   sha256 is the pin's, and caches it where `--cache` does.
---   COSMIC_TOOL=<path> makes the script run another cosmic instead, such
---   as one that `cosmic build` printed in a checkout of cosmic. To move
---   the pin later, run `cosmic release --pin <file>.pin` alone.
---
--- GH_TOKEN goes with the API's requests when it is set, and every
--- redirect must stay on https.
---
--- It prints no summary. It exits 0 when it did what was asked. It exits
--- 1 when it could not: no connection, no matching release, a release
--- that fails verification, or a write that failed. It exits 2 for a
--- command line that it refused.
--- @public

local Flags = require("cosmic.flags")

local command: Flags.Command = {
  about = "find, verify and download a release",
  usage = "[--commit <hex>] [--until <time>] [--list [-n <count>] | -o <file> | --cache] [--pin <file> | --launcher <file>] [--json]",
  examples = {
    { line = "--list", about = "list the recent releases" },
    { line = "-o cosmic", about = "download and verify the latest" },
  },
  spec = {
    ["--commit"] = { value = "hex", about = "the release whose commit starts with this, 7 to 40 hex digits" },
    ["--until"] = { value = "time", about = "the newest published at or before this RFC 3339 time, or by the end of this date (UTC)" },
    ["--list"] = { about = "print the matching releases, newest first, verifying none" },
    ["-n"] = { value = "count", about = "with --list, print at most this many (default 20)" },
    ["--json"] = { about = "print the release, or with --list the releases, as JSON" },
    ["-o"] = { value = "file", about = "write the verified binary here, mode 0755" },
    ["--cache"] = { about = "write the verified binary into bin/cosmic-bootstrap's cache and print its path" },
    ["--pin"] = { value = "file", about = "write the release as ci/cosmic-driver.pin's three lines, once verified" },
    ["--launcher"] = { value = "file", about = "write a project's launcher here, mode 0755, and the release as its pin, <file>.pin" },
  },
}

return command
