--- The build-driver entry point behind `-c`:
--- fence the step, then run it.
---
--- The fence is DERIVED, never declared. Because the recipe vocabulary
--- is closed, every verb's signature already says what it touches —
--- `copy <src> <dst>` reads src and writes dst, `compile <bootstrap>
--- <src> <out>` execs the first, reads the second, writes the third.
--- The shapes table below is that knowledge, and it is the whole
--- grant: a rule cannot over-declare its way out of the fence, because
--- a rule declares nothing. (An earlier design carried grants in
--- target-specific make variables, `COSMIC_UNVEIL = $^`; the closed
--- vocabulary made that channel redundant.)
---
--- It also arms line coverage the way the script path does: a driver
--- run in the coverage lane must still report _cli.build's lines, or
--- every recipe step it executes reads as dead code.

local env = require("cosmic.env")
local fs = require("cosmic.fs")
local proc = require("cosmic.proc")
local grants = require("_cli.grants")
local sandbox = require("cosmic.sandbox")

--- Apply the derived fence.
---
--- best_effort, because `unveil()` no-ops without Landlock: a host that
--- cannot enforce runs unfenced rather than refusing to build, the same
--- posture the make rules take, with CI's enforce lane as the proof it
--- is live where it counts. A host that CAN enforce but fails to is a
--- different thing entirely — that is a fence that silently is not
--- there, so it fails the step loudly instead.
--- ON. `COSMIC_FENCE=0` turns it off.
---
--- It shipped off, because the first attempt turned three lanes red at
--- once: the derivation was right about the arguments and silent about
--- everything else a process needs — the APE loader, `/dev/urandom`,
--- the paths a child's own argv names. Those are the floor, and the
--- floor is here now.
---
--- Default-on is the whole point of the design. The Makefile's
--- per-rule `.PLEDGE`/`.UNVEIL` are gone; between that and this the
--- project had a build nothing sandboxed, and a fence nobody turns on
--- is a fence. Off-by-default also cannot be tested honestly: the only
--- runs that exercised it were the ones that asked for it.
---
--- Costless where it cannot work: `unveil()` no-ops without Landlock,
--- so on a host that cannot enforce this changes nothing. A host that
--- CAN enforce and fails to apply the policy is the loud case — that
--- is a fence that silently is not there.
--- @return boolean
local function fence_enabled(): boolean
  return os.getenv("COSMIC_FENCE") ~= "0"
end

--- Seed the ape loaders $HOME holds into the scratch dir, atomically.
---
--- A NESTED driver -- one a fenced test spawns -- cannot read $HOME to
--- discover a loader there (the outer fence grants no such read), so
--- its own plan would omit the grant and its spawns would die ENOEXEC.
--- The outer driver runs this BEFORE it fences, while $HOME is still
--- readable: with the loader standing in the scratch, every
--- descendant's $TMPDIR/.ape-<v> probe lands inside a directory the
--- fence already grants rw+exec. Copy via a unique name and rename, so
--- a parallel step never execs a half-written loader.
--- @param scratch string The pinned TMPDIR
local function seed_ape_loaders(scratch: string)
  local home = env.get("HOME")
  if home == nil or home == "" then
    return
  end
  local found = fs.glob(home, ".ape-*")
  if found == nil then
    return
  end
  for _, src in ipairs(found as {string}) do -- cast: nil-checked above
    local dst = fs.join(scratch, fs.basename(src))
    if fs.isfile(src) and not fs.exists(dst) then
      local bytes = fs.read(src)
      if bytes ~= nil then
        local part = dst .. ".part." .. tostring(proc.getpid())
        -- cast: read's nil checked above; 0x1ED is 0755
        if fs.write(part, bytes as string) and fs.chmod(part, 0x1ED) then
          fs.rename(part, dst)
        end
      end
    end
  end
end

--- Point an unset TMPDIR at a scratch dir under o/, before the fence.
---
--- With TMPDIR unset -- the default -- the APE extraction dir falls
--- through to $HOME, and the fence used to follow it there: every
--- fenced step got rw+exec on the entire home directory. Pin the unset
--- case under o/ instead: inside the build's own writable tree,
--- narrow, the same for every step. A caller who set TMPDIR keeps it,
--- so only the unset case changes. The loaders a process probes BEFORE
--- extracting one are granted per-file in the plan (see grants.tl);
--- this pin is where a fresh extraction and a step's scratch files go.
local function ensure_build_tmpdir()
  local t = env.get("TMPDIR")
  if t ~= nil and t ~= "" then
    return
  end
  local scratch = fs.abspath(fs.join("o", "tmp"))
  if fs.makedirs(scratch) then
    seed_ape_loaders(scratch)
    env.set("TMPDIR", scratch, true)
  end
