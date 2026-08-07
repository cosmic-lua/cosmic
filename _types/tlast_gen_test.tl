#!/usr/bin/env cosmic
-- The tl AST cache generator: parse the pinned tl's embedded d.tl
-- sources, serialize, dump bytecode. The artifact-side thaw is pinned
-- by cosmic/_teal_ast_test.tl; this covers the generator itself —
-- that it produces a loadable, deterministic cache whose thawed
-- programs a fresh tl instance accepts as parser output.

local check = require("cosmic.check")
local fs = require("cosmic.fs")
local tlast_gen = require("_types.tlast_gen")

local tmpdir = check.must(os.getenv("TEST_TMPDIR"), "TEST_TMPDIR should be set")

-- Generation succeeds against the fetched pin and is deterministic:
-- the repro lane byte-compares whole artifacts, so two runs must
-- produce identical bytes.
local function test_generates_deterministic_cache()
  local dir_a = fs.join(tmpdir, "gen-a")
  local dir_b = fs.join(tmpdir, "gen-b")
  check.must(fs.make_dirs(dir_a))
  check.must(fs.make_dirs(dir_b))
  assert(tlast_gen.generate(dir_a) == nil, "generate should succeed")
  assert(tlast_gen.generate(dir_b) == nil, "second generate should succeed")
  local cache_a = check.must(fs.read(fs.join(dir_a, "tl_ast.luac")))
  local cache_b = check.must(fs.read(fs.join(dir_b, "tl_ast.luac")))
  assert(#cache_a > 0, "cache should not be empty")
  assert(cache_a == cache_b, "two generations should be byte-identical")
  -- write-if-changed: regenerating over an existing identical cache
  -- succeeds without complaint
  assert(tlast_gen.generate(dir_a) == nil, "regenerate over identical cache")
end
test_generates_deterministic_cache()

-- The cache thaws against a fresh, private tl instance (not the
-- running binary's): programs come back table-shaped, and the stdlib
-- program has the top-level statements the checker will walk. Using a
-- fresh instance proves the cache pairs with the pinned bytes it was
-- generated from, not with whatever tl this test process has loaded.
local function test_cache_thaws_on_fresh_tl()
  local dir = fs.join(tmpdir, "gen-thaw")
  check.must(fs.make_dirs(dir))
  assert(tlast_gen.generate(dir) == nil, "generate should succeed")
  local bytecode = check.must(fs.read(fs.join(dir, "tl_ast.luac")))
  local tl_body = check.must(fs.read("o/3p/tl/tl.lua"),
    "pinned tl should be fetched")
  local tl_chunk = check.must(load(tl_body, "@o/3p/tl/tl.lua"))
  local fresh_tl = tl_chunk() as {string: any} -- cast: freshly loaded module surface
  local hooks = check.must(fresh_tl["ast_hooks"], "patched tl exposes ast_hooks")
  local chunk = check.must(load(bytecode, "=.tl_ast", "b"))
  local thaw = chunk()
  assert(type(thaw) == "function", "cache chunk should return the thaw function")
  -- cast: the chunk's contract, guarded as a function above
  local thaw_fn = thaw as function(any): (any, any)
  local prelude_ast, stdlib_ast = thaw_fn(hooks)
  assert(type(prelude_ast) == "table", "prelude program should be a table")
  assert(type(stdlib_ast) == "table", "stdlib program should be a table")
  assert(#(stdlib_ast as {any}) > 0, -- cast: array view of a statement list
    "stdlib program should have top-level statements")
end
test_cache_thaws_on_fresh_tl()
