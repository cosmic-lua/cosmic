local BuildPaths = require("cosmic_ci.build_paths")
local Clock = require("cosmic.clock")
local Fixture = require("cosmic_ci.fixture")
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
    "COSMIC_FIXTURE_PRODUCT",
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

-- The tree boots with any cosmic as its bootstrap: bin/zig runs
-- build/zig.tl on the release ci/cosmic-driver.pin names, or on
-- `COSMIC_BOOTSTRAP`. The product is itself such a cosmic, so it can
-- drive the boot of the tree it was booted from -- the next pin, proved
-- before it is one -- and a boot it drives, from another path, must write
-- the product again, byte for byte, but for the one row that names the path
-- it was built from ([`built_from`]), which is that path. The zig caches are the candidate's,
-- and every C file compiles from a copy there, the same from every path
-- (build.zig's `Own`), so none of it compiles again: only the tree does.
local boot_timeout_ns <const> = Clock.seconds(450)

--- `product` as a tool built from the tree at `tree`, which it runs a file of: the product is built from the checkout
--- CI booted it in, and a file of a copy of that tree at another path is run by a tool built from that copy or it
--- reads the tree as a project. Written under `tmp`; answers its path.
local function built_from(product: string, tree: string, tmp: string): string
  local path = tmp .. "/cosmic"
  Fixture.retargeted(product, path, assert(sys.realpath(tree)), 0x1ed)
  return path
end

local function test_the_product_boots_its_own_tree_to_itself(tmp: string)
  local product = Fixture.required("COSMIC_FIXTURE_PRODUCT") .. "/cosmic"
  local tree = tmp .. "/tree"
  local diagnostics = tmp .. "/logs"
  Fixture.mkdir(diagnostics)
  -- The tree the product was booted from (COSMIC_FIXTURE_SOURCE).
  Fixture.source_tree(tree)

  Fixture.succeeded("self-driven-boot", Fixture.call_with_environment(
    "self-driven-boot", { tree .. "/bin/zig", "build", "boot", "-Dboot-cores=all" }, tree,
    diagnostics, Fixture.environment({
      COSMIC_BOOTSTRAP = product,
      COSMIC_PORTABLE_CACHE = tmp .. "/portable-cache",
    }), boot_timeout_ns))
  local written = BuildPaths.directory(tree) .. "/bin/cosmic"
  local made = Fixture.meta(written, tmp .. "/written.db")
  assert(made["built_from"] == assert(sys.realpath(tree)), "the tool a boot wrote is built from another path")
  -- The same tool but for the path it was built from: the prefix, the modules, their bytecode and every other row.
  assert(Fixture.stripped(written, tmp .. "/stripped.db") == Fixture.stripped(product, tmp .. "/stripped.db"),
    "the tool a boot the product drove wrote is not the product but for the path it was built from")
end

--- The caller prepares terminals before confinement; no policy grants
--- device ioctls to workers for this fixture's convenience. Exercise the
--- real candidate core from this unsandboxed driver fixture instead.
local function test_the_product_prepares_and_restores_terminals(tmp: string)
  local product = Fixture.required("COSMIC_FIXTURE_PRODUCT") .. "/cosmic"
  local source = Fixture.required("COSMIC_FIXTURE_SOURCE")
  local diagnostics = tmp .. "/logs"
  Fixture.mkdir(diagnostics)
  local outcome = Fixture.call_with_environment("pty-bindings",
    { built_from(product, source, tmp), source .. "/test/terminal/pty.tl", "bindings" }, tmp, diagnostics,
    Fixture.environment(), Clock.seconds(30))
  local captured = Fixture.succeeded("pty-bindings", outcome)
  local out = Fixture.read(captured.out)
  assert(out:find("pty: PASS", 1, true), out)
end

--- `cosmic sandbox` on a terminal runs its program through the pty relay
--- (build/term_relay.tl): the real candidate core, driven from this
--- unsandboxed fixture as a user's terminal would, since no worker holds a
--- pty and the sandbox's own start. test/terminal/relay.tl checks that an
--- allowed sequence passes, OSC 52 does not, the window size and the keys
--- reach the program, its status is the verb's, and the caller's termios
--- is restored; and, for a policy with `connect` on a terminal, that the
--- relay's decision line reaches it as a line of its own (CR LF, the relay
--- not holding the terminal), which is skipped, with a line saying so,
--- where the host gives the program no network of its own.
local function test_the_product_relays_a_sandboxed_terminal(tmp: string)
  local product = Fixture.required("COSMIC_FIXTURE_PRODUCT") .. "/cosmic"
  local source = Fixture.required("COSMIC_FIXTURE_SOURCE")
  local diagnostics = tmp .. "/logs"
  Fixture.mkdir(diagnostics)
  local outcome = Fixture.call_with_environment("pty-relay",
    { built_from(product, source, tmp), source .. "/test/terminal/relay.tl" }, tmp, diagnostics,
    Fixture.environment(), Clock.seconds(120))
  local captured = Fixture.succeeded("pty-relay", outcome)
  local out = Fixture.read(captured.out)
  assert(out:find("relay: PASS", 1, true), out)
end
