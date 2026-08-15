--- The batched compile step behind `$(O)/.groups/<dir>.compiled`:
--- one step per DIRECTORY instead of one per file, so the boot, the
--- compiler, and — through the engine's env reuse — every checked
--- import are paid once per group instead of once per member.
---
--- Per-member honesty is unchanged: each member keeps its own
--- content-keyed `.in` record, byte-compatible with the per-file
--- `compile` step's (same label, same inputs, same format), so the two
--- paths interchange freely. A member whose key hits is restamped
--- without recompiling, and every member this step verifies or
--- compiles is restamped, so the per-file rules self-skip on fresh
--- mtimes and remain the correctness safety net rather than the hot
--- path.
---
--- Failure semantics: every member is attempted and every failure
--- reported — the retry recompiles only the broken ones, since the
--- clean members kept their records. Setting COSMIC_FAIL_FAST
--- (nonempty) stops at the first failure instead; it changes what is
--- ATTEMPTED, never what a recorded result means, so it stays out of
--- the skip key's environment switches. The stamp is written only when
--- every member succeeded, so `.DELETE_ON_ERROR` re-runs the batch
--- until the group is clean.

local env = require("cosmic.env")
local fs = require("cosmic.fs")
local hash = require("cosmic.hash")
local work = require("_cli.build.work")

--- The one prefix a recipe step's failure wears; see steps.tl.
local function fail(msg: string): integer
  io.stderr:write("cosmic -c: " .. msg .. "\n")
  return 1
end

--- Per-member source closures, parsed from the facts file the recipe
--- line names (`srcdeps_<stem> := a.tl b.tl`). The facts stay the one
--- source of truth for closures; this step reads them rather than
--- re-deriving imports.
--- @param facts string Path to the facts file (o/project.mk)
--- @return {string: {string}} | nil Closures by stem, or nil on failure
--- @return string? Error message on failure
local function read_srcdeps(facts: string): {string: {string}} | nil, string
  local body = fs.read(facts)
  if not (body is string) then
    return nil, "cannot read facts file: " .. facts
  end
  local map: {string: {string}} = {}
  for line in body:gmatch("[^\n]+") do
    local stem, list = line:match("^srcdeps_(%S+) := ?(.*)$")
    if stem then
      local deps: {string} = {}
      for p in list:gmatch("%S+") do
        deps[#deps + 1] = p
      end
      map[stem] = deps
    end
  end
  return map
end

--- Verify-or-compile one member, mirroring the per-file step exactly:
--- same skip key, same restamp on a hit, same record on a fresh
--- compile.
--- @param src string The member source
--- @param outdir string The group's output directory
--- @param include_flags {string} The `--include-dir DIR` pairs
--- @param tool_stamps {string} Tool stamp paths, in line order
--- @param srcdeps {string: {string}} Closures by stem
--- @return integer Exit code for this member
--- @return boolean True when the member skipped rather than compiled
local function do_member(src: string, outdir: string, include_flags: {string},
    tool_stamps: {string}, srcdeps: {string: {string}}): integer, boolean
  local base = (fs.basename(src):gsub("%.tl$", ""))
  local out = outdir .. "/" .. base .. ".lua"
  local stem = (src:gsub("%.tl$", ""))
  local label: {string} = {"compile", src, out}
  for _, flag in ipairs(include_flags) do
    label[#label + 1] = flag
  end
  local inputs: {string} = {src}
  for _, d in ipairs(srcdeps[stem] or {}) do
    inputs[#inputs + 1] = d
  end
  for _, s in ipairs(tool_stamps) do
    inputs[#inputs + 1] = s
  end
  local key = work.inkey(label, inputs)
  local record_path = out .. ".in"
  if key is string then
    local rin, rout = work.recorded(record_path)
    if rin == key then
      local body = fs.read(out)
      if body is string and hash.sha256_hex(body) == rout then
        local ok, terr = fs.touch(out)
        if ok then
          return 0, true
        end
        io.stderr:write("restamp " .. out .. " failed: " ..
          (terr or "unknown error") .. "\n")
      end
    end
  end
  local code = work.compile_in_process(src, out, include_flags)
  if code == 0 and key is string then
    local body = fs.read(out)
    if body is string then
      local _ok, _err = fs.write(record_path, "in " .. key .. "\nout " ..
        hash.sha256_hex(body) .. "\n")
    end
  end
  return code, false
end

--- compile-batch <bootstrap> <stamp> <outdir> [--include-dir DIR]...
---   [--stamp FILE]... --facts FILE --srcs <src...> [--deps <paths...>]
--- The bootstrap names the toolchain for the line's record; the deps
--- tail rides the line for the fence and for make and is not read
--- here — per-member closures come from the facts file.
--- @param args {string} The verb's arguments
--- @return integer Exit code
local function compile_batch(args: {string}): integer
  local stamp_out, outdir = args[2], args[3]
  if not outdir then
    return fail("usage: compile-batch <bootstrap> <stamp> <outdir>"
      .. " [flags...] --facts <file> --srcs <src...> [--deps <path>...]")
  end
  local include_flags: {string} = {}
  local tool_stamps: {string} = {}
  local facts: string = nil
  local srcs: {string} = {}
  local mode = "flags"
  local i = 4
  while i <= #args do
    local a = args[i]
    if a == "--srcs" then
      mode = "srcs"
    elseif a == "--deps" then
      mode = "deps"
    elseif mode == "flags" and a == "--include-dir" and args[i + 1] then
      include_flags[#include_flags + 1] = a
      include_flags[#include_flags + 1] = args[i + 1]
      i = i + 1
    elseif mode == "flags" and a == "--stamp" and args[i + 1] then
      tool_stamps[#tool_stamps + 1] = args[i + 1]
      i = i + 1
    elseif mode == "flags" and a == "--facts" and args[i + 1] then
      facts = args[i + 1]
      i = i + 1
    elseif mode == "flags" then
      return fail("compile-batch: unrecognized flag '" .. a .. "'")
    elseif mode == "srcs" then
      srcs[#srcs + 1] = a
    end
    i = i + 1
  end
  if #srcs == 0 then
    return fail("compile-batch: no --srcs")
  end
  if not facts then
    return fail("compile-batch: no --facts")
  end
  local srcdeps, derr = read_srcdeps(facts)
  if not srcdeps then
    return fail("compile-batch: " .. tostring(derr))
  end
  local fail_fast = env.get_or("COSMIC_FAIL_FAST", "") ~= ""
  local compiled, skipped, failed = 0, 0, 0
  for _, src in ipairs(srcs) do
    local code, hit = do_member(src, outdir, include_flags, tool_stamps, srcdeps)
    if code ~= 0 then
      failed = failed + 1
      if fail_fast then
        break
      end
    elseif hit then
      skipped = skipped + 1
    else
      compiled = compiled + 1
    end
  end
  if failed > 0 then
    return fail(string.format("compile-batch: %d of %d failed", failed, #srcs))
  end
  local _ok, _err = fs.make_dirs(fs.dirname(stamp_out))
  local wok, werr = fs.write(stamp_out, string.format(
      "compiled %d skipped %d of %d\n", compiled, skipped, #srcs))
  if not wok then
    return fail("write " .. stamp_out .. " failed: "
      .. (werr or "unknown error"))
  end
  return 0
end

local record BatchModule
  compile_batch: function(args: {string}): integer
end

local M: BatchModule = {
  compile_batch = compile_batch,
}

return M
