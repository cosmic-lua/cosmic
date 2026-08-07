--- Compile Lua source to bytecode for the artifact payload.
---
--- NOT stripped (`string.dump(f, false)`), though an unstripped chunk
--- embedding a build-machine path looks like the exact reproducibility
--- hazard stripping exists to remove. Two things make it safe here
--- instead: `chunkname` is always the deterministic `/zip/`-prefixed
--- path the module lands at inside the artifact, never a filesystem
--- path, so two builds dump identical bytes either way
--- (`_make.artifact_test`'s `test_reproducible` covers this claim);
--- and stripping drops line info from every prototype, which silently
--- zeroes `cosmic.coverage`'s `debug.sethook(fn, "l")` hits for any
--- module a test only reaches by spawning the built artifact
--- (`cosmic/searcher.tl`, every `_cli`/`_make` file the `--make`
--- fixture tests exercise that way) -- verified against this exact
--- `load`/`dump` pair, and caught by the coverage ratchet.
---
--- `cmd/cosmic/embed_gen.tl` carries its own copy of this rather than
--- requiring this module: that file runs as a GENERATOR (`_make.
--- generate`'s `run_generator`), compiled in a spawned `cosmic` without
--- `--include-dir .`, so an unresolvable or newly-shaped dependency
--- there is checked against whatever the RUNNING binary already has
--- bundled at `/zip/.tl/**` -- not this tree's edited copy -- and
--- fails loudly rather than picking up what this file says today.

--- Compile Lua source to bytecode.
---
--- `load` on a STRING (unlike `loadfile`) does not skip a leading
--- shebang, and a module built to double as a standalone script
--- (`cosmic/tar.tl` runs `#!/usr/bin/env lua`) compiles it in as the
--- first line -- so it is blanked first, the same trick
--- `cosmic.searcher` uses for the identical reason.
--- @param body string The Lua source, as staged
--- @param chunkname string The chunk's `source`; always `/zip/`-prefixed
--- @return string|nil The bytecode, or nil on a load failure
--- @return string The load error, prefixed with `chunkname`
local function dump(body: string, chunkname: string): string | nil, string
  local source = body
  if source:sub(1, 2) == "#!" then
    source = "--" .. source:sub(3)
  end
  local chunk, lerr = load(source, "@" .. chunkname)
  if not chunk then
    return nil, chunkname .. ": " .. (lerr or "cannot load")
  end
  return string.dump(chunk, false), nil
end

--- The content `_make.artifact`'s `stage` should write for one staged
--- file: bytecode when it is a module or entry, else `content` as is.
--- @param content string The staged file's bytes
--- @param stored string Its path inside the artifact
--- @param is_module boolean Staged.is_module -- see that record
--- @return string|nil The bytes to write, or nil on a load failure
--- @return string The load error, when the first return is nil
local function for_stage(content: string, stored: string,
    is_module: boolean): string | nil, string
  if not is_module then
    return content, nil
  end
  return dump(content, "/zip/" .. stored)
end

local record BytecodeModule
  dump: function(body: string, chunkname: string): string | nil, string
  for_stage: function(content: string, stored: string,
  is_module: boolean): string | nil, string
end

local M: BytecodeModule = {
  dump = dump,
  for_stage = for_stage,
}

return M
