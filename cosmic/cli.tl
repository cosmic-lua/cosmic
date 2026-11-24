--- Help for the `cosmic` verbs: `cosmic help` prints an index of them
--- and `cosmic help <verb>` one verb's full text. Each verb is a module
--- of its own, cosmic/cli/<verb>.tl: its overview is the verb's text
--- (`cosmic docs cosmic.cli.test`, [`cosmic.cli.build`], ... show it), and
--- it returns the verb's [`Flags.Command`]. A verb's own code requires
--- that module alone. Where a module has the verb's name (`json`, `test`),
--- `cosmic docs json` shows the module and ends with a line pointing to
--- the verb. This is not an argument parser for a project's own command
--- line: a project's cmd/<name>/main.tl gets its arguments as a plain
--- array, and `Flags.parse(argv, 1, spec)` from cosmic.flags reads its
--- options, or `Flags.dispatch(argv, 1, commands, name)` its commands --
--- see argv.
---
--- The index comes from each verb's `usage` and `about` and from `groups`,
--- a verb's page from its module's overview and its `spec`, in the order
--- `order` gives.

local Flags = require("cosmic.flags")

local record Module
  --- Each verb as [`Flags.Command`] records it, by verb. Its `spec` is the
  --- verb's options, as [`Flags.parse`] reads a spec: what the verb parses
  --- its command line with, and what `cosmic help` lists beneath its
  --- prose, so the two cannot drift apart; a verb with none leaves it
  --- out. Its `about` is what the verb does, as one short phrase for the
  --- index, and its `usage` what follows the verb's name on its line
  --- there. The four typed as no word of their own -- `cosmic <file.tl>`,
  --- `--standalone`, `-e` and `--version` -- have the `usage` that follows
  --- what is typed instead. No verb's `run` is set.
  verbs: {string: Flags.Command}
  --- The index's sections, each a title and the verbs under it, in
  --- order. Together they name every verb once, and set its place.
  groups: {{string}}
  --- Every verb, in the order of [`Module.groups`]: the order help
  --- prints them in.
  order: {string}
end

local GROUPS <const>: {{string}} = {
  { "Running code", "run", "standalone", "eval", "version", "sandbox", "agent" },
  { "Project", "test", "fix", "build", "db", "lsp" },
  { "Quick tools", "sql", "cache", "json", "hash", "codec", "archive", "fetch", "time", "rand", "qr", "acme", "tailscale", "mcp", "compile" },
  { "Lookup", "docs", "uses", "todos", "help" },
  { "This binary", "bom", "refresh", "release" },
}

--- The verbs of `groups` in turn: slot 1 of a group is its title, and
--- its verbs follow.
local function order_of(groups: {{string}}): {string}
  local out: mut {string} = {}
  for _, group in ipairs(groups) do
    for slot = 2, #group do out[#out + 1] = group[slot] end
  end
  return out
end

local module: Module = {
  verbs = {
    run = require("cosmic.cli.run"),
    standalone = require("cosmic.cli.standalone"),
    eval = require("cosmic.cli.eval"),
    version = require("cosmic.cli.version"),
    test = require("cosmic.cli.test"),
    fix = require("cosmic.cli.fix"),
    build = require("cosmic.cli.build"),
    db = require("cosmic.cli.db"),
    lsp = require("cosmic.cli.lsp"),
    sql = require("cosmic.cli.sql"),
    cache = require("cosmic.cli.cache"),
    json = require("cosmic.cli.json"),
    hash = require("cosmic.cli.hash"),
    codec = require("cosmic.cli.codec"),
    archive = require("cosmic.cli.archive"),
    fetch = require("cosmic.cli.fetch"),
    time = require("cosmic.cli.time"),
    rand = require("cosmic.cli.rand"),
    qr = require("cosmic.cli.qr"),
    acme = require("cosmic.cli.acme"),
    tailscale = require("cosmic.cli.tailscale"),
    mcp = require("cosmic.cli.mcp"),
    docs = require("cosmic.cli.docs"),
    uses = require("cosmic.cli.uses"),
    todos = require("cosmic.cli.todos"),
    bom = require("cosmic.cli.bom"),
    refresh = require("cosmic.cli.refresh"),
    release = require("cosmic.cli.release"),
    agent = require("cosmic.cli.agent"),
    sandbox = require("cosmic.cli.sandbox"),
    compile = require("cosmic.cli.compile"),
    help = require("cosmic.cli.help"),
  },
  groups = GROUPS,
  order = order_of(GROUPS),
}

return module
