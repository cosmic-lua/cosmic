--- The tool string every compile key carries: a digest of the compiler's identity ([`GrammarMode.tool`]), as the identity
--- of a compile with run-time checks is ([`build.importer`]'s `checked_tool`), so a compiled row, a compile the checkouts
--- share and the verdict of a test never stand for another compile. It is not part of the compiler's identity
--- ([`build.identity`]), which decides when the tool is stale.
---
--- A module of its own, because [`build.test_key`] reads it and a harness module reaches no more of the tree than it must.
local Hash = require("cosmic.hash")

local record GrammarMode
  --- What a checked compile writes ([`GrammarMode.tool`], [`importer.checked_tool`]).
  mut checks_format: string

  --- The tool string a compile is keyed by, given the identity of the compiler `tool`: a digest of the tool. `wraps` says the
  --- compile writes the calls of `__fact` ([`lang.fact_wraps`]) at the reads a test narrowed, whose Lua is another program
  --- from the one without.
  tool: function(tool: string, wraps?: boolean): string
end

--- What a checked compile writes, which every key of a checked run holds: the compile keys
--- ([`GrammarMode.tool`], [`importer.checked_tool`]) and the verdict keys ([`build.declared_key`]'s `checks`). A check
--- added to the compile (returns, fields) changes it, and so moves all three at once.
GrammarMode.checks_format = "fact-wraps\0parameter-checks\0counted"

function GrammarMode.tool(tool: string, wraps?: boolean): string
  return Hash.hex_sha256(tool .. (if wraps == true then "\0grammar-new\0" .. GrammarMode.checks_format else "\0grammar-new" end))
end

return GrammarMode
