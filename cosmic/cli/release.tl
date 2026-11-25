--- `cosmic release [list | get | pin <file> | launcher <file>] [--commit hex] [--until time] [options]`:
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
--- - With no command, it prints the release as the three lines of
---   ci/cosmic-driver.pin (commit, URL, sha256), or as an object with
---   `--json`. It downloads no binary.
--- - `list` prints the matches instead, latest commit first, up to `-n`
---   (default 20, one request each): the time each was published and its
---   commit, or an array with `--json`. It verifies none of them.
--- - `get -o <file>` writes the binary to a file. `get --cache` writes it
---   where bin/cosmic-bootstrap caches the pin's binary
---   (`$XDG_CACHE_HOME/cosmic/bootstrap/cosmic-<sha256>`), and prints that
---   path. Each renames the file into place only when its sha256 is the
---   release's digest. A device, a FIFO or `/dev/stdout` at `-o` (or at
---   `pin`'s file) is written in place instead, once the whole binary is
---   verified, with no execute bit. Only the system's own names
---   (`/dev/stdout`, `/dev/fd/N`) are followed: any other link to a
---   device is refused.
--- - `pin <file>` writes the three pin lines to a file after the binary's
---   bytes are verified; `pin -` prints them. `pin` and `launcher` also take `-o` and
---   `--cache`, to keep the binary they verify.
--- - `launcher <file>` sets up a project to run on the release. It writes the
---   pin as `<file>.pin`, and at the file a shell script, a project's
---   bin/cosmic, that runs the release the pin names with the arguments
---   given. The script downloads the release once, runs it only when its
---   sha256 is the pin's, and caches it where `get --cache` does.
---   COSMIC_TOOL=<path> makes the script run another cosmic instead, such
---   as one that `cosmic build` printed in a checkout of cosmic. To move
---   the pin later, run `cosmic release pin <file>.pin`.
---
--- GH_TOKEN goes with the API's requests when it is set, and every
--- redirect must stay on https.
---
--- It prints no summary. It exits 0 when it did what was asked. It exits
--- 1 when it could not: no connection, no matching release, or a release
--- that fails verification. It exits 2 for a command line that it
--- refused, and 5 when its output could not be written.
--- @public

local Flags = require("cosmic.flags")

--- `own` with the options every `release` command takes: which release it is.
local function release_spec(own: {string: boolean | Flags.Option}): {string: boolean | Flags.Option}
  local spec: mut {string: boolean | Flags.Option} = {
    ["--commit"] = { value = "hex", about = "the release whose commit starts with this, 7 to 40 hex digits" },
    ["--until"] = { value = "time", about = "the newest published at or before this RFC 3339 time, or by the end of this date (UTC)" },
  }
  for name, option in pairs(own) do spec[name] = option end
  return spec
end

--- `own` with the options that keep a `release` command's verified binary: `-o` and `--cache`.
local function kept(own: {string: boolean | Flags.Option}): {string: boolean | Flags.Option}
  local spec: mut {string: boolean | Flags.Option} = {
    ["-o"] = { value = "file", about = "write the verified binary here, mode 0755" },
    ["--cache"] = { about = "write the verified binary into bin/cosmic-bootstrap's cache and print its path" },
  }
  for name, option in pairs(own) do spec[name] = option end
  return spec
end

local command: Flags.Command = {
  about = "find, verify and download a release",
  usage = "[list | get | pin | launcher] [options]",
  examples = {
    { line = "", about = "the latest release" },
    { line = "list", about = "list the recent releases" },
    { line = "get -o cosmic", about = "download and verify the latest" },
    { line = "pin --commit 1a2b3c4 ci/cosmic-driver.pin", about = "pin a project to a release" },
  },
  subcommands = {
    show = {
      typed = "",
      -- A line that names no command runs this one, so its usage is the verb's.
      usage = "[list | get | pin | launcher] [options]",
      about = "print the matching release as a pin; downloads no binary",
      spec = release_spec({ ["--json"] = { about = "print it as JSON" } }),
    },
    list = {
      about = "print the matching releases, newest first, verifying none",
      spec = release_spec({
        ["-n"] = { value = "count", integer = { min = 1 }, default = "20", about = "print at most this many" },
        ["--json"] = { about = "print them as JSON" },
      }),
    },
    get = {
      about = "download the release and verify it",
      spec = release_spec(kept({})),
    },
    pin = {
      about = "write the release as ci/cosmic-driver.pin's three lines to a file, or - (standard output), once verified",
      usage = "[options] <file>|-",
      spec = release_spec(kept({})),
    },
    launcher = {
      about = "write a project's launcher to a file, mode 0755, and the release as its pin, <file>.pin",
      usage = "[options] <file>",
      spec = release_spec(kept({})),
    },
  },
}

return command
