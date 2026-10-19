--- Which checker compiles the tree: the fork's (`teal`, the default) or the new one (`new`), chosen by `COSMIC_GRAMMAR`, the
--- word `cosmic compile --grammar` takes. An unset or empty variable is `teal`; any other word but `new` is refused.
---
--- The mode is part of the tool string that every compile key carries ([`GrammarMode.tool`]), as the identity of a compile
--- with run-time checks is ([`build.importer`]'s `checked_tool`), so a compiled row, a compile the checkouts share and the
--- verdict of a test never stand for the other mode. It is not part of the compiler's identity ([`build.identity`]), which
--- decides when the tool is stale: the tool is the same tool whichever mode a run asks for.
---
--- A module of its own, because [`build.test`] reads it and a harness module reaches no more of the tree than it must.
local Env = require("cosmic.env")
local Hash = require("cosmic.hash")

local record GrammarMode
  --- The checkers a run may compile with.
  enum Mode
    "teal"
    "new"
  end

  --- The mode `word` names: the fork's for nil and "", nil and why for a word that is none.
  of: function(word: string | nil): Mode | nil, string

  --- The mode `COSMIC_GRAMMAR` asks for ([`GrammarMode.of`]).
  mode: function(): Mode | nil, string

  --- The tool string a compile in `mode` is keyed by, given the identity of the compiler `tool`: `tool` itself for the
  --- fork's mode, so that nothing a default run keys moves, and a digest of the tool and the mode for the new one.
  --- `wraps` says the compile writes the calls of `__fact` ([`lang.fact_wraps`]) at the reads a test narrowed, whose Lua is
  --- another program from the one without; the fork writes none, so it is told apart in the new mode alone.
  tool: function(tool: string, mode: Mode, wraps?: boolean): string
end

function GrammarMode.of(word: string | nil): GrammarMode.Mode | nil, string
  if word == nil or word == "" or word == "teal" then
    return "teal"
  elseif word == "new" then
    return "new"
  end
  return nil, "COSMIC_GRAMMAR=" .. word .. ": the grammars are `teal` (the default) and `new`"
end

function GrammarMode.mode(): GrammarMode.Mode | nil, string
  return GrammarMode.of(Env.get("COSMIC_GRAMMAR"))
end

function GrammarMode.tool(tool: string, mode: GrammarMode.Mode, wraps?: boolean): string
  if mode == "teal" then
    return tool
  end
  return Hash.hex_sha256(tool .. (wraps == true and "\0grammar-new\0fact-wraps" or "\0grammar-new"))
end

return GrammarMode
