local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Fuzz = require("build.fuzz")
local shrink = require("build.fuzz.shrink")

--- The report [`Fuzz.run`] raises for `p`, which must fail.
local function report(p: Fuzz.Property): string
  local ok, err = pcall(Fuzz.run, p)
  assert(not ok, "the property held")
  return tostring(err)
end

local function any_bytes(src: Fuzz.Source): string
  return Fuzz.bytes(src, 64)
end

local function test_a_property_that_holds_runs_every_iteration()
  local seen = 0
  local n = Fuzz.run({
    name = "holds",
    iters = 20,
    gen = any_bytes,
    check = function(_input: string): boolean, string
      seen = seen + 1
      return true, ""
    end,
  })
  assert(n == 20 and seen == 20, ("ran %d, checked %d"):format(n, seen))
end

-- Any byte of 200 or more fails: the simplest failing input is that one
-- byte, alone.
local function test_a_failure_is_shrunk_to_its_simplest_input()
  local err = report({
    name = "no high bytes",
    iters = 200,
    gen = any_bytes,
    check = function(input: string): boolean, string
      if input:find("[\200-\255]") then return false, "a high byte" end
      return true, ""
    end,
  })
  assert(err:find("fuzz no high bytes: seed=1 iteration=%d+: a high byte"), err)
  assert(err:find("draws and 1 byte;", 1, true), err)
  assert(err:find("input (hex): c8\n", 1, true), err)
  assert(err:find("reproduce: FUZZ_CASE=no-high-bytes:", 1, true), err)
  assert(err:find("or FUZZ_SEED=1 FUZZ_ITERS=", 1, true), err)
end

local function test_a_seed_reaches_the_same_failure_every_time()
  local function first(): string
    return report({
      name = "short",
      iters = 100,
      gen = any_bytes,
      check = function(input: string): boolean, string
        return #input < 50, "long"
      end,
    })
  end
  assert(first() == first())
end

local function test_a_raise_fails_the_property_and_names_what_it_raised()
  local err = report({
    name = "raises",
    iters = 5,
    gen = any_bytes,
    check = function(_input: string): boolean, string
      error("the parser gave up", 0)
    end,
  })
  assert(err:find("raised: the parser gave up", 1, true), err)
  assert(err:find("to 1 draw and 0 bytes;", 1, true), err)
end

-- The budget shares the VM's one hook with coverage, which `cosmic test`
-- always collects: it must hold anyway, in a coroutine the check makes
-- too, and be disarmed once the run is over.
local function test_a_check_that_never_ends_spends_its_budget()
  local err = report({
    name = "spins",
    iters = 3,
    budget = 100000,
    gen = any_bytes,
    check = function(_input: string): boolean, string
      local co = coroutine.wrap(function()
        while true do end
      end)
      co()
      return true, ""
    end,
  })
  assert(err:find("spent its budget of 100000 VM instructions", 1, true), err)
  local total = 0
  for i = 1, 300000 do total = total + i end
  assert(total > 0)
end

local function test_a_failing_input_is_kept_in_the_property_dir(tmp: string)
  local err = report({
    name = "keeps it",
    dir = tmp,
    iters = 50,
    gen = any_bytes,
    check = function(input: string): boolean, string
      return input:find("\0", 1, true) == nil, "a NUL"
    end,
  })
  local kept = tmp .. "/keeps-it.input"
  assert(err:find("kept at " .. kept, 1, true), err)
  assert(Fs.read(kept) == "\0")
  local held, why = Fuzz.replay({ name = "keeps it", gen = any_bytes,
    check = function(input: string): boolean, string
      return input:find("\0", 1, true) == nil, "a NUL"
    end }, "\0")
  assert(not held and why == "a NUL", why)
end

local function test_a_zero_budget_edit_count_leaves_the_sample()
  local src: Fuzz.Source = { int = function(_self: Fuzz.Source, min: integer, _max: integer): integer
    return min
  end }
  assert(Fuzz.mutate(src, "sample", 3) == "sample")
  assert(Fuzz.pick(src, { "a", "b" }) == "a")
  assert(Fuzz.bytes(src, 10) == "")
end

