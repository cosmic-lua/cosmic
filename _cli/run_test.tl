#!/usr/bin/env cosmic
--- Tests for _cli.run -- the two user-facing error-presentation
--- helpers the CLI wraps every script in (#504, previously zero
--- coverage). Both are pure string transforms, so they are tested
--- directly rather than through a spawned binary.

local run = require("_cli.run")
local env = require("cosmic.env")

-- augment_module_errors: attach require hints to Teal's compile-time
-- "module not found" so a typo reads the same whether it was caught at
-- compile time or run time.

local function test_augment_leaves_unrelated_errors_alone()
  local err = "foo.tl:3:1: syntax error near 'end'"
  assert(run.augment_module_errors(err) == err,
    "an error without a module-not-found match must pass through verbatim")
end
test_augment_leaves_unrelated_errors_alone()

local function test_augment_appends_did_you_mean()
  local err = "s.tl:1:1: module not found: 'cosmic.fss'"
  local out = run.augment_module_errors(err)
  assert(out ~= err, "a module-not-found error should be augmented")
  assert(out:find(err, 1, true) == 1,
    "the original message must be preserved as the prefix, got: " .. out)
  assert(out:find("Did you mean?", 1, true),
    "expected a Did-you-mean block, got: " .. out)
  assert(out:find("cosmic.fs", 1, true),
    "expected the near-miss suggestion cosmic.fs, got: " .. out)
  -- The hint engine's own first two lines ("module 'x' not found" and
  -- the blank after it) are dropped -- they would duplicate the Teal
  -- error we are appending to.
  assert(not out:find("module 'cosmic.fss' not found", 1, true),
    "the hint's redundant header must be stripped, got: " .. out)
  assert(not out:match("\n\n$"), "trailing blank lines must be trimmed")
end
test_augment_appends_did_you_mean()

local function test_augment_respects_no_require_hints()
  local err = "s.tl:1:1: module not found: 'cosmic.fss'"
  env.set("COSMIC_NO_REQUIRE_HINTS", "1")
  local out = run.augment_module_errors(err)
  env.unset("COSMIC_NO_REQUIRE_HINTS")
  assert(out == err,
    "COSMIC_NO_REQUIRE_HINTS must disable augmentation, got: " .. out)
end
test_augment_respects_no_require_hints()

-- trim_traceback: hide the cosmic entry point's frames so a user sees
-- only their own stack.

local function test_trim_traceback_keeps_the_message()
  local tb = run.trim_traceback("boom")
  assert(tb:find("boom", 1, true),
    "the error message must survive trimming, got: " .. tb)
end
test_trim_traceback_keeps_the_message()

local function test_trim_traceback_accepts_non_string_errors()
  -- The parameter is `any`: a script can error() a table or a number.
  local tb = run.trim_traceback(42)
  assert(tb:find("42", 1, true), "expected the tostring'd value, got: " .. tb)
end
test_trim_traceback_accepts_non_string_errors()

--- The real contract: running under the cosmic binary, the live stack
--- passes through /zip/main.lua (the embedded entry point). Trimming
--- must cut there, and COSMIC_FULL_TRACEBACK must keep it. Comparing
--- the two in one test means this cannot pass vacuously on a host
--- where the frame happens to be absent -- if /zip/main.lua is not in
--- the untrimmed traceback there is nothing to trim, and we skip.
local function test_trim_traceback_cuts_at_the_cosmic_entry_point()
  env.set("COSMIC_FULL_TRACEBACK", "1")
  local full = run.trim_traceback("boom")
  env.unset("COSMIC_FULL_TRACEBACK")
  if not full:find("/zip/main%.lua:") then
    require("cosmic.check").skip(
      "traceback trimming: no /zip/main.lua frame in this run")
    return
  end
  local trimmed = run.trim_traceback("boom")
  assert(not trimmed:find("/zip/main%.lua:"),
    "trimmed traceback must not expose the entry point, got: " .. trimmed)
  assert(#trimmed < #full,
    "trimming must shorten the traceback: " .. #trimmed .. " vs " .. #full)
  assert(trimmed:find("boom", 1, true), "message still required after trim")
end
test_trim_traceback_cuts_at_the_cosmic_entry_point()
