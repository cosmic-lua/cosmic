--- `cosmic acme <key|issue> ...`: a TLS certificate from an ACME
--- certificate authority (RFC 8555) such as Let's Encrypt. `key
--- [--rsa [--bits N]] <file|->` writes a new private key as PEM, P-256
--- by default, in a new file of mode 0600; a file that is there is
--- refused. `issue --account <file> --key <file> <name>...` asks for a
--- certificate for the DNS names under the account key, made into an
--- account on the first issue (`--agree-tos` accepts the server's
--- terms; `--contact mailto:...`, once or more), and prints the chain
--- as PEM, or writes it to `--out <file>`. A key file is PEM as `key`
--- writes it, or as OpenSSL does (SEC 1, PKCS #1 or PKCS #8). It takes
--- one way to prove each name: `--webroot <dir>` writes the http-01
--- response under `<dir>/.well-known/acme-challenge/`, which the web
--- server for the name serves on port 80; `--dns-hook <program>`
--- meets dns-01, which a wildcard needs, by running `<program> present
--- <record> <value>`, which puts the TXT record and exits 0 once the
--- zone serves it, and `<program> cleanup <record> <value>` after. The
--- directory is Let's Encrypt's production one; `--staging` takes its
--- staging one, and `--directory <url>` another server. Examples:
--- `cosmic acme key account.pem`, then `cosmic acme issue --account
--- account.pem --key site.pem --webroot /var/www --agree-tos --out
--- chain.pem example.com`. A program asks for its own with
--- [`cosmic.acme`]. It prints no summary. Exits 0 when it wrote, 1 when
--- the server or a challenge refused the issue or a request failed, 2
--- for a command line or a key file it refuses, 5 for a write that failed
--- @public

local Flags = require("cosmic.flags")

local command: Flags.Command = {
  about = "a certificate from Let's Encrypt",
  usage = "<issue|key> ...",
  examples = {
    { line = "key account.pem", about = "make a key" },
    { line = "issue --account account.pem --key site.pem --webroot /var/www --agree-tos --out chain.pem example.com", about = "get a certificate" },
  },
  subcommands = {
    key = {
      about = "a new key, written to a file or - for standard output",
      usage = "[--rsa [--bits n]] <file>|-",
      spec = {
        ["--rsa"] = { about = "an RSA key, not P-256" },
        ["--bits"] = { value = "n", about = "the RSA key's bits (default 2048)", choices = { "2048", "3072", "4096" } },
      },
    },
    issue = {
      about = "a certificate for the names",
      usage = "[options] <name>...",
      spec = {
        ["--account"] = { value = "file", about = "the account key, as PEM" },
        ["--key"] = { value = "file", about = "the certificate key, as PEM" },
        ["--webroot"] = { value = "dir", about = "meet http-01 from this web root" },
        ["--dns-hook"] = { value = "program", about = "meet dns-01 by running this program" },
        ["--staging"] = { about = "Let's Encrypt's staging server" },
        ["--directory"] = { value = "url", about = "another ACME server's directory" },
        ["--contact"] = { value = "url", about = "a contact for the account, such as mailto:ops@example.com" },
        ["--agree-tos"] = { about = "accept the server's terms of service" },
        ["--out"] = { value = "file", about = "write the chain here, not to standard output" },
      },
    },
  },
}

return command
