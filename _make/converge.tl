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
local proc = require("cosmic.proc")
local help = require("_make.help")
local project = require("_make.project")
local types = require("_make.types")
local validate = require("_make.validate")

local type Binary = types.Binary
local type Project = types.Project

--- Verbs whose ANSWER depends on the toolchain, so a project that
--- builds its own gates under what it built.
---
--- Everything that reads or judges the tree. Not `build` (it is how
--- you get the toolchain), not `clean` (it removes it), not `fetch`
--- (it provisions), not `help`.
local GATES < const >: {string: boolean} = {
  fmt = true,
  check = true,
  test = true,
  example = true,
  benchmark = true,
  lint = true,
  coverage = true,
  docs = true,
  ci = true,
}

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

--- The line `--make help` prints that nothing else does. Content, not
--- exit status, is what tells an engine from a look-alike. Read from
--- `_make.help`, the one place `usage()` composes it, rather than kept
--- as a second copy here that could drift from what `--make help`
--- actually prints (help.tl does not import converge.tl, so this
--- direction adds no cycle).
local PROBE_MARK < const > = help.PROBE_MARK

--- How long the probe waits for that answer. The candidate is an
--- arbitrary user binary, so the probe is bounded rather than trusting.
local PROBE_MS < const > = 10000

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
---
--- NANOSECONDS included, both returns of `mtim()`. Whole seconds would
--- read a rebuild that changed bytes without changing size, inside one
--- second, as a fixpoint -- and then the gate runs stale, which is the
--- precise failure this exists to close.
--- @param path string The artifact
--- @return string A stamp that moves when the file does
local function stamp_of(path: string): string
  local info = fs.stat(path)
  if not info then
    return ""
  end
  local st = info as fs.Stat -- cast: record union after guard
  local secs, nsecs = st:mtim()
  return tostring(st:size()) .. "-" .. tostring(secs) .. "." ..
  tostring(nsecs)
end

--- Can this artifact drive a build? Asked, not assumed.
---
--- The name and the namespace are what a project DECLARES; this is
--- what the binary can DO. A user project may innocently define
--- `cosmic/init.tl` and build a `cmd/cosmic/main.tl` -- and then every
--- gate re-exec'd into their own binary, which knows nothing about
--- `--make`, and died with a raw traceback. All gates, permanently
--- broken, for a project that did nothing wrong.
---
--- `--make help` is the probe because it is the one verb that answers
--- before a project is opened: no build, no chdir, no side effect.
---
--- The answer is graded on CONTENT, not on exit status. Exiting 0 on
--- unrecognised argv is an ordinary CLI shape -- printing usage and
--- succeeding is what many mains do, and the fixture in this file's own
--- tests is a `print(...)` main that does exactly that. Accept exit 0
--- and such a binary gets re-exec'd with the whole gate argv, prints
--- something, exits 0, and the gate REPORTS SUCCESS having run nothing:
--- strictly worse than the traceback this replaced, because a traceback
--- is at least visible. So the probe requires the line only this
--- engine's usage emits.
---
--- And it is bounded. A candidate is an arbitrary user binary; one that
--- reads stdin would hang every gate verb forever, after a single
--- `make: root=…` line and no other sign. An empty `stdin` so a reader
--- gets EOF rather than the terminal, and a wait timeout so one that
--- ignores EOF still loses. Output is captured (the default), because a
--- look-alike's usage text is not this run's output.
--- @param path string The candidate artifact
--- @return boolean Whether it answers as a cosmic engine
local function drives_a_build(path: string): boolean
  local h, serr = child.spawn({path, "--make", "help"}, {stdin = ""})
  if not (h is child.Handle) then
    local _ = serr
    return false
  end
  local r = (h as child.Handle):wait(PROBE_MS) -- cast: after guard
  if not (r is child.Result) then
    (h as child.Handle):kill() -- cast: after guard
    return false
  end
  local res = r as child.Result -- cast: after guard
  return res.ok and (res.stdout or ""):find(PROBE_MARK, 1, true) ~= nil
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
--- @return string A short verdict detail naming WHICH refusal
local function to_the_tree(proj: Project, argv: {string},
    self: string): boolean, string, string
  local tool = toolchain_of(proj)
  if not (tool is Binary) then
    return true
  end
  local built = fs.join(project.BUILD_DIR, "bin",
    (tool as Binary).name) -- cast: record union after the guard
  local gen = math.tointeger(tonumber(env.get_or(GEN_ENV, "0")) or 0) or 0

  local was_us = fs.isfile(built) and same_file(built, self)
  local before = stamp_of(built)
  local r = child.run({self, "--make", "build"},
    {stdout = "inherit", stderr = "inherit"})
  if not r.ok then
    return false, "make: " ..
    (r.spawn_error or "the converging build failed"), "build failed"
  end
  if not fs.isfile(built) then
    return false, "make: " .. built .. ": the build produced no artifact",
    "no artifact"
  end
  -- Running the artifact, and the build left it alone: this IS the
  -- fixpoint. `--make build` replaces it only when the bytes change,
  -- so an unmoved stamp is the convergence test, free. Checked BEFORE
  -- the generation cap: already being the answer is not a failure to
  -- reach it.
  if was_us and stamp_of(built) == before then
    env.unset(GEN_ENV)
    return true
  end
  if gen >= MAX_GEN then
    return false, "make: build is not a fixpoint: " .. built ..
    " still changed after " .. MAX_GEN .. " generations", "not a fixpoint"
  end
  -- What the project DECLARES made this look like a toolchain; this is
  -- what the binary can DO. They disagree for a project that innocently
  -- defines `cosmic/init.tl` and builds a `cmd/cosmic/main.tl` -- and
  -- the right answer for that project is to CARRY ON, not to refuse.
  --
  -- Refusing was the bug wearing a better name: every gate verb paid a
  -- full build and then failed, permanently, for a project whose only
  -- mistake was two ordinary names. There is nothing to converge to
  -- here, which is the same situation as any non-toolchain project --
  -- and there the gate simply runs. The running engine is a perfectly
  -- good judge of a project that is not a toolchain.
  --
  -- Said once, on stderr, because it explains a `--make build` the user
  -- did not ask for.
  if not drives_a_build(built) then
    io.stderr:write("make: " .. built .. " is not a cosmic engine " ..
      "(it does not answer `--make help`); gating under this one\n")
    env.unset(GEN_ENV)
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
  (eerr or "unknown error"), "re-exec failed"
end

local record ConvergeModule
  GATES: {string: boolean}
  GEN_ENV: string
  MAX_GEN: integer
  toolchain_of: function(proj: Project): Binary | nil
  drives_a_build: function(path: string): boolean
  to_the_tree: function(proj: Project, argv: {string},
  self: string): boolean, string, string
end

local M: ConvergeModule = {
  GATES = GATES,
  drives_a_build = drives_a_build,
  GEN_ENV = GEN_ENV,
  MAX_GEN = MAX_GEN,
  toolchain_of = toolchain_of,
  to_the_tree = to_the_tree,
}

return M
