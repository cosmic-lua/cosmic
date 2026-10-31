--- Which checker compiles the tree: the new one, `new`, the word `cosmic compile --grammar` takes and `COSMIC_GRAMMAR` may
--- name. An unset or empty variable is `new`. The fork's grammar, `teal`, is gone: a project still in it is rewritten to the
--- new grammar by hand (doc/guides/project.md), and any other word is refused too.
---
--- The mode is part of the tool string that every compile key carries ([`GrammarMode.tool`]), as the identity of a compile
--- with run-time checks is ([`build.importer`]'s `checked_tool`), so a compiled row, a compile the checkouts share and the
--- verdict of a test never stand for another compile. It is not part of the compiler's identity ([`build.identity`]), which
--- decides when the tool is stale.
---
--- A module of its own, because [`build.test_key`] reads it and a harness module reaches no more of the tree than it must.
local Env = require("cosmic.env")
local Hash = require("cosmic.hash")

local record GrammarMode
  --- What a checked compile writes ([`GrammarMode.tool`], [`importer.checked_tool`]).
  mut checks_format: string

  --- The checkers a run may compile with.
  enum Mode
    "new"
  end

  --- The mode `word` names: `new` for nil, "" and "new", nil and why for any other word (`teal` is refused, pointing to
  --- the project guide).
  of: function(word: string?): Mode?, string

  --- The mode `COSMIC_GRAMMAR` asks for ([`GrammarMode.of`]).
  mode: function(): Mode?, string

  --- The tool string a compile in `mode` is keyed by, given the identity of the compiler `tool`: a digest of the tool and
  --- the mode. `wraps` says the compile writes the calls of `__fact` ([`lang.fact_wraps`]) at the reads a test narrowed,
  --- whose Lua is another program from the one without.
  tool: function(tool: string, mode: Mode, wraps?: boolean): string
end

function GrammarMode.of(word: string?): GrammarMode.Mode?, string
  if word == nil or word == "" or word == "new" then
    return "new", ""
  elseif word == "teal" then
    return nil, "COSMIC_GRAMMAR=teal: the fork's grammar is gone; rewrite a project to the new grammar by hand, as doc/guides/project.md says"
  end
  return nil, "COSMIC_GRAMMAR=" .. word .. ": the only grammar is `new` (the default)"
end

function GrammarMode.mode(): GrammarMode.Mode?, string
  return GrammarMode.of(Env.get("COSMIC_GRAMMAR"))
end

--- What a checked compile writes, which every key of a checked run holds: the compile keys
--- ([`GrammarMode.tool`], [`importer.checked_tool`]) and the verdict keys ([`build.declared_key`]'s `checks`). A check
--- added to the compile (returns, fields) changes it, and so moves all three at once.
GrammarMode.checks_format = "fact-wraps\0parameter-checks"

function GrammarMode.tool(tool: string, _mode: GrammarMode.Mode, wraps?: boolean): string
  return Hash.hex_sha256(tool .. (if wraps == true then "\0grammar-new\0" .. GrammarMode.checks_format else "\0grammar-new" end))
end

return GrammarMode
