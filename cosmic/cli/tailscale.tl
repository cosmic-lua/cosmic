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
--- - `--socket <path>` names the daemon's socket, for every command.
--- @public

local Flags = require("cosmic.flags")

local command: Flags.Command = {
  about = "this machine's Tailscale node, and Taildrop",
  usage = "<status|whois|cert|ping|file> [options] [words...]",
  examples = {
    { line = "status", about = "this node and its peers" },
    { line = "whois 100.101.102.103", about = "who an address is" },
    { line = "file send report.pdf laptop", about = "send a file with Taildrop" },
  },
  spec = {
    ["--socket"] = { value = "path", about = "the daemon's socket, where it is not where it is looked for" },
    ["--json"] = { about = "status, whois, ping, file targets, file list: the reply as JSON" },
    ["--cert-file"] = { value = "file", about = "cert: write the chain here (default <domain>.crt; -: standard output)" },
    ["--key-file"] = { value = "file", about = "cert: write the key here (default <domain>.key; -: standard output)" },
    ["--min-validity"] = { value = "duration", about = "cert: renew first one that expires within this, such as 30d" },
    ["--kind"] = { value = "kind", about = "ping: disco (default), ICMP, TSMP or peerapi" },
    ["--name"] = { value = "name", about = "file send: the name the file goes under (default: its own)" },
    ["--wait"] = { about = "file get: wait for a file when none waits" },
    ["--conflict"] = { value = "how", about = "file get: skip (default), overwrite or rename a name already taken" },
    ["--keep"] = { about = "file get: leave each file waiting in the daemon too" },
  },
}

return command
