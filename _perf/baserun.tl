#!/usr/bin/env cosmic
--- Measure a baseline cosmic binary against the TREE's `_perf`.
---
---   cosmic --make run _perf/baserun.tl --bin PATH [run args...]
---
--- A compare is only a compare when the INSTRUMENT is held fixed and
--- the SUBJECT is not. `_perf/**` is the instrument; `cosmic/**` is the
--- subject. Run an older binary bare and it answers `_perf.*` from its
--- own embedded copy, so the two sides of a release compare are
--- measured by two different instruments — the previous release's
--- scenarios against the tree's.
---
--- This module builds the one shape that fixes that without also
--- fixing the subject: a `--modules` manifest whose root directory
--- holds NOTHING but `_perf` and `o/_perf`. `cosmic.searcher`'s tree
--- searcher resolves `<root>/<build>/<rel>.lua` then `<root>/<rel>.tl`
--- and MISSES otherwise, falling through to the binary's own `/zip` —
--- so such a root answers `_perf.*` from the tree and leaves every
--- `cosmic.*` require to the binary under measurement. That emptiness
--- IS the mechanism: a root that also holds `cosmic/` would put the
--- tree's library on both sides of the compare and make a real
--- regression cancel out.
---
--- Both callers that measure a baseline go through here — the release
--- workflow's compare step and `_perf/gate.tl`'s regression retry — so
--- the retry, which is what decides the gate, cannot resolve `_perf`
--- differently from the pass it is retrying.

local child = require("cosmic.child")
local fs = require("cosmic.fs")
local proc = require("cosmic.proc")

--- The entry the manifest carries the baseline binary into.
---
--- The BUILT `.lua`, never `_perf/run.tl`: a `.tl` entry is type-checked
--- through the binary's own include path, which finds
--- `/zip/.tl/_perf/*.tl` before any require runs, so the entry would be
--- checked against the binary's embedded declarations rather than
--- loaded from the tree.
local ENTRY < const > = "o/_perf/run.lua"

--- Name of the scoped root, under `<root>/<build>/perf/`.
local TREEROOT < const > = "treeroot"

--- Name of the manifest, beside the scoped root.
local MANIFEST < const > = "tree.modules"

local USAGE < const > = [[
usage: baserun.lua --bin PATH [run args...]
  measures PATH against the tree's _perf; every other argument is
  passed through to _perf/run.tl.
]]

--- Create one symlink, tolerating an existing one.
--- @param target string What the link points at
--- @param linkpath string Where the link lives
--- @return boolean Success
--- @return string Error message on failure
local function link_once(target: string, linkpath: string): boolean, string
  if fs.is_link(linkpath) then
    return true, nil
  end
  local ok, err = fs.symlink(target, linkpath)
  if not ok then
    return false, "symlink " .. linkpath .. ": " .. tostring(err)
  end
  return true, nil
end

--- Build the `_perf`-scoped root and write its manifest.
---
--- Idempotent: an existing link is left alone, and the manifest is
--- rewritten with the same bytes. The root gains no entry beyond
--- `_perf` and `o/_perf` — `_perf/baserun_test.tl` asserts exactly
--- that, because any further entry silently widens what the baseline
--- side resolves from the tree.
--- @param root string The project root
--- @param build string The build directory name ("o")
--- @return string|nil Path of the manifest written
--- @return string Error message on failure
local function ensure_root(root: string, build: string): string | nil, string
  local base = fs.join(root, build, "perf", TREEROOT)
  local built = fs.join(base, "o")
  local mok, merr = fs.make_dirs(built)
  if not mok then
    return nil, "make_dirs " .. built .. ": " .. tostring(merr)
  end
  local sok, serr = link_once(fs.absolute_path(fs.join(root, "_perf")),
    fs.join(base, "_perf"))
  if not sok then
    return nil, serr
  end
  local bok, berr = link_once(fs.absolute_path(fs.join(root, build, "_perf")),
    fs.join(built, "_perf"))
  if not bok then
    return nil, berr
  end
  local manifest = fs.join(root, build, "perf", MANIFEST)
  local text = "root " .. fs.absolute_path(base) .. "\nbuild o\n"
  local wok, werr = fs.write(manifest, text)
  if not wok then
    return nil, "write " .. manifest .. ": " .. tostring(werr)
  end
  return manifest
end

--- The argv that runs a baseline binary against the tree's `_perf`.
--- @param bin string The baseline binary
--- @param modules string The manifest ensure_root wrote
--- @param extra {string} Arguments passed through to the harness
--- @return {string} The argv
local function argv(bin: string, modules: string, extra: {string}): {string}
  local out: {string} = {bin, "--modules", modules, ENTRY}
  for _, a in ipairs(extra) do
    out[#out + 1] = a
  end
  return out
end

--- CLI entry point: `--bin PATH`, everything else passed through.
--- @param ... string Command-line arguments
--- @return integer The child's exit code, or 1 on a setup failure
local function main(...: string): integer
  local bin: string = nil
  local extra: {string} = {}
  local raw = {...}
  local i = 1
  while i <= #raw do
    if raw[i] == "--bin" then
      i = i + 1
      bin = raw[i]
    else
      extra[#extra + 1] = raw[i]
    end
    i = i + 1
  end
  if bin == nil or bin == "" then
    io.stderr:write(USAGE)
    return 1
  end
  local cwd, cerr = fs.cwd()
  if cwd == nil then
    io.stderr:write("perf-baserun: cwd: " .. tostring(cerr) .. "\n")
    return 1
  end
  local manifest, eerr = ensure_root(cwd, "o")
  if manifest == nil then
    io.stderr:write("perf-baserun: " .. eerr .. "\n")
    return 1
  end
  local res, rerr = child.run(argv(bin, manifest, extra),
    {stdout = "inherit", stderr = "inherit"})
  if res == nil then
    io.stderr:write("perf-baserun: " .. tostring(rerr) .. "\n")
    return 1
  end
  return res.code or 1
end

if proc.is_main() then
  os.exit(main(...)) -- exits: process boundary, this is a script entry
end

local record baserun
  ensure_root: function(root: string, build: string): string | nil, string
  argv: function(bin: string, modules: string, extra: {string}): {string}
  main: function(...: string): integer
end

local M: baserun = {
  ensure_root = ensure_root,
  argv = argv,
  main = main,
}

return M
