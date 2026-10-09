--- End to end: an unsandboxed run keys each verdict by its test's
--- declared inputs, as a sandboxed run does (build/declared_key.tl),
--- though nothing holds a worker to them. macOS, which has no sandbox,
--- trusts what CI's Linux legs enforce.
---
--- An unenforced verdict stands until what its test declares changes:
--- on a run again, and in another checkout at the same path through a
--- cache COSMIC_VERDICT_CACHE names, never through the one every
--- sandboxed checkout shares by default. It stands in no checkout
--- elsewhere, since its worker sees the tree where it is, not at /tree
--- as a sandboxed one does. Its worker is given the environment its key
--- holds and no more, and the store of its closure. Neither a sandboxed
--- verdict nor an unenforced one stands for the other.
---
--- Every run here is unsandboxed by COSMIC_TEST_SANDBOX=0, so every host
--- runs these, whether or not it can sandbox a worker; the case that
--- starts a sandboxed run is in `declared_sandboxed_test.tl`.

local Fs = require("cosmic.fs")
local build_paths = require("build.paths")
local fixture = require("build.declared_unenforced_fixture")
local Test = require("cosmic.test")

--- What a run of `cosmic test` needs of the host, and the program it
--- runs.
Test.policy{
  profiles = { "cosmic" },
  grants = { { path = "o/bin", letters = "rx" } },
}

--- The summary of an unenforced run that shares through the file
--- COSMIC_VERDICT_CACHE names, and of one that names none.
local UNENFORCED <const> = "; unsandboxed (COSMIC_TEST_SANDBOX=0), keyed by declared inputs)"
local UNSHARED <const> =
  "; unsandboxed (COSMIC_TEST_SANDBOX=0), keyed by declared inputs, sharing no verdicts)"

local checkout, environment, says = fixture.checkout, fixture.environment, fixture.says

--- Runs `cosmic test` on `root`, answering its exit status and what it
--- printed, which must say it started.
--- Moves the checkout at `from` to `to` with its build directory, as a
--- checkout that kept its build in it moved: what is left at `from` is
--- no checkout, and a new one made there is another.
local function move(from: string, to: string, env: {string:string})
  local built = build_paths.required(from, env)
  assert(Fs.rename(from, to))
  assert(Fs.rename(built, build_paths.required(to, env)))
end

local function run(root: string, output: string, env: {string:string}): integer, string
  local ran = fixture.run(root, output, env)
  return ran.code, ran.text
end

--- Its verdicts stand on a run again -- the scratch directory each
--- worker is given, new every run, is no part of their keys -- and in
--- another checkout of the same content at the same path, on the
--- verdicts the first reached; the summary says how the run was keyed;
--- and each worker was given only the variables its key holds.
local function test_an_unenforced_verdict_stands_again_and_in_another_checkout(tmp: string)
  local env = environment(tmp .. "/cache/verdicts.db")
  checkout(tmp .. "/first")
  -- Each worker attaches the store of its module's closure, as a
  -- sandbox gives it one, which its key holds by its bytes.
  local first = says(tmp .. "/first", tmp .. "/first.out", env, "2 ran, 0 stood")
  assert(first:find("test: declared: 2 closure stores written", 1, true), first)
  says(tmp .. "/first", tmp .. "/again.out", env, "0 ran, 2 stood")
  -- Another checkout where the first was, which has none of the
  -- first's own verdicts: it stands on those it shared.
  move(tmp .. "/first", tmp .. "/moved", env)
  checkout(tmp .. "/first")
  local second = says(tmp .. "/first", tmp .. "/second.out", env,
    "0 ran, 2 stood, 2 of them on another checkout's verdict")
  assert(second:find(UNENFORCED, 1, true), second)
end

