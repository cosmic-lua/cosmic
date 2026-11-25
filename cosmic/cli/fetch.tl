--- `cosmic fetch <url[#sha256=hex]> [-o file] [--sha256 hex] [--sha512 hex] [--allow-downgrade]
--- [--roots set] [--cacert file] [--pin pin]`, or `cosmic fetch head [--json] <url> [...]`: makes one GET, like a small
--- curl. GET is the only method, by design: for a header, a body or
--- another method, write a script with [`cosmic.http`].
---
--- Without `-o`, the body goes to standard output, so
--- `cosmic fetch <url> | cosmic json '$.items'` reads it. With `-o`, the
--- body is written to a temporary file beside the target. The file is
--- renamed into place only when the whole body is in and its digest
--- matches. So a failed digest leaves nothing at the target. A device,
--- a FIFO or `/dev/stdout` (`-o /dev/null`, a named pipe) is written in
--- place, as standard output is, never replaced by a regular file. A FIFO
--- with no reader holds the fetch until one opens it, as a shell's `>`
--- does.
---
--- Digests:
---
--- - `--sha256` or `--sha512` gives the digest. The URL's fragment can
---   also carry it: `<url>#sha256=<hex>`, or `#sha256sum=`, `#sha512=`,
---   `#sha512sum=`. The fragment is never sent or printed.
--- - An unknown fragment is dropped. A fragment that looks like a
---   checksum this verb does not check, such as `sha1=` or `SHA256=`,
---   exits 2.
--- - A bad digest, or an option and a fragment for one algorithm that
---   differ, exits 2 before any request. For different algorithms, both
---   must match.
--- - A digest (`--sha256`, `--sha512` or a fragment) with standard output
---   holds the whole body in memory, with no limit, and writes it only
---   when the digest matches, because bytes already on a pipe cannot be
---   taken back. On a mismatch it exits 1 and names both digests.
--- - Without a digest, streaming to standard output can leave partial
---   bytes sent before a failure (exit 5).
---
--- Status and redirects:
---
--- - A status outside 2xx fails (exit 1, with the status on standard
---   error), as `curl -f` does. Nothing turns this off, so an error page
---   never reaches a pipe.
--- - `fetch head` prints `HTTP <status>` and the headers, with names
---   lowercased and sorted. With `--json` it prints an object of `status`,
---   `url` and `headers`. It also fails on a status outside 2xx.
--- - Redirects are followed, up to 10, as [`cosmic.http`] follows them.
---   From an https URL, a redirect to http is refused (exit 5), unlike
---   curl's default. `--allow-downgrade` follows it; use it with
---   `--sha256`.
--- - Header values print with control bytes as `\xNN`, and a URL's
---   userinfo prints as `***`.
---
--- Certificates:
---
--- Certificates are always verified: no option turns this off.
---
--- - `--roots` chooses the CA roots to verify against, as
---   [`Http.Options`]'s `roots` does: `minimal`, `none`, or digests
---   joined by commas.
--- - `--cacert` also trusts a file's certificates.
--- - `--pin` holds the server's key to a public key pin
---   ([`Http.public_key_pin`]).
--- - A value of the wrong shape exits 2 before any request, and a
---   `--cacert` file it cannot read exits 5.
---
--- It prints no summary: its output is the body that a pipe reads. It
--- exits 0 when the body was delivered. It exits 1 when the server said no
--- (a status outside 2xx) or a digest does not match. It exits 2 for a
--- command line or a URL that it refuses. It exits 5 when the fetch could
--- not be done: no connection, a body that broke off, or an `-o` write or
--- a write to standard output that failed.
--- @public

local Flags = require("cosmic.flags")

--- `own` with the options both of `fetch`'s commands take: what to trust, and whether a downgrade is followed.
local function fetch_spec(own: {string: boolean | Flags.Option}): {string: boolean | Flags.Option}
  local spec: mut {string: boolean | Flags.Option} = {
    ["--allow-downgrade"] = { about = "follow a redirect from https to http, which is refused by default" },
    ["--roots"] = { value = "set", about = "trust these CA roots: minimal (the default), mozilla, none, " ..
        "or root sha256 digests joined by commas" },
    ["--cacert"] = { value = "file", about = "also trust the certificates in this PEM or DER file; " ..
        "with --roots none, only them", dash = "input" },
    ["--pin"] = { value = "pin", about = "fail unless the server's key hashes to this sha256//<base64>; " ..
        "repeat for more than one" },
  }
  for name, option in pairs(own) do spec[name] = option end
  return spec
end

local command: Flags.Command = {
  about = "GET a URL, verifying what it keeps",
  usage = "[head] <url>",
  examples = {
    { line = "https://example.com/", about = "print the body" },
    { line = "-o tool.tgz https://example.com/tool.tgz --sha256 2c26b46b68ffc68ff99b453c1d30413413422d706483bfa0f98a5e886266e7ae", about = "save it, if it has this digest" },
    { line = "head --json https://example.com/", about = "its status and headers, as JSON" },
  },
  subcommands = {
    get = {
      typed = "",
      about = "print the body, or save it",
      usage = "<url[#sha256=<hex>]>",
      spec = fetch_spec({
        ["-o"] = { value = "file", about = "write the body to file, renamed into place once complete and verified " ..
            "(a device or FIFO is written in place)", dash = "output" },
        ["--sha256"] = { value = "hex", about = "fail unless the body has this sha256; on stdout, buffer until verified" },
        ["--sha512"] = { value = "hex", about = "fail unless the body has this sha512 (also checked with --sha256)" },
      }),
    },
    head = {
      about = "print the status and headers, not the body",
      usage = "[--json] [options] <url>",
      spec = fetch_spec({ ["--json"] = { about = "print them as a JSON object" } }),
    },
  },
}

return command
