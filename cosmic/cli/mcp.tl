--- `cosmic mcp <action> ... [--url URL | -- program args...]`: asks a
--- Model Context Protocol server, revision 2026-07-28, and prints its
--- reply as one line of JSON. The server is a program it starts and
--- speaks to over stdio, the words after `--` (a `.tl` file first is
--- run by this program), or one at `--url` over Streamable HTTP, with
--- the bearer token in the variable `--token-env NAME` names. The
--- actions: `discover`, `tools`, `resources`, `templates`, `prompts`,
--- `call <tool> [json]`, `read <uri>` and `prompt <name> [json]`.
--- `--timeout` bounds each request over HTTP, and a program's whole
--- run (30 seconds). A plain `http://` URL takes a token only to a
--- loopback host. A word of the action that starts with `-` is read
--- as an option. Examples: `cosmic mcp tools
--- -- server.tl`, `cosmic mcp call add '{"a":1,"b":2}' -- server.tl`.
--- A program serves with [`cosmic.mcp.server`] and asks with
--- [`cosmic.mcp.client`]. It prints no summary. Exits 0 when it
--- got a reply, 1 when the server failed or refused or a tool's result is
--- an error, 2 for a command line it refuses, 5 for a write that failed
--- @public

local Flags = require("cosmic.flags")

local command: Flags.Command = {
  about = "ask an MCP server, or run its tools",
  usage = "<action> [words...] [-- program...]",
  spec = {
    ["--url"] = { value = "url", about = "the server's Streamable HTTP endpoint, not a program" },
    ["--token-env"] = { value = "name", about = "url: the variable that holds the bearer token" },
    ["--timeout"] = { value = "seconds", about = "the most a request over --url, or a program's run, may take (default 30)" },
  },
  examples = {
    { line = "tools -- server.tl", about = "list the tools of a server this program runs from server.tl" },
    { line = "call add '{\"a\":2,\"b\":5}' -- server.tl", about = "call its tool add" },
    { line = "tools --url https://example.com/mcp --token-env MCP_TOKEN", about = "ask a server over HTTP, its token in $MCP_TOKEN" },
  },
}

return command
