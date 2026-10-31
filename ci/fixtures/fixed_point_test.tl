local BuildPaths = require("cosmic_ci.build_paths")
local Clock = require("cosmic.clock")
local Fixture = require("cosmic_ci.fixture")
local Maps = require("cosmic_ci.maps")
local sys = require("cosmic.sys")

local Test = require("cosmic.test")

--- Run unsandboxed and sharing nothing (cosmic_ci/orchestration.tl's
--- `fixture`), its worker is given the variables it names: what the
--- driver says where the candidate and its products are
--- (COSMIC_FIXTURE_*) and what the children it starts read
--- ([`Fixture.inherited`], which each of them hands on and no more, and
--- which cosmic_ci/orchestration_test.tl holds this list to). It
--- declares `tool`, as [`BuildPaths.directory`] starts the running
--- program on the candidate's build/paths.tl, whose modules a worker run
--- on its closure alone would lack.
Test.policy{
  profiles = { "cosmic" },
  grants = { { path = "o/bin", letters = "rx" } },
  env = {
    "COSMIC_FIXTURE_COMPILES",
    "COSMIC_FIXTURE_PRODUCT",
    "COSMIC_FIXTURE_SHARED_COMPILES",
    "COSMIC_FIXTURE_SOURCE",
    "PATH",
    "HOME",
    "XDG_CACHE_HOME",
    "TMPDIR",
    "COSMIC_PORTABLE_CACHE",
    "COSMIC_VERDICT_CACHE",
    "COSMIC_AUTO_BOOT",
    "COSMIC_TEST_SANDBOX",
    "COSMIC_SANDBOX",
    "COSMIC_TEST_HELD",
    "COSMIC_BOOTSTRAP", "COSMIC_BUILD_HOME",
    "COSMIC_ZIG",
    "COSMIC_ZIG_CACHE",
    "COSMIC_ZIG_GLOBAL_CACHE",
    "ZIG_LIB_DIR",
    "ZIG_GLOBAL_CACHE_DIR",
    "ZIG_LOCAL_CACHE_DIR",
    "SDKROOT",
    "DEVELOPER_DIR",
    "COSMIC_TEST_TIMEOUT",
    "FUZZ_ITERS",
    "MACOSX_DEPLOYMENT_TARGET",
    "COSMIC_BOOTSTRAP_ATTEMPTS",
    "COSMIC_BOOTSTRAP_VERIFY",
    "SSL_CERT_FILE",
    "SSL_CERT_DIR",
    "CURL_CA_BUNDLE",
    "ALL_PROXY",
    "HTTPS_PROXY",
    "HTTP_PROXY",
    "NO_PROXY",
    "all_proxy",
    "https_proxy",
    "http_proxy",
    "no_proxy",
  },
}

-- What one stage's `docs` may take: the rebuild, the settling rebuild
-- where the case settles, and the command they re-enter. A compiler
-- case's stage compiles the whole tree cold once, in its settle; the
-- build.plans case's settles parse every source again too. On a four-core
-- x86-64 host with an every-core product the longest stage, that case's
-- edited one, took 137 s beside the file's other tests (a seeded rebuild
-- of 25 s, a settle of 109 s): about 185 s on the slowest leg
-- (orchestration.tl's `fixed_point_test_timeout_ns` scales it), and this
-- keeps 1.6 times that. A sharing case's stage takes far less. The driver
-- bounds each test and the file (orchestration.tl's
-- `fixed_point_test_timeout_ns`).
local stage_timeout_ns <const> = Clock.seconds(300)

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

--- What one rebuild said it compiled and took back, in the order the
--- rebuilds ran: build.reboot's "rebuilt the tool in ... (N modules
--- compiled, M cached)".
local record Rebuild
  compiled: integer
  cached: integer
end

local function rebuilds_in(err: string): {Rebuild}
  local found: mut {Rebuild} = {}
  for compiled, cached in err:gmatch("rebuilt the tool in [%d.]+ s %((%d+) modules? compiled, (%d+) cached%)") do
    found[#found + 1] = { compiled = assert(math.tointeger(tonumber(compiled))),
      cached = assert(math.tointeger(tonumber(cached))) }
  end
  return found
end

--- A copy of the leg's compiles (COSMIC_FIXTURE_COMPILES, orchestration.tl's
--- `seed_compiles`) for one case's edited stage to take back
--- (COSMIC_BUILD_CACHE), in a directory of its own and 0700, since
--- build/shared_compiles.tl's `open` refuses a file in a directory another
--- user could write, as a umask of 002 leaves the case's.
local function seeded_compiles(case_root: string): string
  local dir = case_root .. "/compiles"
  assert(sys.mkdir(dir, 0x1c0))
  local path = dir .. "/cache.db"
  Fixture.copy(Fixture.required("COSMIC_FIXTURE_COMPILES"), path, 0x180)
  return path
end