--- A checkout of the same content elsewhere stands on none of them: an
--- unsandboxed worker sees the tree where it is, and a test's verdict
--- may turn on that path -- here, on its length -- so its key holds it,
--- as a sandboxed key need not, whose worker sees the tree at /tree
--- wherever it is.
local function test_an_unenforced_verdict_stands_in_no_checkout_elsewhere(tmp: string)
  local env = environment(tmp .. "/cache/verdicts.db")
  local function placed(root: string)
    checkout(root)
    assert(Fs.write(root .. "/suite/place_test.tl", string.format([[
local sys = require("cosmic.sys")

local function test_where_the_tree_is()
  assert(#assert(sys.getcwd()) == %d, "the tree moved")
end
]], #assert(Fs.absolute(root)))))
  end
  placed(tmp .. "/first")
  says(tmp .. "/first", tmp .. "/first.out", env, "3 ran, 0 stood")
  -- The same content at a longer path: each of its tests runs again,
  -- and the one that turns on where the tree is fails there, as it
  -- would have had its verdict not stood.
  assert(Fs.mkdirs(tmp .. "/elsewhere"))
  assert(Fs.rename(tmp .. "/first", tmp .. "/elsewhere/first"))
  local code, text = run(tmp .. "/elsewhere/first", tmp .. "/elsewhere.out", env)
  assert(code ~= 0, text)
  assert(text:find("1 of 3 failed", 1, true) and text:find("the tree moved", 1, true), text)
end

--- A file beneath a declared directory that changes runs the test that
--- declares it, and it alone.
local function test_an_edit_to_what_a_test_declares_runs_it(tmp: string)
  local env = environment(tmp .. "/cache/verdicts.db")
  checkout(tmp .. "/root")
  says(tmp .. "/root", tmp .. "/first.out", env, "2 ran, 0 stood")
  assert(Fs.write(tmp .. "/root/suite/data/f", "two\n"))
  says(tmp .. "/root", tmp .. "/edited.out", env, "1 ran, 1 stood")
end

--- Where COSMIC_VERDICT_CACHE names no file, it shares nothing: it
--- neither makes nor reads the cache every sandboxed checkout shares by
--- default, so another checkout at the same path runs every test again,
--- and the summary says so.
local function test_an_unenforced_run_shares_only_through_a_named_cache(tmp: string)
  local env = environment("")
  env.COSMIC_VERDICT_CACHE = nil
  env.XDG_CACHE_HOME = tmp .. "/xdg"
  checkout(tmp .. "/first")
  local first = says(tmp .. "/first", tmp .. "/first.out", env, "2 ran, 0 stood")
  assert(first:find(UNSHARED, 1, true), first)
  says(tmp .. "/first", tmp .. "/again.out", env, "0 ran, 2 stood")
  move(tmp .. "/first", tmp .. "/moved", env)
  checkout(tmp .. "/first")
  says(tmp .. "/first", tmp .. "/second.out", env, "2 ran, 0 stood")
  assert(Fs.stat(tmp .. "/xdg/cosmic/verdicts/verdicts.db") == nil,
    "it made the shared cache every checkout reads by default")
end

--- Its worker attaches the store of its module's closure, not the
--- tree's projection in its build directory: the database it holds open
--- is under the build directory's stores/. The store names nothing of
--- where it is, so the case reads the worker's descriptors from /proc
--- instead -- where there is one: macOS has none, and a Linux leg checks it.
local function test_an_unenforced_worker_attaches_its_closure_store(tmp: string)
  local env = environment(tmp .. "/cache/verdicts.db")
  local root = tmp .. "/root"
  checkout(root)
  assert(Fs.write(root .. "/suite/store_test.tl", [[
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local sys = require("cosmic.sys")

local function test_the_store_it_attached()
  local listed = Fs.list("/proc/self/fd")
  if listed == nil then return end
  -- The tree's build directory, named as build/paths.tl names it, under
  -- the base the runner gives a worker, where it resolves.
  local named = assert(Env.get("COSMIC_BUILD_HOME")) .. "/" .. Hash.hex_sha256((assert(sys.realpath("."))))
  local built = (assert(sys.realpath(named)))
  local attached: {string} = {}
  for _, fd in ipairs(listed) do
    local link = Fs.readlink("/proc/self/fd/" .. fd)
    if link ~= nil and Fs.within(link, built) and link:sub(-3) == ".db" then
      attached[#attached + 1] = link
    end
  end
  assert(#attached > 0, "it holds no database of the tree open")
  for _, link in ipairs(attached) do
    assert(Fs.within(link, built .. "/stores"), "it attached " .. link)
  end
end
]]))
  says(root, tmp .. "/first.out", env, "3 ran, 0 stood")
end
