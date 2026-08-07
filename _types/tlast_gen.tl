--- Generate the tl stdlib AST cache into `o/_types/tlast_gen/`.
---
--- A generation unit, like `_types/types_gen.tl` beside it: `--make`
--- hands it its output directory and runs it before the graph. The
--- logic lives in `_types/tlast.tl` — a requirable, tested module —
--- because a `*_gen.tl` is a generator by position, not a module, and
--- cannot be imported (the gentl/types_gen split). What this writes is
--- the artifact payload `.tl_ast.luac`; see tlast.tl for the how and
--- whilp/cosmic#967 for the why.

local cosmic = require("cosmic")
local proc = require("cosmic.proc")
local tlast = require("_types.tlast")

if proc.is_main() then
  cosmic.main(function(args: {string}): number, string
      local dest = args[1]
      if not dest or dest == "" then
        return 1, "tlast_gen: usage: tlast_gen <output-dir>"
      end
      local err = tlast.generate(dest)
      if err then
        return 1, "tlast_gen: " .. err
      end
      return 0
    end)
end

local record TlastGenModule
  generate: function(dest: string): string | nil
end

local M: TlastGenModule = {
  generate = tlast.generate,
}

return M
