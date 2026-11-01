--- The one grammar a run compiles with, the new one, and the tool string every compile key carries. `COSMIC_GRAMMAR` may
--- name `new` and nothing else; an unset or empty variable is `new`. The fork's grammar, `teal`, is gone: a project still in
--- it is rewritten to the new grammar by hand (doc/guides/project.md), and a run that finds the variable naming it, or
--- any other word, is refused.
---
--- The tool string is a digest of the compiler's identity ([`GrammarMode.tool`]), as the identity of a compile with
--- run-time checks is ([`build.importer`]'s `checked_tool`), so a compiled row, a compile the checkouts share and the
--- verdict of a test never stand for another compile. It is not part of the compiler's identity ([`build.identity`]), which
--- decides when the tool is stale.
---
--- A module of its own, because [`build.test_key`] reads it and a harness module reaches no more of the tree than it must.
local Env = require("cosmic.env")
local Hash = require("cosmic.hash")

local record GrammarMode
  --- What a checked compile writes ([`GrammarMode.tool`], [`importer.checked_tool`]).
  mut checks_format: string

  --- Why `word` is refused as the value of `COSMIC_GRAMMAR`, or nil for nil, "" and "new" (`teal` is refused, pointing to
  --- the project guide).
  refusal_of: function(word: string?): string?

  --- Why the `COSMIC_GRAMMAR` of this process is refused ([`GrammarMode.refusal_of`]), or nil.
  refusal: function(): string?

  --- The tool string a compile is keyed by, given the identity of the compiler `tool`: a digest of the tool. `wraps` says the
  --- compile writes the calls of `__fact` ([`lang.fact_wraps`]) at the reads a test narrowed, whose Lua is another program
  --- from the one without.
  tool: function(tool: string, wraps?: boolean): string
end

function GrammarMode.refusal_of(word: string?): string?
  if word == nil or word == "" or word == "new" then
    return nil
  elseif word == "teal" then
    return "COSMIC_GRAMMAR=teal: the fork's grammar is gone; rewrite a project to the new grammar by hand, as doc/guides/project.md says"
  end
  return "COSMIC_GRAMMAR=" .. word .. ": the only grammar is `new` (the default)"
end

function GrammarMode.refusal(): string?
  return GrammarMode.refusal_of(Env.read("COSMIC_GRAMMAR"))
end

--- What a checked compile writes, which every key of a checked run holds: the compile keys
--- ([`GrammarMode.tool`], [`importer.checked_tool`]) and the verdict keys ([`build.declared_key`]'s `checks`). A check
--- added to the compile (returns, fields) changes it, and so moves all three at once.
GrammarMode.checks_format = "fact-wraps\0parameter-checks\0counted"

function GrammarMode.tool(tool: string, wraps?: boolean): string
  return Hash.hex_sha256(tool .. (if wraps == true then "\0grammar-new\0" .. GrammarMode.checks_format else "\0grammar-new" end))
end

return GrammarMode