-- The fixed point of the self-rebuild. The tool a boot wrote (the
-- product) is made stale by `edit` of `file` and rebuilt, then made stale
-- again by undoing it and rebuilt once more. The result must be the
-- product again, byte for byte (prefix, database and all) but for the row
-- that names the tree it is built from, which is the case's. The second
-- rebuild is done by a tool the first built, so this holds only when a
-- tool built by a rebuild compiles and writes what a boot does.
-- `settles` is whether `file` is in the writer's identity (`build.identity`'s
-- `writer_modules`) or the compiler's (`compiler_modules`): then each
-- rebuilt tool finds its database built by other code than its own and
-- builds it again once (`build.reboot`). Outside both, neither does.
--
-- `shares` is whether the case's rebuilds share compiles and parses with
-- the group's other sharing cases, through one file the driver names
-- afresh for each run (COSMIC_FIXTURE_SHARED_COMPILES) and nothing else
-- reads; otherwise they share none ([`Fixture.environment`]). A shared
-- row is keyed by the module's key, which holds the compiler's identity,
-- the module's source and its imports' keys (build/shared_compiles.tl),
-- so a rebuild takes a row only where it would compile the same
-- sources under the same compiler's identity, and every row was
-- compiled cold in this run by another case's rebuild. Only a case whose
-- subject is the rebuild's way, not what a compiler compiles, shares:
-- see [`test_a_rebuilt_compiler_lands_on_the_booted_tool`] for why those
-- cases' settles compile cold. A case that shares none takes the leg's
-- compiles (COSMIC_FIXTURE_COMPILES, [`seeded_compiles`]) in its edited
-- stage alone, where the product rebuilds: those are the boot's compiles,
-- made under the product's compiler identity, so the rebuild takes back
-- what it would compile again identically, as any rebuild in a booted
-- checkout does, and compiles only what the edit moves; the settle after
-- it finds no row under the edited compiler's identity. Its undone stage
-- shares nothing, so its settle compiles the whole tree cold under the
-- product's identity: each settle must take nothing back, and the
-- seeded rebuild more than it compiles.
local function run_fixed_point_case(tmp: string, name: string, file: string,
                                    edit: function(string): string, settles: boolean,
                                    shares: boolean)
  local product = Fixture.required("COSMIC_FIXTURE_PRODUCT") .. "/cosmic"
  local case_root = tmp .. "/case-fixed-point-" .. name
  local tree = case_root .. "/tree"
  local diagnostics = case_root .. "/logs"
  Fixture.mkdir(diagnostics)
  -- The tree the product was booted from (COSMIC_FIXTURE_SOURCE).
  Fixture.source_tree(tree)
  local program = BuildPaths.directory(tree) .. "/bin/cosmic"
  Fixture.mkdir(BuildPaths.directory(tree) .. "/bin")
  -- The product was booted in the checkout the driver built in: put in this copy, it is the tool a boot here
  -- would have written, built from this copy.
  Fixture.retargeted(product, program, assert(sys.realpath(tree)), 0x1ed)
  local booted = Fixture.stripped(product, case_root .. "/booted.db")

  local path = tree .. "/" .. file
  local original = Fixture.read(path)
  local base = Fixture.environment({
    COSMIC_PORTABLE_CACHE = case_root .. "/cache" })
  local shared = base
  if shares then
    shared = Maps.with(base, { COSMIC_BUILD_CACHE = Fixture.required("COSMIC_FIXTURE_SHARED_COMPILES") })
  end
  for _, stage in ipairs({ "edited", "undone" }) do
    local values = shared
    if stage == "edited" then
      local edited = edit(original)
      assert(edited ~= original, name .. ": the edit changed nothing")
      Fixture.write(path, edited)
      if not shares then
        values = Maps.with(base, { COSMIC_BUILD_CACHE = seeded_compiles(case_root) })
      end
    else
      Fixture.write(path, original)
    end
    local outcome = Fixture.call_with_environment("fixed-point-" .. name ..
        "-" .. stage, { program, "docs", "cosmic.child" }, tree, diagnostics,
      values, stage_timeout_ns)
    assert(outcome.result.code == 0, name .. ": " .. stage ..
        ": exit status was " .. tostring(outcome.result.code) .. ", want 0")
    local err = Fixture.read(outcome.err)
    local stale_lines = count_occurrences(err,
      "the tool is stale; rebuilding it from the tree")
    assert(stale_lines == 1, name .. ": " .. stage .. ": reported " ..
        tostring(stale_lines) .. " stale-rebuild lines, want 1")
    local settled_lines = count_occurrences(err,
      "the tool's database was built by other code than its own; building it again")
    local want = if settles then 1 else 0 end
    assert(settled_lines == want, name .. ": " .. stage .. ": built its " ..
        "database again " .. tostring(settled_lines) .. " times, want " ..
        tostring(want))
    if not shares then
      local made = rebuilds_in(err)
      assert(#made == 1 + want, name .. ": " .. stage .. ": reported " ..
          tostring(#made) .. " rebuilds, want " .. tostring(1 + want))
      local first = assert(made[1])
      if stage == "edited" then
        assert(first.cached > first.compiled, name .. ": edited: the rebuild took back " ..
            tostring(first.cached) .. " compiles of the leg's and made " .. tostring(first.compiled))
      end
      local settle = assert(made[#made])
      if settles then
        assert(settle.cached == 0, name .. ": " .. stage .. ": the settle took back " ..
            tostring(settle.cached) .. " compiles, want none")
      end
    end
  end
  assert(Fixture.meta(program, case_root .. "/rebuilt.db")["built_from"] == assert(sys.realpath(tree)),
    name .. ": the tool two self-rebuilds left is built from another path")
  assert(Fixture.stripped(program, case_root .. "/rebuilt.db") == booted, name .. ": the tool two " ..
      "self-rebuilds left is not the tool the boot wrote")
end

-- A comment appended to a module's source.
local function commented(source: string): string
  return source .. "-- a fixed-point fixture\n"
end

-- The runner starts a file's tests in the order they are declared, as
-- many at once as it has workers. The first case that shares compiles
-- (`outside`) fills the group's file; one that starts after it ends
-- takes the tree's compiles back and compiles only what its own edit
-- moves, while one that starts beside it compiles cold. So `outside` is
-- declared among the compiler cases, which take about twice as long,
-- and the other sharing cases after them: on three or four workers each
-- of those starts once `outside` has ended.

-- `build.plans` is in the compiler's identity (`build.identity`'s
-- `compiler_roots`) and not the writer's: each rebuilt tool compiles
-- the whole tree again with its own compiler.
--
-- This case and the two that redefine the compiler's identity share no
-- compiles with another case, and their settles take none back: what
-- they check is what a compiler compiles. (The edited stage's first
-- rebuild takes the leg's, the product's own: [`run_fixed_point_case`].)
-- The undone
-- stage ends on a tool whose compiler the edited compiler compiled,
-- compiling the whole tree again under the identity of the product's
-- compiler, and the product must come of it byte for byte. A sharing
-- case compiles the same sources under that same identity, so its rows
-- would stand in for that whole compile, and nothing the twice-rebuilt
-- compiler compiled would be checked. Nor would the second of the two
-- that redefine the identity alike compile under the redefined identity
-- what the first already had.
local function test_a_rebuilt_compiler_lands_on_the_booted_tool(tmp: string)
  run_fixed_point_case(tmp, "compiler", "build/plans.tl", commented, true, false)
end

-- `build.positions` is in neither identity, though build.writer
-- reaches it (through build.importer, which the writer's identity
-- leaves out): the stale tool's compiler and writer are the tree's, and
-- each rebuild is final.
local function test_a_self_rebuild_lands_on_the_booted_tool(tmp: string)
  run_fixed_point_case(tmp, "outside", "build/positions.tl", commented, false, true)
end

-- An edit to how the compiler's identity is defined (`build.identity`'s
-- `compiler_identity`): the stale tool records the tree's identity by
-- its own, older definition, so the tool it writes carries a name its
-- own code does not give the tree. Settling, that tool keys its compiles
-- by the identity its own code takes (`build.reboot`'s `into`), which is
-- what the tool it writes carries, so each stage settles once. Keyed by
-- the carried name instead, the settled tool would be unsettled still,
-- and refuse (exit 3).
local function test_a_redefined_compiler_lands_on_the_booted_tool(tmp: string)
  run_fixed_point_case(tmp, "identity", "build/identity.tl", function(source: string): string
    return (source:gsub('"build%.tree", "build%.withheld",\n',
      '"build.tree", "build.withheld", "build.clock",\n', 1))
  end, true, false)
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
  run_fixed_point_case(tmp, "fingerprint-identity", "build/identity.tl", function(source: string): string
    local covered, files = source:gsub('(%["build%.zig%.zon"%] = true,\n)',
      '%1  ["README.md"] = true,\n', 1)
    assert(files == 1, "fingerprint-identity: tool_files' build.zig.zon line was not found")
    local redefined, roots = covered:gsub('"build%.tree", "build%.withheld",\n',
      '"build.tree", "build.withheld", "build.clock",\n', 1)
    assert(roots == 1, "fingerprint-identity: compiler_roots' last line was not found")
    return redefined
  end, true, false)
end

-- Staging, scans and transaction history do not define projection bytes.
local function test_a_staging_edit_needs_no_settling(tmp: string)
  run_fixed_point_case(tmp, "staging", "build/work.tl", commented, false, true)
end

-- `build.clock` is in the writer's identity and not the compiler's.
local function test_a_rebuilt_writer_lands_on_the_booted_tool(tmp: string)
  run_fixed_point_case(tmp, "writer", "build/clock.tl", commented, true, true)
end

-- An edit to what the tool's fingerprint covers (`build.identity`'s
-- `tool_files`): the stale tool records the tree's fingerprint by its
-- own, older definition, so the tool it writes is stale by its own
-- code, and builds itself again once (`build.reboot`) rather than
-- refusing as still stale after a reboot.
local function test_a_rebuilt_fingerprint_lands_on_the_booted_tool(tmp: string)
  run_fixed_point_case(tmp, "fingerprint", "build/identity.tl", function(source: string): string
    return (source:gsub('(%["build%.zig%.zon"%] = true,\n)', '%1  ["README.md"] = true,\n', 1))
  end, true, true)
end
