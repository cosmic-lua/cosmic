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

local child = require("cosmic.child")
local fs = require("cosmic.fs")

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

--- The Lua that `compile_staged` runs INSIDE the base runtime. It is
--- `dump` above, transcribed: same shebang blanking, same `@/zip/`
--- chunkname, same unstripped `string.dump`. The two must stay in step
--- -- `bytecode_test`'s `test_staged_matches_dump` pins that by
--- comparing their output byte for byte on this tree's own runtime.
local CONVERTER < const > = [==[
local dir, manifest = ...
for stored in io.lines(manifest) do
  local path = dir .. "/" .. stored
  local fh, oerr = io.open(path, "rb")
  if not fh then
    io.stderr:write("bytecode: cannot read " .. path .. ": " .. tostring(oerr) .. "\n")
    os.exit(1)
  end
  local body = fh:read("a")
  fh:close()
  if body:sub(1, 2) == "#!" then
    body = "--" .. body:sub(3)
  end
  local chunk, lerr = load(body, "@/zip/" .. stored)
  if not chunk then
    io.stderr:write("bytecode: /zip/" .. stored .. ": " .. tostring(lerr) .. "\n")
    os.exit(1)
  end
  local out, werr = io.open(path, "wb")
  if not out then
    io.stderr:write("bytecode: cannot write " .. path .. ": " .. tostring(werr) .. "\n")
    os.exit(1)
  end
  out:write(string.dump(chunk, false))
  out:close()
end
]==]

--- Compile the staged module files to bytecode, in place, using the
--- artifact's OWN base runtime rather than this process.
---
--- Bytecode is version-stamped and a runtime refuses to load another
--- version's, so the dumper's Lua and the base's must agree. Dumping in
--- process makes them agree only by luck: they are the same only while
--- the running cosmic was itself built on the cosmos the pin now names.
--- Bump the cosmos pin across a Lua release and generation 1 stages the
--- old version's bytecode onto the new base, producing a binary that
--- cannot load its own `cosmic.searcher` -- and convergence cannot heal
--- it, because healing means re-execing into exactly that binary.
--- Dumping with the base ties the two together by construction, so the
--- bump is an ordinary pin change instead of a bootstrap problem.
---
--- One spawn for the whole payload, not one per module: the runtime
--- reads a manifest of staged paths and rewrites each in place. The
--- manifest, the converter and an EXECUTABLE copy of the runtime live
--- under `o/`, never inside `dir` -- everything in there is artifact.
---
--- The copy is why this does not exec `runtime` where it lies: a unit
--- stages its base as data, mode 0644, so the file that will run the
--- payload cannot itself be run. Copying it and setting the bit leaves
--- the unit's own base untouched, and works for any base a project
--- declares rather than assuming the cosmos one.
--- @param runtime string Path to the base runtime, as it will load the payload
--- @param dir string The staging directory
--- @param stored {string} Artifact-relative paths of the module entries
--- @return boolean Whether every module compiled
--- @return string The error message
local function compile_staged(runtime: string, dir: string,
    stored: {string}): boolean, string
  if #stored == 0 then
    return true
  end
  local work = dir .. ".bytecode"
  local mok, merr = fs.make_dirs(work)
  if not mok then
    return false, "make: cannot create " .. work .. ": " ..
    (merr or "unknown error")
  end
  local prog = fs.join(work, "convert.lua")
  local manifest = fs.join(work, "modules.txt")
  local exe = fs.join(work, "runtime")
  local cpok, cperr = fs.copy(runtime, exe)
  if not cpok then
    return false, "make: bytecode: cannot copy " .. runtime .. ": " ..
    (cperr or "unknown error")
  end
  local xok, xerr = fs.set_mode(exe, fs.octal("755"))
  if not xok then
    return false, "make: bytecode: cannot make " .. exe .. " executable: " ..
    (xerr or "unknown error")
  end
  local pok, perr = fs.write(prog, CONVERTER)
  if not pok then
    return false, "make: cannot write " .. prog .. ": " .. (perr or "unknown error")
  end
  local wok, werr = fs.write(manifest, table.concat(stored, "\n") .. "\n")
  if not wok then
    return false, "make: cannot write " .. manifest .. ": " .. (werr or "unknown error")
  end
  local r, rerr = child.run({exe, prog, dir, manifest},
    {stdout = "inherit", stderr = "inherit"})
  if r == nil then
    return false, "make: bytecode: " .. tostring(rerr or "start failed")
  end
  if not r.ok then
    return false, "make: bytecode: " .. runtime .. " failed to compile the payload"
  end
  local _rok, _rerr = fs.remove_all(work)
  return true
end

--- Whether a generated payload path lands in the artifact's MODULE root,
--- and so must be compiled like any other module.
---
--- The rule is the dot-prefix convention the payload already runs on:
--- names under a dot-prefixed directory stay out of the module root, so
--- `tl.lua` is a module and `.docs/index.lua` is not. Load-bearing rather
--- than cosmetic -- the docs index is a bare table literal, read with
--- `load("return " .. source)`, and compiling it as a chunk fails.
--- @param stored string The path inside the artifact
--- @return boolean Whether it is a module
local function is_module_path(stored: string): boolean
  return stored:sub(-4) == ".lua" and stored:sub(1, 1) ~= "."
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
  compile_staged: function(runtime: string, dir: string,
  stored: {string}): boolean, string
  is_module_path: function(stored: string): boolean
  dump: function(body: string, chunkname: string): string | nil, string
  for_stage: function(content: string, stored: string,
  is_module: boolean): string | nil, string
end

local M: BytecodeModule = {
  compile_staged = compile_staged,
  is_module_path = is_module_path,
  dump = dump,
  for_stage = for_stage,
}

return M