end

--- @param verb string The verb name
--- @param args {string} Its arguments
--- @return string|nil Error message when an enforceable fence failed
local function fence(verb: string, args: {string}): string | nil
  if not fence_enabled() then
    return nil
  end
  -- A policy that could not be DERIVED is an error, not an absence.
  -- Only the shapeless verb (no policy, no error) legitimately runs
  -- without a fence; anything else that came back empty failed on the
  -- way, and dispatching it here would be the one thing this gate
  -- exists to prevent -- a step running with no Landlock at all,
  -- announced as if it were fenced.
  local fs_policy, perr = grants.plan(verb, args)
  if perr ~= nil then
    return "fence for '" .. verb .. "' could not be derived: " .. perr
  end
  if fs_policy == nil then
    return nil
  end
  -- `keep_coverage`, because this policy GRANTS the coverage directory
  -- (`_cli/grants.tl` creates it and adds it to `rw`). Without saying
  -- so the mechanism seals coverage before restricting — the right
  -- default when nobody knows whether the dump will still work — and
  -- every fenced recipe then reports only the lines it ran before the
  -- fence landed. The dumps are all there and all nearly empty, which
  -- is why it read as a code regression rather than a lost measurement.
  local enforced, err = sandbox.apply({
      fs = fs_policy,
      best_effort = true,
      keep_coverage = true,
    })
  if enforced is sandbox.Availability then
    -- best_effort can no longer skip silently: apply reports what it
    -- enforced. A host that cannot enforce runs unfenced by design
    -- (see above) — say so when the caller explicitly asked for the
    -- fence (COSMIC_FENCE set), and stay quiet on the implicit
    -- default, where a per-recipe warning would drown a whole build
    -- on such hosts.
    if not enforced.fs and os.getenv("COSMIC_FENCE") ~= nil then
      io.stderr:write("fence: unenforceable on this host; '"
        .. verb .. "' runs unfenced\n")
    end
    return nil
  end
  return "fence for '" .. verb .. "' failed: " .. (err or "unknown error")
end

--- Run one driver entry with line coverage armed.
--- @param run function(): integer The entry to run
--- @return integer Exit code from the entry
local function with_coverage(run: function(): integer): integer
  local cov_dump: function() = nil
  if os.getenv("COSMIC_COVERAGE") then
    cov_dump = require("cosmic.coverage").enable_from_env()
  end
  local code = run()
  if cov_dump then
    cov_dump()
  end
  return code
end

--- Say what this step is doing, in one short line.
---
--- The build runs make with `-s`, so make echoes nothing and the tool
--- owns its own progress voice. Echoing the recipe line instead costs
--- ~400 characters a step over ~370 steps -- the driver's absolute
--- path, the source, the output, `--include-dir`, the whole transitive
--- import closure, and the trailing `;` sentinel that exists only to
--- route the line through SHELL -- with the one fact a reader wants,
--- which file, buried mid-line.
---
--- Derived, not declared: the shape table the fence already uses says
--- which argument a verb WRITES, so the line is that verb and that
--- path. A verb the table does not know prints its name alone rather
--- than guessing.
--- @param verb string The recipe verb
--- @param args {string} Its arguments
local function announce(verb: string, args: {string})
  local shape = grants.shapes[verb]
  local where = ""
  if shape ~= nil then
    local at = (shape.rw and shape.rw[1]) or shape.rest_rw
    or (shape.ro and shape.ro[1])
    if at ~= nil and args[at] ~= nil then
      where = " " .. args[at]
    end
  end
  io.write(verb .. where .. "\n")
end

--- `-c '<line>'`: one recipe line from make, run as argv (`SHELL :=
--- cosmic`). Parsed first, fenced from the parse, then dispatched.
--- @param line string The recipe line
--- @return integer Exit code
local function recipe(line: string): integer
  return with_coverage(function(): integer
      local b = require("_cli.build")
      local verb, args, err = b.parse(line)
      if err ~= nil then
        io.stderr:write("cosmic -c: " .. err .. "\n")
        return 1
      end
      if verb == nil then
        return 0
      end
      ensure_build_tmpdir()
      local ferr = fence(verb, args)
      if ferr ~= nil then
        io.stderr:write("cosmic -c: " .. ferr .. "\n")
        return 1
      end
      announce(verb, args)
      return b.dispatch(verb, args)
    end)
end

local record DriverModule
  recipe: function(line: string): integer
  ensure_build_tmpdir: function()
end

local M: DriverModule = {
  recipe = recipe,
  ensure_build_tmpdir = ensure_build_tmpdir,
}

return M
