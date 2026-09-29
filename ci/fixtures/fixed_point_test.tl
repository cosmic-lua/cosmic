local Fixture = require("cosmic_ci.fixture")

-- A rebuild from a fresh tree compiles all of it (about 20 s on a
-- runner), and one whose compiler moved compiles it again on
-- re-entry; the driver bounds each test here (orchestration.tl).
local rebuild_timeout_ms <const> = 150000

local function count_occurrences(text: string, needle: string): integer
  local count = 0
  local at = 1
  while true do
    local from = text:find(needle, at, true)
    if from == nil then break end
    count = count + 1
    at = from + #needle
  end
  return count
end

-- The fixed point of the self-rebuild. The tool a boot wrote (the
-- product) is made stale by `edit` of `file` and rebuilt, then made stale
-- again by undoing it and rebuilt once more. The result must be the
-- product again, byte for byte (prefix, database and all). The second
-- rebuild is done by a tool the first built, so this holds only when a
-- tool built by a rebuild compiles and writes what a boot does.
-- `settles` is whether `file` is in the writer's identity (`build.work`'s
-- `writer_modules`) or the compiler's (`compiler_modules`): then each
-- rebuilt tool finds its database built by other code than its own and
-- builds it again once (`build.reboot`). Outside both, neither does.
local function run_fixed_point_case(tmp: string, name: string, file: string,
    edit: function(string): string, settles: boolean)
  local product = Fixture.required("COSMIC_FIXTURE_PRODUCT") .. "/cosmic"
  local case_root = tmp .. "/case-fixed-point-" .. name
  local tree = case_root .. "/tree"
  local diagnostics = case_root .. "/logs"
  Fixture.mkdir(diagnostics)
  -- The tree the product was booted from (COSMIC_FIXTURE_SOURCE).
  Fixture.source_tree(tree)
  local program = tree .. "/o/bin/cosmic"
  Fixture.mkdir(tree .. "/o/bin")
  Fixture.copy(product, program, 0x1ed)
  local booted = Fixture.hash(product)

  local path = tree .. "/" .. file
  local original = Fixture.read(path)
  local values = Fixture.environment({
    COSMIC_PORTABLE_CACHE = case_root .. "/cache" })
  for _, stage in ipairs({ "edited", "undone" }) do
    if stage == "edited" then
      local edited = edit(original)
      assert(edited ~= original, name .. ": the edit changed nothing")
      Fixture.write(path, edited)
    else
      Fixture.write(path, original)
    end
    local outcome = Fixture.call_with_environment("fixed-point-" .. name ..
      "-" .. stage, { program, "docs", "cosmic.child" }, tree, diagnostics,
      values, rebuild_timeout_ms)
    assert(outcome.result.code == 0, name .. ": " .. stage ..
      ": exit status was " .. tostring(outcome.result.code) .. ", want 0")
    local err = Fixture.read(outcome.err)
    local stale_lines = count_occurrences(err,
      "the tool is stale; rebuilding it from the tree")
    assert(stale_lines == 1, name .. ": " .. stage .. ": reported " ..
      tostring(stale_lines) .. " stale-rebuild lines, want 1")
    local settled_lines = count_occurrences(err,
      "the tool's database was built by other code than its own; building it again")
    local want = settles and 1 or 0
    assert(settled_lines == want, name .. ": " .. stage .. ": built its " ..
      "database again " .. tostring(settled_lines) .. " times, want " ..
      tostring(want))
  end
  assert(Fixture.hash(program) == booted, name .. ": the tool two " ..
    "self-rebuilds left is not the tool the boot wrote")
end

-- A comment appended to a module's source.
local function commented(source: string): string
  return source .. "-- a fixed-point fixture\n"
end

-- `build.positions` is in neither identity, though build.writer
-- reaches it (through build.importer, which the writer's identity
-- leaves out): the stale tool's compiler and writer are the tree's, and
-- each rebuild is final.
local function test_a_self_rebuild_lands_on_the_booted_tool(tmp: string)
  run_fixed_point_case(tmp, "outside", "build/positions.tl", commented, false)
end

-- `build.clock` is in the writer's identity and not the compiler's.
local function test_a_rebuilt_writer_lands_on_the_booted_tool(tmp: string)
  run_fixed_point_case(tmp, "writer", "build/clock.tl", commented, true)
end

-- `build.contracts` is in the compiler's identity (`build.work`'s
-- `compiler_roots`) and not the writer's: each rebuilt tool compiles
-- the whole tree again with its own compiler.
local function test_a_rebuilt_compiler_lands_on_the_booted_tool(tmp: string)
  run_fixed_point_case(tmp, "compiler", "build/contracts.tl", commented, true)
end

-- An edit to how the compiler's identity is defined (`build.work`'s
-- `compiler_identity`): the stale tool records the tree's identity by
-- its own, older definition, so the tool it writes carries a name its
-- own code does not give the tree. Settling, that tool keys its compiles
-- by the identity its own code takes (`build.reboot`'s `into`), which is
-- what the tool it writes carries, so each stage settles once. Keyed by
-- the carried name instead, the settled tool would be unsettled still,
-- and refuse (exit 3).
local function test_a_redefined_compiler_lands_on_the_booted_tool(tmp: string)
  run_fixed_point_case(tmp, "identity", "build/work.tl", function(source: string): string
    return (source:gsub('"build%.teal", "build%.tree",\n',
      '"build.teal", "build.tree", "build.clock",\n', 1))
  end, true)
end

-- An edit to what the tool's fingerprint covers (`build.work`'s
-- `tool_files`): the stale tool records the tree's fingerprint by its
-- own, older definition, so the tool it writes is stale by its own
-- code, and builds itself again once (`build.reboot`) rather than
-- refusing as still stale after a reboot.
local function test_a_rebuilt_fingerprint_lands_on_the_booted_tool(tmp: string)
  run_fixed_point_case(tmp, "fingerprint", "build/work.tl", function(source: string): string
    return (source:gsub('(%["build%.zig%.zon"%] = true,\n)', '%1  ["README.md"] = true,\n', 1))
  end, true)
end

-- One commit that moves both what the fingerprint covers and how the
-- compiler's identity is defined. The tool the stale tool writes is
-- stale by its own code and carries the identity the older definition
-- takes. Settling on the "teal" path, it carries the tree's code
-- (`build.reboot`'s `carries_tree_code`), so it keys its compiles, and
-- signs what it writes, by the identities its own code takes, and the
-- tool it writes is settled: each stage rebuilds once and settles once.
-- Keyed by the carried names, it would be unsettled still, and refuse
-- (exit 3).
local function test_a_redefined_fingerprint_and_compiler_land_on_the_booted_tool(tmp: string)
  run_fixed_point_case(tmp, "fingerprint-identity", "build/work.tl", function(source: string): string
    local covered, files = source:gsub('(%["build%.zig%.zon"%] = true,\n)',
      '%1  ["README.md"] = true,\n', 1)
    assert(files == 1, "fingerprint-identity: tool_files' build.zig.zon line was not found")
    local redefined, roots = covered:gsub('"build%.teal", "build%.tree",\n',
      '"build.teal", "build.tree", "build.clock",\n', 1)
    assert(roots == 1, "fingerprint-identity: compiler_roots' last line was not found")
    return redefined
  end, true)
end
