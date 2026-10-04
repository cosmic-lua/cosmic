local Clock = require("cosmic.clock")
local Fixture = require("cosmic_ci.fixture")

local Test = require("cosmic.test")

--- Run unsandboxed and sharing nothing (cosmic_ci/orchestration.tl's
--- `fixture`), its workers are given the environment they declare:
--- all of it, which says where the candidate and its products are
--- (COSMIC_FIXTURE_*) and where the host's toolchain is. A release that
--- keys every unsandboxed run by declaration gives a worker only that.
Test.needs{ env = { "*" } }

-- The tree boots with any cosmic as its bootstrap: bin/zig runs
-- build/zig.tl on the release ci/cosmic-driver.pin names, or on
-- `COSMIC_BOOTSTRAP`. The product is itself such a cosmic, so it can
-- drive the boot of the tree it was booted from -- the next pin, proved
-- before it is one -- and a boot it drives, from another path, must write
-- the product again, byte for byte. The zig caches are the candidate's,
-- and every C file compiles from a copy there, the same from every path
-- (build.zig's `Own`), so none of it compiles again: only the tree does.
local boot_timeout_ns <const> = Clock.seconds(450)

local function test_the_product_boots_its_own_tree_to_itself(tmp: string)
  local product = Fixture.required("COSMIC_FIXTURE_PRODUCT") .. "/cosmic"
  local tree = tmp .. "/tree"
  local diagnostics = tmp .. "/logs"
  Fixture.mkdir(diagnostics)
  -- The tree the product was booted from (COSMIC_FIXTURE_SOURCE).
  Fixture.source_tree(tree)

  Fixture.succeeded("self-driven-boot", Fixture.call_with_environment(
    "self-driven-boot", { tree .. "/bin/zig", "build", "boot" }, tree,
    diagnostics, Fixture.environment({
      COSMIC_BOOTSTRAP = product,
      COSMIC_PORTABLE_CACHE = tmp .. "/portable-cache",
    }), boot_timeout_ns))
  assert(Fixture.hash(tree .. "/o/bin/cosmic") == Fixture.hash(product),
    "the tool a boot the product drove wrote is not the product")
end
