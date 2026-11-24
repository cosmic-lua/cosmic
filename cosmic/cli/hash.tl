--- `cosmic hash [options] [file|-]...` (or `cosmic hash check <sums>`): prints the digest of each file,
--- or of standard input for `-` or no file. The line is
--- `<hex>  <name>`, as `sha256sum` prints it, on every platform. Each
--- input, a file or standard input, is read a chunk at a time, so its
--- size does not change the memory used. `--json` prints an array of
--- `{path, algorithm, digest}` instead of the lines.
---
--- `-a` (`--algorithm`) names one of the algorithms [`cosmic.hash`] has:
--- `sha256` (the default), `sha512`, `sha384`, `sha224`, `sha1`, `md5`,
--- `sha3-224`, `sha3-256`, `sha3-384` and `sha3-512`.
---
--- Names are written as GNU writes them. A name with a backslash, a newline
--- or a carriage return starts its line with `\` and has `\\`, `\n` and `\r` in
--- it; all three read back. To hash a file named `-` or `check`, give it as
--- `./-` or `./check`. `check` is a command only as the first word:
--- `cosmic hash -a md5 check SUMS` digests the files `check` and `SUMS`.
---
--- `cosmic hash check <sums>` (`-` for standard input) verifies a sums file in
--- that format: text and `*` binary markers, escaped names, and blank
--- and `#` lines skipped. The digest size follows `-a`, so name the
--- algorithm for a file that is not SHA-256. Each file
--- prints `name: OK`, `name: FAILED`, or `name: FAILED open or read`,
--- with its name escaped as above. `--quiet` prints only the failures.
---
--- - BSD lines (`SHA256 (file) = hex`) and one-space separators are
---   malformed. A malformed line makes the exit 5, even when every
---   entry is OK. (GNU only warns, without `--strict`.)
--- - A CRLF sums file leaves the CR in each name.
--- - Each listed path is opened as given. A path that is not a regular
---   file is `FAILED open or read`. A sums file you do not trust can
---   still make it read any regular file you can read.
---
--- `--hmac <key>` makes each digest an HMAC under the key.
--- `--hmac-file <path>` reads the key from a file: its bytes exactly, a
--- trailing newline too, with a warning (write the file with
--- `printf %s`). Use the file: a key on the command line shows in `ps`
--- and in the shell's history. Every algorithm has an HMAC, which also
--- streams. `--json` names it `hmac-sha256` and so on, and `check`
--- verifies HMACs when it is given a key.
---
--- `cosmic hash` prints no summary: its output is data. It exits 0 when
--- all is well, and 1 when a check failed or a listed file could not be
--- read. It exits 2, with `cosmic: hash: ...` on standard error, for a command
--- line it refuses, and 5 for a file to hash, a sums file (a malformed line
--- too) or a write to standard output that it cannot use.
--- @public

local Flags = require("cosmic.flags")

--- `own` with the options both of `hash`'s commands take: the algorithm, and an HMAC's key.
local function shared(own: {string: boolean | Flags.Option}): {string: boolean | Flags.Option}
  local spec: mut {string: boolean | Flags.Option} = {
    ["--algorithm"] = { value = "name", aliases = { "-a" }, default = "sha256", about = "the digest's algorithm",
      choices = { "md5", "sha1", "sha224", "sha256", "sha384", "sha512", "sha3-224", "sha3-256", "sha3-384",
        "sha3-512" } },
    ["--hmac"] = { value = "key", about = "make each digest an HMAC under key (visible in ps)" },
    ["--hmac-file"] = { value = "path", about = "make each digest an HMAC under the bytes of a file" },
  }
  -- The algorithms' own options, before -a named them.
  for _, name in ipairs({ "md5", "sha1", "sha224", "sha256", "sha384", "sha512", "sha3-224", "sha3-256", "sha3-384",
      "sha3-512" }) do
    spec["--" .. name] = { moved = "name the algorithm with -a " .. name }
  end
  for name, option in pairs(own) do spec[name] = option end
  return spec
end

local command: Flags.Command = {
  about = "digest files, or check a sums file",
  usage = "[options] [file|-]... | check [options] <sums|->",
  examples = {
    { line = "notes.txt", about = "the SHA-256 of a file" },
    { line = "-a sha512 notes.txt", about = "another algorithm" },
    { line = "check SHA256SUMS", about = "verify a sums file" },
  },
  subcommands = {
    digest = {
      typed = "",
      -- A line that names no command runs this one, so its usage is the verb's.
      usage = "[options] [file|-]... | check [options] <sums|->",
      about = "print the digest of each file, or of standard input",
      spec = shared({
        ["--json"] = { about = "print an array of {path, algorithm, digest}" },
        ["--check"] = { moved = "`cosmic hash check <sums>` checks a sums file" },
      }),
    },
    check = {
      usage = "[options] <sums|->",
      about = "verify the files a sums file lists, or one read from standard input for -",
      spec = shared({ ["--quiet"] = { about = "print only the failures" } }),
    },
  },
}

return command
