#!/usr/bin/env cosmic
-- ast-grep ignore: test file needs package.path manipulation
local path = require("cosmo.path")

-- Where the pinned tl landed. `cosmic --make fetch` unpacks a pin beside
-- the pin, so the tarball lands whole in this unit's output directory;
-- the Makefile's fetch pipeline stages elsewhere and names it in
-- TEST_DIR, and that arm goes with the Makefile.
--
-- It has to come from the environment or a known path, never a bare
-- `global TEST_DIR`: cosmic injects only _G.arg, so a global reads nil
-- and the prepend below silently resolves the BINARY's embedded tl
-- instead of the staged source this test exists to exercise.
local TEST_DIR = os.getenv("TEST_DIR") or "o/3p/tl"

-- Prepend before requiring, or the embedded tl wins.
package.path = path.join(TEST_DIR, "?.lua") .. ";" .. package.path
local tl = require("tl")

local function test_load_tl()
  assert(tl ~= nil, "failed to load tl")
  assert(type(tl.loader) == "function", "tl.loader should be a function")
  assert(type(tl.generate) == "function", "tl.generate should be a function")
end

local function test_parse_simple()
  local result = tl.process_string("local x: number = 1", false, nil, "test.tl")
  assert(result ~= nil, "tl.process_string should return a result")
  assert(result.syntax_errors == nil or #result.syntax_errors == 0, "should have no syntax errors")
end

-- Canary for the 5.4 codegen target: tl.generate's second argument is
-- the target STRING — an options table was once passed here instead,
-- silently regressing every compile to the non-5.4 default, which
-- rejects 5.4-only syntax like <close> attributes  This
-- fails if the target ever stops being honored.
local function test_generate_emits_close_attribute()
  local result = tl.process_string(
    "local x <close> = setmetatable({}, {__close = function() end})\n",
    true, nil, "close_canary.tl")
  assert(result.syntax_errors == nil or #result.syntax_errors == 0,
    "canary snippet should parse")
  local code = tl.generate(result.ast, "5.4")
  assert(code and code:find("<close>", 1, true),
    "5.4 target must emit the <close> attribute")
end

-- The for_control_var carried patch: Lua 5.5 makes the FIRST variable
-- of either `for` form const, so a body that reassigns one compiles to
-- Lua that 5.4 runs and 5.5 refuses to LOAD. The patch shadows such a
-- variable with a plain local. These cases pin both halves of that
-- behaviour -- that the shadow appears when it is needed, and that it
-- does NOT appear when it is not, since an unmarked loop must generate
-- byte-identical output to an unpatched compiler.
local function generate_lua(src: string, chunkname: string): string
  local result = tl.process_string(src, true, nil, chunkname)
  assert(result.syntax_errors == nil or #result.syntax_errors == 0,
    chunkname .. " should parse")
  local code = tl.generate(result.ast, "5.4")
  assert(code, chunkname .. " should generate")
  return code
end

local function test_fornum_reassigned_control_var_is_shadowed()
  local code = generate_lua("for i = 1, 3 do i = i + 1 end\n", "fornum_write.tl")
  assert(code:find("local i = i", 1, true),
    "a reassigned numeric-for control variable must be shadowed, got: " .. code)
end

local function test_fornum_untouched_control_var_is_not_shadowed()
  local code = generate_lua("for i = 1, 3 do print(i) end\n", "fornum_read.tl")
  assert(not code:find("local i = i", 1, true),
    "a numeric-for that never reassigns must emit stock output, got: " .. code)
end

local function test_forin_reassigned_first_var_is_shadowed()
  local code = generate_lua(
    "for k in pairs({ a = 1 }) do k = k .. \"!\" end\n", "forin_write.tl")
  assert(code:find("local k = k", 1, true),
    "a reassigned generic-for first variable must be shadowed, got: " .. code)
end

local function test_forin_later_var_is_not_shadowed()
  -- Only the FIRST variable is const on 5.5; a later one stays an
  -- ordinary local, so shadowing it would be gratuitous divergence.
  local code = generate_lua(
    "for _, v in ipairs({ \"x\" }) do v = v .. \"!\" end\n", "forin_later.tl")
  assert(not code:find("local v = v", 1, true),
    "a generic-for's later variable must not be shadowed, got: " .. code)
end

local function test_shadowed_loops_still_compute_the_same_result()
  -- The shadow must be semantically inert on 5.4: same answer as the
  -- unshadowed form this compiler used to emit.
  local code = generate_lua(
    "local s = 0\n" ..
    "for i = 1, 3 do i = i + 1 s = s + i end\n" ..
    "for k in pairs({ a = 1 }) do k = k .. \"!\" s = s + #k end\n" ..
    "return s\n", "for_semantics.tl")
  local chunk, err = load(code, "=for_semantics", "t")
  assert(chunk, "shadowed output must load: " .. tostring(err))
  local ok, value = pcall(chunk)
  assert(ok, "shadowed output must run: " .. tostring(value))
  assert(value == 11, "expected 11 (2+3+4 numeric, +2 for \"a!\"), got " ..
    tostring(value))
end
