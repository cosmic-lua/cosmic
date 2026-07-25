--- Build-driver entry points, shared by `--build <mode>` and `-c`.
---
--- Both run cosmic.build, and both arm line coverage the way the script
--- path does: a driver run in the coverage lane must still report
--- cosmic.build's lines, or every recipe step it executes reads as
--- dead code. cosmic.build is required inside the call rather than at
--- module load, so a cosmic that never runs a recipe never loads it.

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

--- `--build <mode> <args>...`: one recipe step, named directly.
--- @param mode string The mode name
--- @param argv {string} The mode's arguments
--- @return integer Exit code
local function build(mode: string, argv: {string}): integer
  return with_coverage(function(): integer
      return require("cosmic.build").main(mode, table.unpack(argv))
    end)
end

--- `-c '<line>'`: one recipe line from make, run as argv (`SHELL :=
--- cosmic`).
--- @param line string The recipe line
--- @return integer Exit code
local function recipe(line: string): integer
  return with_coverage(function(): integer
      return require("cosmic.build").recipe(line)
    end)
end

local record DriverModule
  build: function(mode: string, argv: {string}): integer
  recipe: function(line: string): integer
end

return {build = build, recipe = recipe} as DriverModule -- cast: table to module record
