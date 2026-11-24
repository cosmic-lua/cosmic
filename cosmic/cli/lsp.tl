--- `cosmic lsp [--stdio] [--listen [host:]port] [--socket path]`: a
--- Language Server Protocol server for Teal, which an editor starts.
--- It publishes the checker's errors and warnings as a document is
--- opened, changed or saved, checked in memory as the editor holds it
--- and as a build checks it, with a project's `require` found as a
--- build finds modules, from open documents, then the modules a build
--- stages of the workspace's root, staged again when the editor says a
--- file changed on disk, then the binary's `cosmic.*`; it responds to hover
--- with a symbol's docs, as `cosmic docs`, to go to definition
--- with where a name is declared, and formats a document as
--- `cosmic fix` does. It serves one editor over standard input and
--- output, or, with `--listen` (a numeric IPv4 host or a bracketed
--- IPv6 one, the loopback when only a port is given) or `--socket`,
--- each editor that connects until SIGINT or SIGTERM. Whoever reaches
--- a listener reads the files below the root it names, unasked who it
--- is: it warns on standard error when it listens beyond the loopback.
--- `--stdio` takes neither of the others. Over standard input and
--- output it exits 0 after the editor's `shutdown`, at `exit` or the
--- stream's end, and 1 at an `exit` or an end with no `shutdown`
--- before it or a stream that breaks; a listener exits 0 when a signal
--- stops it and 1 when it cannot listen, as at a socket file already
--- there, which it leaves for a person to remove; 2 for a command line
--- it refuses
--- @public

local Flags = require("cosmic.flags")

local command: Flags.Command = {
  about = "a language server for editors",
  usage = "[--stdio] [--listen [host:]port] [--socket path]",
  examples = {
    { line = "", about = "serve one editor over standard input and output" },
  },
  spec = {
    ["--stdio"] = { about = "serve one editor over standard input and output (the default)" },
    ["--listen"] = { value = "[host:]port",
      about = "serve each editor that connects to this TCP port" },
    ["--socket"] = { value = "path",
      about = "serve each editor that connects to this socket file" },
  },
}

return command
