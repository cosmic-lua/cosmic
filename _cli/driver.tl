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

--- @param verb string The verb name
--- @param args {string} Its arguments
--- @return string|nil Error message when an enforceable fence failed
local function fence(verb: string, args: {string}): string | nil
  if not fence_enabled() then
    return nil
  end
  local fs_policy = grants.plan(verb, args)
  if fs_policy == nil then
    return nil
  end
  local ok, err = sandbox.apply({fs = fs_policy, best_effort = true})
  if not ok then
    return "fence for '" .. verb .. "' failed: " .. (err or "unknown error")
  end
  return nil
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
      local ferr = fence(verb, args)
      if ferr ~= nil then
        io.stderr:write("cosmic -c: " .. ferr .. "\n")
        return 1
      end
      return b.dispatch(verb, args)
    end)
end

local record DriverModule
  recipe: function(line: string): integer
end

local M: DriverModule = {
  recipe = recipe,
}

return M