local function test_mutate_stays_deterministic_and_changes_its_sample()
  local changed = 0
  local err = report({
    name = "mutates",
    iters = 100,
    gen = function(src: Fuzz.Source): string
      return Fuzz.mutate(src, "ustar\0" .. string.rep("0", 20), 4)
    end,
    check = function(input: string): boolean, string
      if input ~= "ustar\0" .. string.rep("0", 20) then changed = changed + 1 end
      return #input < 40, "grew"
    end,
  })
  assert(changed > 0)
  assert(err:find("grew", 1, true), err)
end

-- The shrinker alone: a list of draws fails while it holds a value of 7
-- or more, so the simplest failing list is that one value, alone.
local function test_shrink_cuts_and_lowers_draws()
  local function fails(values: {integer}): boolean, {shrink.Draw}
    local used: {shrink.Draw} = {}
    local failed = false
    for i, v in ipairs(values) do
      used[i] = { min = 0, max = 100, value = v }
      if v >= 7 then failed = true end
    end
    return failed, used
  end
  local draws: {shrink.Draw} = {}
  for i, v in ipairs({ 3, 90, 2, 55, 1 }) do draws[i] = { min = 0, max = 100, value = v } end
  local shrunk = shrink.shrink(draws, fails, 1000)
  local best, tries = shrunk.draws, shrunk.tries
  assert(#best == 1 and best[1].value == 7, ("%d draws, first %d"):format(#best, best[1].value))
  assert(tries > 0 and tries <= 1000)
  local capped = shrink.shrink(draws, fails, 3).tries
  assert(capped == 3)
end

-- A costly property caps what FUZZ_ITERS may ask of it; a count the
-- property names itself stands. FUZZ_ITERS is whatever the run set: CI
-- sets 0, a deep run more than the cap.
-- TODO: under CI's FUZZ_ITERS=0 the cap is never met, so only a local or
-- nightly run checks it; once cosmic.env can set a variable for a
-- call, set FUZZ_ITERS above the cap here.
local function test_max_iters_caps_the_count_but_not_a_named_one()
  local function holds(_input: string): boolean, string return true, "" end
  local asked = math.tointeger(tonumber(Env.get_or("FUZZ_ITERS", "64"))) or 64
  local capped = Fuzz.run({ name = "capped", max_iters = 5, gen = any_bytes, check = holds })
  assert(capped == math.min(asked, 5), "ran " .. capped)
  local named = Fuzz.run({ name = "named", iters = 9, max_iters = 5, gen = any_bytes, check = holds })
  assert(named == 9, "ran " .. named)
end

-- A corpus is checked before anything is drawn: an input kept there
-- fails the run whatever the seed would draw, and one that holds is
-- checked and passed over.
local function test_a_corpus_input_is_checked_before_any_draw(tmp: string)
  local corpus = tmp .. "/corpus"
  assert(Fs.mkdirs(corpus))
  assert(Fs.write(corpus .. "/a.input", "fine"))
  assert(Fs.write(corpus .. "/README", "not an input!"))
  local checked: {string} = {}
  local function no_bang(input: string): boolean, string
    checked[#checked + 1] = input
    return input:find("!", 1, true) == nil, "a bang"
  end
  local n = Fuzz.run({ name = "corpus holds", corpus = corpus, iters = 3,
    gen = function(_src: Fuzz.Source): string return "drawn" end, check = no_bang })
  assert(n == 3 and checked[1] == "fine" and #checked == 4, ("%d checked"):format(#checked))
  assert(Fs.write(corpus .. "/b.input", "bang!"))
  local err = report({ name = "corpus fails", corpus = corpus, dir = tmp, iters = 3,
    gen = function(_src: Fuzz.Source): string return "drawn" end, check = no_bang })
  assert(Fs.read(tmp .. "/corpus-fails.input") == "bang!")
  assert(err:find("fuzz corpus fails: corpus input " .. corpus .. "/b.input: a bang", 1, true), err)
  assert(err:find("input (hex, 5 bytes): 62616e6721", 1, true), err)
end

-- A report says where to keep the shrunk input so it stays fixed: the
-- property's corpus, under a name its bytes decide.
local function test_a_report_says_how_to_keep_the_input(tmp: string)
  local err = report({
    name = "keep me",
    dir = tmp,
    iters = 50,
    gen = any_bytes,
    check = function(input: string): boolean, string
      return input:find("\0", 1, true) == nil, "a NUL"
    end,
  })
  assert(err:find("mkdir -p testdata/fuzz/keep-me && cp " .. tmp .. "/keep-me.input " ..
    "testdata/fuzz/keep-me/6e340b9cffb37a98.input", 1, true), err)
end

-- Labels count what the drawn inputs reached; a required label no input
-- reached fails the run, and one some input reached lets it pass. The
-- kept input is removed on that failure, since it is no failing input.
local function test_a_required_label_no_input_reached_fails_the_run(tmp: string)
  local function check(input: string): boolean, string
    Fuzz.label("checked")
    if #input > 1000 then Fuzz.label("long") end
    return true, ""
  end
  local n = Fuzz.run({ name = "labelled", iters = 64, gen = any_bytes, check = check,
    requires = { "checked" } })
  assert(n == 64)
  local err = report({ name = "never long", dir = tmp, iters = 64, gen = any_bytes, check = check,
    requires = { "checked", "long" } })
  assert(err == 'fuzz never long: seed=1: no input of 64 reached "long", which the ' ..
    "property requires: its inputs do not exercise what it is meant to", err)
  assert(not Fs.exists(tmp .. "/never-long.input"))
end

-- A label the property requires a share of fails a run in which fewer
-- inputs reached it, though some did, and passes one in which enough did.
local function test_a_label_under_its_required_share_fails_the_run(tmp: string)
  local function check(input: string): boolean, string
    if #input % 4 == 0 then Fuzz.label("a quarter") end
    return true, ""
  end
  local n = Fuzz.run({ name = "enough", iters = 64, gen = any_bytes, check = check,
    shares = { ["a quarter"] = 0.1 } })
  assert(n == 64)
  local err = report({ name = "too rare", dir = tmp, iters = 64, gen = any_bytes, check = check,
    shares = { ["a quarter"] = 0.6 } })
  assert(err:find('^fuzz too rare: seed=1: %d+ inputs of 64 reached "a quarter", under the share of 0.6 ' ..
    "the property requires: its inputs exercise it too rarely$"), err)
  assert(not Fs.exists(tmp .. "/too-rare.input"))
end

-- A share outside (0, 1], NaN among them, is refused before anything is
-- drawn, as a floor that would always or never hold.
local function test_a_share_outside_zero_to_one_is_refused()
  for _, share in ipairs({ 0.0, -0.5, 1.5, 0 / 0 }) do
    local err = report({ name = "bad share", iters = 64, gen = any_bytes,
      check = function(_input: string): boolean, string error("drawn") end,
      shares = { x = share } })
    assert(err:find('^fuzz bad share: the share of "x" is .+, not in %(0, 1%]$'), err)
  end
end

-- A count the property names itself is a whole run: `requires` holds of
-- it however few inputs it draws. (Only FUZZ_ITERS below the default,
-- what reproducing one failure asks for, lets it go.)
local function test_a_named_count_holds_requires()
  local err = report({ name = "short", iters = 3, gen = any_bytes,
    check = function(_input: string): boolean, string return true, "" end,
    requires = { "never" } })
  assert(err:find('no input of 3 reached "never"', 1, true), err)
end

-- A check that runs a property of its own leaves the enclosing run's
-- labels counting: the inner run's are its own.
local function test_a_nested_run_keeps_the_enclosing_labels()
  local n = Fuzz.run({ name = "outer", iters = 64, gen = any_bytes,
    check = function(_input: string): boolean, string
      Fuzz.run({ name = "inner", iters = 2, gen = any_bytes,
        check = function(_i: string): boolean, string
          Fuzz.label("inner")
          return true, ""
        end })
      Fuzz.label("outer")
      return true, ""
    end,
    requires = { "outer" } })
  assert(n == 64)
  local err = report({ name = "outer only", iters = 64, gen = any_bytes,
    check = function(_input: string): boolean, string
      Fuzz.run({ name = "inner", iters = 1, gen = any_bytes,
        check = function(_i: string): boolean, string
          Fuzz.label("inner")
          return true, ""
        end })
      return true, ""
    end,
    requires = { "inner" } })
  assert(err:find('reached "inner"', 1, true), err)
end

-- A label outside a run's drawn inputs -- in a replay, or no run at all
-- -- counts nothing and does not raise.
local function test_a_label_outside_a_run_does_nothing()
  Fuzz.label("stray")
  local held = Fuzz.replay({ name = "replayed", gen = any_bytes,
    check = function(_input: string): boolean, string
      Fuzz.label("stray")
      return true, ""
    end }, "x")
  assert(held)
end

-- A report names its input's own case, and a run given that case checks
-- that one input -- the one that failed -- and nothing else: not the
-- other iterations, not another property, not a corpus.
local function test_a_case_checks_the_one_input_it_names(tmp: string)
  local seen: {string} = {}
  local function no_nul(input: string): boolean, string
    seen[#seen + 1] = input
    return input:find("\0", 1, true) == nil, "a NUL"
  end
  local err = report({ name = "one case", iters = 200, gen = any_bytes, check = no_nul })
  local case = assert(err:match("reproduce: FUZZ_CASE=(%S+)"), err)
  local first: string
  for i = 1, #seen do
    if seen[i]:find("\0", 1, true) then
      first = seen[i]
      break
    end
  end
  seen = {}
  local again = report({ name = "one case", iters = 200, gen = any_bytes, check = no_nul, case = case })
  assert(seen[1] == first, "the case drew another input")
  assert(again:find("fuzz one case: FUZZ_CASE=" .. case .. ": a NUL", 1, true), again)
  local corpus = tmp .. "/corpus"
  assert(Fs.mkdirs(corpus))
  assert(Fs.write(corpus .. "/a.input", "\0"))
  seen = {}
  local n = Fuzz.run({ name = "another", corpus = corpus, gen = any_bytes, check = no_nul, case = case })
  assert(n == 0 and #seen == 0, ("checked %d"):format(#seen))
end

local function test_a_case_that_is_not_one_raises()
  for _, case in ipairs({ "p:x", " p:5", "a:b:5", ":5", "p:5 " }) do
    local ok, err = pcall(Fuzz.run, { name = "p", gen = any_bytes, case = case,
      check = function(_input: string): boolean, string return true, "" end })
    assert(not ok and tostring(err):find(("FUZZ_CASE=%q is not <property>:<case seed>"):format(case),
      1, true), case .. ": " .. tostring(err))
  end
end

-- A check that fails an input once and then holds for it depends on
-- something beside the input: the report says so rather than shrinking.
local function test_a_check_that_fails_once_is_reported_flaky()
  local failed = false
  local err = report({ name = "once", iters = 5, gen = any_bytes,
    check = function(_input: string): boolean, string
      if failed then return true, "" end
      failed = true
      return false, "the first time"
    end })
  assert(err:find("fuzz once: seed=1 iteration=1: flaky: failed (the first time), then held " ..
    "when the same input was checked again", 1, true), err)
  assert(not err:find("shrunk", 1, true), err)
end

-- A shrunk input that failed while shrinking and holds when checked
-- again is not reported as the smallest: the input that first failed
-- is, and the report says why.
local function test_a_shrunk_input_that_then_holds_is_named_flaky()
  local seen_alone = false
  local err = report({ name = "shrunk once", iters = 200, gen = any_bytes,
    check = function(input: string): boolean, string
      if input == "\200" then
        if seen_alone then return true, "" end
        seen_alone = true
        return false, "a high byte"
      end
      return input:find("[\200-\255]") == nil, "a high byte"
    end })
  assert(err:find("flaky: the shrunk input held when checked again", 1, true), err)
  assert(not err:find("input (hex): 80\n", 1, true), err)
end

-- Elements drawn after a `more` draw each are cut from the middle of a
-- collection by shrinking: what fails is two elements in order, and the
-- simplest failing input is those two, alone.
local function test_shrinking_cuts_elements_from_the_middle()
  local err = report({ name = "in order", iters = 300,
    gen = function(src: Fuzz.Source): string
      local parts: {string} = {}
      while Fuzz.more(src, #parts, 40) do
        parts[#parts + 1] = Fuzz.pick(src, { "a", "b", "c", "d" }) .. string.char(src:int(0, 9) + 48)
      end
      return table.concat(parts)
    end,
    check = function(input: string): boolean, string
      return input:find("b%d.*d%d") == nil, "b before d"
    end })
  assert(err:find("input (hex): 62306430\n", 1, true), err)
end

local function test_every_attempt_checkpoints_its_exact_input(tmp: string)
  local seen = 0
  local p: Fuzz.Property = { name = "checkpoint", dir = tmp, iters = 1,
    gen = function(src: Fuzz.Source): string return tostring(src:int(0, 1000)) end,
    check = function(input: string): boolean, string
      assert(Fs.read(tmp .. "/checkpoint.input") == input, "stale checkpoint")
      seen = seen + 1
      return false, "same bug"
    end }
  local err = report(p)
  assert(not err:find("stale checkpoint", 1, true), err)
  assert(seen > 3, "must include shrinking and confirmation")
  assert(Fs.read(tmp .. "/checkpoint.input.original") ~= nil)
  local held, why = Fuzz.replay(p, "replayed")
  assert(not held and why == "same bug")
  assert(Fs.read(tmp .. "/checkpoint.input") == "replayed")
  local corpus = tmp .. "/corpus"
  assert(Fs.mkdirs(corpus))
  assert(Fs.write(corpus .. "/one.input", "corpus"))
  p.corpus = corpus
  err = report(p)
  assert(err:find("corpus input", 1, true), err)
  assert(not err:find("stale checkpoint", 1, true), err)
end

local function test_an_unsavable_checkpoint_prevents_the_check(tmp: string)
  local checked = false
  local p: Fuzz.Property = { name = "unsaved", dir = tmp .. "/absent", iters = 1,
    gen = any_bytes,
    check = function(_input: string): boolean, string
      checked = true
      return false, "bug"
    end }
  local err = report(p)
  assert(err:find("cannot save evidence", 1, true), err)
  assert(not checked)
  local ok, why = pcall(Fuzz.replay, p, "replay")
  assert(not ok and tostring(why):find("cannot save evidence", 1, true))
  assert(not checked)
end

local function test_shrinking_preserves_failure_identity_and_secondary_evidence(tmp: string)
  local first: string
  local err = report({ name = "identity", dir = tmp, iters = 1,
    gen = function(src: Fuzz.Source): string return tostring(src:int(1, 1000000)) end,
    check = function(input: string): boolean, string
      if first == nil then first = input end
      return false, input == first and "original bug" or "other bug"
    end })
  assert(err:find("iteration=1: original bug", 1, true), err)
  assert(Fs.read(tmp .. "/identity.input") == first)
  assert(Fs.read(tmp .. "/identity.input.original") == first)
  local secondary = Fs.read(tmp .. "/identity.input.secondary-1")
  assert(secondary ~= nil and secondary ~= first)
  assert(err:find("secondary failure 1: other bug", 1, true), err)
end

local function test_explicit_identity_allows_varying_diagnostics_to_shrink(tmp: string)
  local err = report({ name = "stable identity", dir = tmp, iters = 1,
    gen = function(src: Fuzz.Source): string return tostring(src:int(1, 1000000)) end,
    check = function(input: string): boolean, string return false, "bad value " .. input end,
    failure_id = function(_input: string, _why: string): string return "bad-value" end })
  assert(Fs.read(tmp .. "/stable-identity.input") == "1", err)
  assert(err:find("bad value 1", 1, true), err)
end

local function test_confirmation_requires_the_same_failure_identity()
  local checks = 0
  local err = report({ name = "changes bug", iters = 1, gen = any_bytes,
    check = function(_input: string): boolean, string
      checks = checks + 1
      return false, checks == 1 and "one" or "two"
    end })
  assert(checks == 2, err)
  assert(err:find("flaky: failed (one), then failed differently (two)", 1, true), err)
end

local function test_generator_errors_are_attributed_to_the_seed(tmp: string)
  local err = report({ name = "generator", dir = tmp, iters = 1,
    gen = function(src: Fuzz.Source): string
      local _ = src:int(0, 9)
      error("cannot generate", 0)
    end,
    check = function(_input: string): boolean, string error("must not check") end })
  assert(err:find("fuzz generator: seed=1 iteration=1: generator raised: cannot generate", 1, true), err)
  assert(err:find("reproduce: FUZZ_CASE=generator:", 1, true), err)
  local saved = assert(Fs.read(tmp .. "/generator.input.generation"))
  assert(saved:find("draws: ", 1, true), saved)
end

local function test_generator_fault_while_shrinking_does_not_replace_the_check_failure()
  local first = true
  local err = report({ name = "generator replay", iters = 1,
    gen = function(src: Fuzz.Source): string
      local n = src:int(1, 1000)
      if not first then error("replay generator fault", 0) end
      first = false
      return tostring(n)
    end,
    check = function(_input: string): boolean, string return false, "original check failure" end })
  assert(err:find("iteration=1: original check failure", 1, true), err)
  assert(err:find("generator raised while replaying shrink choices:", 1, true), err)
end

local function test_nested_checks_restore_the_checkpoint_and_inherit_the_budget(tmp: string)
  local p: Fuzz.Property = { name = "nested", dir = tmp, iters = 1, budget = 100000,
    gen = function(_src: Fuzz.Source): string return "outer" end,
    check = function(input: string): boolean, string
      local inner: Fuzz.Property = { name = "nested", dir = tmp,
        check = function(_input: string): boolean, string return true, "" end }
      assert(Fuzz.replay(inner, "inner"))
      assert(Fs.read(tmp .. "/nested.input") == input, "inner stole checkpoint")
      while true do end
    end }
  local err = report(p)
  assert(err:find("spent its budget of 100000 VM instructions", 1, true), err)
  assert(not err:find("inner stole checkpoint", 1, true), err)
end

local function test_nested_budget_exhaustion_cannot_be_swallowed()
  local err = report({ name = "outer budget", iters = 1, budget = 100000,
    gen = any_bytes,
    check = function(_input: string): boolean, string
      local _ = pcall(Fuzz.replay, { name = "inner budget",
        check = function(_s: string): boolean, string
          while true do end
        end }, "")
      return true, ""
    end })
  assert(err:find("spent its budget of 100000 VM instructions", 1, true), err)
end

local function test_an_invalid_explicit_failure_identity_is_refused()
  for _, bad in ipairs({ "", "nil" }) do
    local err = report({ name = "invalid identity", iters = 1, gen = any_bytes,
      check = function(_s: string): boolean, string return false, "bug" end,
      failure_id = function(_input: string, _why: string): string
        if bad == "nil" then return nil end
        return ""
      end })
    assert(err:find("failure_id must return a nonempty string", 1, true), err)
  end
end

local function test_a_tiny_budget_does_not_leak_into_later_checks()
  local held, why = Fuzz.replay({ name = "tiny", budget = 1,
    check = function(_s: string): boolean, string return true, "" end }, "")
  assert(not held and why:find("budget", 1, true), why)
  assert(Fuzz.replay({ name = "after tiny",
    check = function(_s: string): boolean, string return true, "" end }, ""))
end

local function test_budget_boundaries_return_outcomes_and_restore_state()
  for budget = 1, 100 do
    for _, raises in ipairs({ false, true }) do
      local ok, held, why = pcall(Fuzz.replay, { name = "boundary", budget = budget,
        check = function(_s: string): boolean, string
          if raises then error("ordinary failure", 0) end
          return true, ""
        end }, "")
      assert(ok, ("budget %d escaped: %s"):format(budget, tostring(held)))
      assert(held or why:find("budget", 1, true) or why == "raised: ordinary failure", why)
    end
  end
  assert(Fuzz.replay({ name = "after boundaries",
    check = function(_s: string): boolean, string return true, "" end }, ""))
end

local function test_secondary_evidence_is_bounded(tmp: string)
  local first: string
  local others = 0
  local err = report({ name = "many failures", dir = tmp, iters = 1,
    gen = any_bytes,
    check = function(input: string): boolean, string
      if first == nil then first = input end
      if input == first then return false, "original" end
      others = others + 1
      return false, "other " .. others
    end })
  assert(others > 4, err)
  assert(err:find("secondary failure 4:", 1, true), err)
  assert(not err:find("secondary failure 5:", 1, true), err)
  assert(not Fs.exists(tmp .. "/many-failures.input.secondary-5"))
end

local function test_returned_and_raised_failures_have_distinct_identities()
  local function key(raises: boolean): string
    local held, _, identity = Fuzz.replay({ name = "kinds",
      failure_id = function(_input: string, _why: string): string return "raised: boom" end,
      check = function(_input: string): boolean, string
        if raises then error("boom", 0) end
        return false, "raised: boom"
      end }, "")
    assert(not held)
    return identity
  end
  assert(key(false) ~= key(true))
end
