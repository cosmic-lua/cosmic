--- Gate under the binary the tree builds, by building it.
---
--- A project that defines the `cosmic` namespace BUILDS ITS OWN
--- TOOLCHAIN, and every gate result is a statement about a toolchain.
--- Run `check` under the pinned release and it type-checks with the
--- release's checker; run `fmt` under it and it formats with the
--- release's formatter -- so a formatter fix passes its own gate. That
--- was a three-step incantation in the docs (`build`, `build`, `ci`),
--- a page defending it, and the same mistake made twice inside the
--- change that introduced it.
---
--- So the tool does it. A gate verb in such a project builds first,
--- and if the artifact it produced is not the binary running, re-execs
--- into it with the original argv. The loop terminates because the
--- build is content-addressed: `--make build` replaces `o/bin/<name>`
--- only when its bytes change, so "did this change anything" is a
--- question the filesystem already answers. Two generations is the
--- cap; a third means the build is not a fixpoint, which is a loud
--- failure rather than a spin.
---
--- Precedent: GNU make re-execs itself when a makefile it included was
--- rebuilt, and rustc's stage0/1/2 is the same shape one level up.
---
--- What it is NOT: a general "rebuild before every verb". An ordinary
--- project's artifact is not the tool that gates it, so there is
--- nothing to converge to and this does nothing at all.

local child = require("cosmic.child")
local env = require("cosmic.env")
local fs = require("cosmic.fs")
local fs_types = require("cosmic.fs.types")
local proc = require("cosmic.proc")
local project = require("_make.project")
local types = require("_make.types")
local validate = require("_make.validate")

local type Binary = types.Binary
local type Project = types.Project

--- The generation counter, carried across the re-exec.
local GEN_ENV < const > = "COSMIC_MAKE_GEN"

--- How many times a run may re-exec into what it built.
---
--- Two. The first covers "you invoked the pin"; the second covers "the
--- pin's build differed from the tree's own". A third would mean the
--- build never reaches a fixpoint, and spinning on that is strictly
--- worse than saying so.
local MAX_GEN < const > = 2

--- The namespace a project must define to be a cosmic.
local TOOLCHAIN < const > = "cosmic"

--- The binary this project builds that would replace the running tool,
--- or nil when it builds none.
---
--- Two things have to be true at once, and neither alone is enough: the
--- project defines `cosmic/**` outright -- the same claim the artifact
--- staging uses to drop the base's standard library -- AND it builds a
--- binary called `cosmic`. A project that merely has a `main.tl` is not
--- a toolchain, and a project that vendors a `cosmic/` package without
--- shipping a cosmic is not one either. Rebuilding either before a gate
--- would be a rule nobody asked for.
--- @param proj Project The scanned project
--- @return Binary|nil The binary that would replace the running tool
local function toolchain_of(proj: Project): Binary | nil
  if not validate.claims(proj)[TOOLCHAIN] then
    return nil
  end
  for _, b in ipairs(proj.binaries) do
    if b.name == TOOLCHAIN then
      return b
    end
  end
  return nil
end

--- Whether two paths name the same file.
--- @param a string A path
--- @param b string Another path
--- @return boolean Whether they resolve to one file
local function same_file(a: string, b: string): boolean
  return fs.abspath(a) == fs.abspath(b)
end

--- A file's identity, cheaply: size and mtime, or "" when absent.
---
--- The artifact is replaced in place, so its PATH never answers "did
--- the build change anything" -- and `--make build` replaces it only
--- when the bytes differ, which makes size and mtime exactly that
--- question.
--- @param path string The artifact
--- @return string A stamp that moves when the file does
local function stamp_of(path: string): string
  local info = fs.stat(path)
  if not info then
    return ""
  end
  local st = info as fs_types.Stat -- cast: mixed-representation Stat
  local secs = st:mtim()
  return tostring(st:size()) .. "-" .. tostring(secs)
end

--- Build, then re-exec into the result when it is not what is running.
---
--- Returns only when the caller should carry on in this process: the
--- re-exec does not come back. `false` plus a message is a refusal the
--- caller turns into a verdict.
--- @param proj Project The scanned project
--- @param argv {string} The original `--make` argv, replayed verbatim
--- @param self string Absolute path to the running binary
--- @return boolean Whether to continue in this process
--- @return string The refusal, when it is false
local function to_the_tree(proj: Project, argv: {string},
    self: string): boolean, string
  local tool = toolchain_of(proj)
  if not (tool is Binary) then
    return true
  end
  local built = fs.join(project.BUILD_DIR, "bin",
    (tool as Binary).name) -- cast: record union after the guard
  local gen = math.tointeger(tonumber(env.get(GEN_ENV, "0")) or 0) or 0
  if gen >= MAX_GEN then
    return false, "make: build is not a fixpoint: " .. built ..
    " still changed after " .. MAX_GEN .. " generations"
  end

  local was_us = fs.isfile(built) and same_file(built, self)
  local before = stamp_of(built)
  local r, rerr = child.run({self, "--make", "build"},
    {stdout = "inherit", stderr = "inherit"})
  if not (r is child.Result) then
    return false, "make: " .. (rerr or "the converging build failed")
  end
  -- cast: narrowing does not survive the early-exit guard above
  if not (r as child.Result).ok then
    return false, "make: the converging build failed"
  end
  if not fs.isfile(built) then
    return false, "make: " .. built .. ": the build produced no artifact"
  end
  -- Running the artifact, and the build left it alone: this IS the
  -- fixpoint. `--make build` replaces it only when the bytes change,
  -- so an unmoved stamp is the convergence test, free.
  if was_us and stamp_of(built) == before then
    return true
  end

  local replay: {string} = {fs.abspath(built), "--make"}
  for _, a in ipairs(argv) do
    replay[#replay + 1] = a
  end
  env.set(GEN_ENV, tostring(gen + 1))
  io.write("make: gating under " .. built .. "\n")
  local _, eerr = proc.execvp(replay[1], replay)
  return false, "make: cannot re-exec " .. replay[1] .. ": " ..
  (eerr or "unknown error")
end

local record ConvergeModule
  GEN_ENV: string
  MAX_GEN: integer
  toolchain_of: function(proj: Project): Binary | nil
  to_the_tree: function(proj: Project, argv: {string},
  self: string): boolean, string
end

local M: ConvergeModule = {
  GEN_ENV = GEN_ENV,
  MAX_GEN = MAX_GEN,
  toolchain_of = toolchain_of,
  to_the_tree = to_the_tree,
}

return M
