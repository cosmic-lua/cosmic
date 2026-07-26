--- Examples for the cosmic.script_cache module.
--- Compiled `.tl` output, keyed by path + content + build id. Two
--- functions and no error returns: a cache that can fail its caller is
--- not a cache, so a miss and a failure look the same on purpose.

-- Example_store_and_load demonstrates the round trip. store() takes the
-- SOURCE path and the compiled code; load() takes the source path alone
-- and returns what was stored for that exact content.
local function Example_store_and_load()
  local script_cache = require("cosmic.script_cache")
  local fs = require("cosmic.fs")
  local env = require("cosmic.env")
  local tmp = os.getenv("TEST_TMPDIR") or "/tmp"
  env.set("COSMIC_TL_CACHE_DIR", fs.join(tmp, "cache-roundtrip"))

  local src = fs.join(tmp, "greet.tl")
  fs.write(src, "return function(): string return 'hi' end\n")

  print(script_cache.load(src))
  script_cache.store(src, "return function() return 'hi' end\n")
  print(script_cache.load(src))
  -- Output:
  -- nil
  -- return function() return 'hi' end
end

-- Example_content_keyed demonstrates the invalidation rule: the key is
-- the content, not the mtime, so editing the source is a miss and no
-- filesystem timestamp granularity can produce a stale hit.
local function Example_content_keyed()
  local script_cache = require("cosmic.script_cache")
  local fs = require("cosmic.fs")
  local env = require("cosmic.env")
  local tmp = os.getenv("TEST_TMPDIR") or "/tmp"
  env.set("COSMIC_TL_CACHE_DIR", fs.join(tmp, "cache-keyed"))

  local src = fs.join(tmp, "edited.tl")
  fs.write(src, "return 1\n")
  script_cache.store(src, "return 1\n")
  print(script_cache.load(src) ~= nil)

  fs.write(src, "return 2\n")
  print(script_cache.load(src))
  -- Output:
  -- true
  -- nil
end

-- Example_best_effort demonstrates the contract: a source that cannot
-- be read has no key, so there is nothing to look up and nothing to
-- store. Neither call raises, and neither reports — the caller compiles.
local function Example_best_effort()
  local script_cache = require("cosmic.script_cache")
  local fs = require("cosmic.fs")
  local env = require("cosmic.env")
  local tmp = os.getenv("TEST_TMPDIR") or "/tmp"
  env.set("COSMIC_TL_CACHE_DIR", fs.join(tmp, "cache-besteffort"))

  local missing = fs.join(tmp, "no-such-file.tl")
  script_cache.store(missing, "return 0\n")
  print(script_cache.load(missing))
  -- Output:
  -- nil
end

-- Suppress unused warnings for examples
local _ = {Example_store_and_load, Example_content_keyed, Example_best_effort}
