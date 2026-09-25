local Fixture = require("cosmic_ci.fixture")

-- The tree boots with any cosmic as its bootstrap: bin/zig runs
-- build/zig.tl on the release ci/cosmic-driver.pin names, or on
-- `COSMIC_BOOTSTRAP`. The product is itself such a cosmic, so it can
-- drive the boot of the tree it was booted from -- the next pin, proved
-- before it is one -- and a boot it drives, from another path, must write
-- the product again, byte for byte. The zig caches are the candidate's,
-- so only the core's own C, keyed by its path, compiles again.
local boot_timeout_ms <const> = 450000

local function test_the_product_boots_its_own_tree_to_itself(tmp: string)
  local root = Fixture.required("COSMIC_FIXTURE_ROOT")
  local product = Fixture.required("COSMIC_FIXTURE_PRODUCT") .. "/cosmic"
  local tree = tmp .. "/tree"
  local diagnostics = tmp .. "/logs"
  Fixture.mkdir(diagnostics)
  Fixture.mkdir(tree)
  Fixture.run("git-archive", { "/bin/sh", "-c",
    "git -C \"$1\" archive HEAD | tar -xf - -C \"$2\"", "sh", root, tree },
    root, diagnostics)

  Fixture.succeeded("self-driven-boot", Fixture.call_with_environment(
    "self-driven-boot", { tree .. "/bin/zig", "build", "boot" }, tree,
    diagnostics, Fixture.environment({
      COSMIC_BOOTSTRAP = product,
      COSMIC_PORTABLE_CACHE = tmp .. "/portable-cache",
    }), boot_timeout_ms))
  assert(Fixture.hash(tree .. "/o/bin/cosmic") == Fixture.hash(product),
    "the tool a boot the product drove wrote is not the product")
end
