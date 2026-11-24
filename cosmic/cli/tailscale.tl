--- `cosmic tailscale <status|whois|cert|ping|file> ...`: asks the
--- machine's own Tailscale node, through tailscaled's LocalAPI, with no
--- `tailscale` binary. A program asks the daemon with
--- [`cosmic.tailscale`].
---
--- Commands:
---
--- - `status` prints this node and each peer, one a line: its address,
---   MagicDNS name, owner or tags, OS, and how traffic reaches it. It
---   exits 1 when the node is not running.
--- - `whois <address|name>` prints the node that a tailnet address
---   belongs to, its user, and the capabilities that the policy's grants
---   give it here.
--- - `cert [domain]` writes the certificate of one of the node's names
---   (the first by default, as in `cosmic tailscale cert`) to
---   `<domain>.crt`, and its key to `<domain>.key` with mode 0600.
---   `--cert-file` and `--key-file` name other files (`-` for standard
---   output). `--min-validity 30d` makes the daemon first renew a
---   certificate that expires sooner.
--- - `ping <address|name>` prints the round trip and the path it took
---   (`--kind disco|ICMP|TSMP|peerapi`).
---
--- Taildrop (`file`):
---
--- - `file targets` lists the nodes that a file can go to.
--- - `file send <file|-> <target>` sends a file to a node by name,
---   address or stable id. `--name` renames it.
--- - `file list` lists the files that wait here.
--- - `file get <dir>` writes each waiting file into the directory and
---   drops it from the daemon. `--keep` leaves it there, and `--wait`
---   waits for a file. `--conflict skip|overwrite|rename` says what to
---   do when a name is already taken (default skip).
---
--- Other options:
---
--- - `--json` prints the daemon's reply as JSON, for `status`, `whois`,
---   `ping`, `file targets` and `file list`.
--- - `--socket <path>`, after the command, names the daemon's socket.
--- @public

local Flags = require("cosmic.flags")

local socket: Flags.Option = { value = "path", about = "the daemon's socket, where it is not where it is looked for" }
local json: Flags.Option = { about = "the reply as JSON" }

local command: Flags.Command = {
  about = "this machine's Tailscale node, and Taildrop",
  usage = "<cert|file|ping|status|whois> ...",
  examples = {
    { line = "status", about = "this node and its peers" },
    { line = "whois 100.101.102.103", about = "who an address is" },
    { line = "file send report.pdf laptop", about = "send a file with Taildrop" },
  },
  subcommands = {
    status = {
      about = "this node and each peer",
      spec = { ["--socket"] = socket, ["--json"] = json },
    },
    whois = {
      about = "the node an address or name belongs to",
      usage = "[--json] <address|name>",
      spec = { ["--socket"] = socket, ["--json"] = json },
    },
    cert = {
      about = "the certificate and key of one of the node's names",
      usage = "[options] [domain]",
      spec = {
        ["--socket"] = socket,
        ["--cert-file"] = { value = "file", about = "write the chain here (default <domain>.crt; -: standard output)" },
        ["--key-file"] = { value = "file", about = "write the key here (default <domain>.key; -: standard output)" },
        ["--min-validity"] = { value = "duration", about = "renew first one that expires within this, such as 30d" },
      },
    },
    ping = {
      about = "the round trip to a node and the path it took",
      usage = "[options] <address|name>",
      spec = {
        ["--socket"] = socket, ["--json"] = json,
        ["--kind"] = { value = "kind", about = "the kind of ping", choices = { "disco", "ICMP", "TSMP", "peerapi" },
          default = "disco" },
      },
    },
    file = {
      about = "Taildrop: send and get files",
      usage = "<get|list|send|targets> ...",
      subcommands = {
        targets = {
          about = "the nodes a file may go to",
          spec = { ["--socket"] = socket, ["--json"] = json },
        },
        send = {
          about = "send a file, or - for standard input, to a target",
          usage = "[--name <name>] <file>|- <target>",
          spec = {
            ["--socket"] = socket,
            ["--name"] = { value = "name", about = "the name the file goes under (default: its own)" },
          },
        },
        list = {
          about = "the files waiting here",
          spec = { ["--socket"] = socket, ["--json"] = json },
        },
        get = {
          about = "move the waiting files into a directory",
          usage = "[options] <dir>",
          spec = {
            ["--socket"] = socket,
            ["--wait"] = { about = "wait for a file when none waits" },
            ["--conflict"] = { value = "how", about = "a name already taken", choices = { "skip", "overwrite", "rename" },
              default = "skip" },
            ["--keep"] = { about = "leave each file waiting in the daemon too" },
          },
        },
      },
    },
  },
}

return command
