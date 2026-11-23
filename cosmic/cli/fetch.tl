--- `cosmic fetch <url[#sha256=hex]> [-o file] [--sha256 hex] [--sha512 hex] [--allow-downgrade] [--head [--json]]
--- [--roots set] [--cacert file] [--pin pin]`: makes one GET, like a small
--- curl. GET is the only method, by design: for a header, a body or
--- another method, write a script with [`cosmic.http`].
---
--- Without `-o`, the body goes to standard output, so
--- `cosmic fetch <url> | cosmic json '$.items'` reads it. With `-o`, the
--- body is written to a temporary file beside the target. The file is
--- renamed into place only when the whole body is in and its digest
--- matches. So a failed digest leaves nothing at the target.
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
---   bytes sent before a failure (exit 1).
---
--- Status and redirects:
---
--- - A status outside 2xx fails (exit 1, with the status on standard
---   error), as `curl -f` does. Nothing turns this off, so an error page
---   never reaches a pipe.
--- - `--head` prints `HTTP <status>` and the headers, with names
---   lowercased and sorted. With `--json` it prints an object of `status`,
---   `url` and `headers`. It also fails on a status outside 2xx.
--- - Redirects are followed, up to 10, as [`cosmic.http`] follows them.
---   From an https URL, a redirect to http is refused (exit 1), unlike
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
--- - A value of the wrong shape, or a `--cacert` file it cannot read,
---   exits 2 before any request.
---
--- It prints no summary: its output is the body that a pipe reads. It
--- exits 0 when the body was delivered. It exits 1 when the fetch failed:
--- no connection, a bad status, a digest that does not match, a body that
--- broke off, or an `-o` write that failed. It exits 2 for a command line,
--- a URL or a write to standard output that it cannot use.
--- @public

local Flags = require("cosmic.flags")

local command: Flags.Command = {
  about = "GET a URL, verifying what it keeps",
  usage = "<url>",
  examples = {
    { line = "https://example.com/", about = "print the body" },
    { line = "-o tool.tgz https://example.com/tool.tgz --sha256 2c26b46b68ffc68ff99b453c1d30413413422d706483bfa0f98a5e886266e7ae", about = "save it, if it has this digest" },
  },
  spec = {
    ["-o"] = { value = "file", about = "write the body to file, renamed into place once complete and verified" },
    ["--sha256"] = { value = "hex", about = "fail unless the body has this sha256; on stdout, buffer until verified" },
    ["--sha512"] = { value = "hex", about = "fail unless the body has this sha512 (also checked with --sha256)" },
    ["--allow-downgrade"] = { about = "follow a redirect from https to http, which is refused by default" },
    ["--head"] = { about = "print the status and headers, not the body" },
    ["--json"] = { about = "with --head, print them as a JSON object" },
    ["--roots"] = { value = "set", about = "trust these CA roots: minimal (the default), mozilla, none, " ..
        "or root sha256 digests joined by commas" },
    ["--cacert"] = { value = "file", about = "also trust the certificates in this PEM or DER file; " ..
        "with --roots none, only them" },
    ["--pin"] = { value = "pin", about = "fail unless the server's key hashes to this sha256//<base64>; " ..
        "repeat for more than one" },
  },
}

return command
