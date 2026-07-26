#!/usr/bin/env cosmic
--- Write `o/project.mk` for this repo's own Makefile — the migration
--- bridge.
---
--- `cosmic --make` generates the same file internally and then drives
--- make with it. This repo cannot use that path yet, for two reasons
--- worth stating: the pinned bootstrap that runs every recipe predates
--- the generator, and `o/cosmic.mk`'s own `build`/`test`/`fmt` targets
--- collide with the ones the Makefile still defines. So the Makefile
--- adopts the FACTS first and keeps its rules, and this script is how
--- the facts get written — by calling the same `_make` modules
--- the verb calls, out of the TREE, so there is one generator and not
--- two.
---
--- It lives HERE, not in `_build/` where the rest of this repo's build
--- tooling sits, because that is where its inputs are: `_make/`
--- is internal to `cosmic/`, so a script outside it cannot import the
--- model — `--make check` said so, in as many words, the moment the
--- script existed. Put it where its inputs are is the design's own
--- rule, and it applies to the bridge too.
---
--- Deliberately temporary: when the Makefile's own targets retire
--- the bridge becomes `-include o/cosmic.mk` and this file goes — or
--- becomes the `facts` verb, which is what it already is minus a name.

local fs = require("cosmic.fs")
local graph = require("_make.graph")
local project = require("_make.project")
local proc = require("cosmic.proc")
local types = require("_make.types")

--- Scan the current directory and write the facts file, but only when
--- the bytes change: make re-execs itself whenever an included makefile
--- is remade, so an unconditional write would restart every build.
--- @param out string Path to write (o/project.mk)
--- @return integer Exit code
local function main(out: string): integer
  if not out or out == "" then
    io.stderr:write("facts: usage: facts <out>\n")
    return 2
  end
  local root, rerr = fs.getcwd()
  if not root then
    io.stderr:write("facts: " .. (rerr or "cannot determine the root") .. "\n")
    return 1
  end
  local proj, perr = project.scan(root as string) -- cast: scalar narrowing after the guard
  if not proj then
    io.stderr:write("facts: " .. (perr or "scan failed") .. "\n")
    return 1
  end

  -- COSMIC names the binary a recipe would exec. Nothing in the bridge
  -- reads it — the Makefile's recipes name their own — so the honest
  -- value is whatever is running this.
  local self = rawget(arg, -1) as string or "cosmic" -- cast: arg is untyped
  local content = graph.project_mk(proj as types.Project, self) -- cast: record union after the guard
  if fs.read(out) == content then
    return 0
  end
  local ok, werr = fs.write(out, content)
  if not ok then
    io.stderr:write("facts: cannot write " .. out .. ": " ..
      (werr or "unknown error") .. "\n")
    return 1
  end
  return 0
end

if proc.is_main() then
  os.exit(main(...))
end

return {main = main}
