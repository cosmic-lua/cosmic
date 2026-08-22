## Goal

G5, via the cosmic.fuzz epic (3I1j7yQA): a fuzz failure must be
believable. The message names a minimized input and a draw count, but
the detail beside them describes the ORIGINAL failing iteration and the
count includes draws the minimized input never consumes — so the one
artifact a reader reproduces from disagrees with itself. A reader who
replays the named input and sees a different error stops trusting the
lane, which is the same damage a false red does.

## Evidence

2026-08-20 audit, re-reproduced 2026-08-22 against `origin/main` at
`ff09b575` on a built tree.

`_fuzz/driver.tl`'s `run_in_process` computes the detail `what` from the
original failing iteration (driver.tl:173-182 on `ff09b575`), then
replaces the reported input with a minimized one (driver.tl:183-184)
without recomputing the detail. Two facts make the pairing wrong:

- `shrink`'s `still_fails` (`_fuzz/shrink.tl:35-46`) accepts a candidate
  on ANY failure, not the same one — a throw and a false return are
  indistinguishable to it, deliberately ("shrinking does not distinguish
  which invariant broke").
- `source.replay` sets `rec.draws` to the whole candidate list
  (`_fuzz/source.tl:69`), not to what the generator consumed, so
  `#minimized_draws` counts a tail that value-shrinking left behind.

**Reproduced.** A probe at `_fuzz/zzprobe_test.tl` — `gen =
driver.bytes(src, 256)`, `iters = 1`, and a check that throws on inputs
over 5 bytes but returns `false, "too long"` over 2 — run through
`o/bin/cosmic --make test _fuzz/zzprobe_test.tl`:

```
detail_probe: seed=1 iteration=1 input(base64)=AAAA draws=8: threw: o/_fuzz/zzprobe_test.lua:14: thrown_only_for_long_inputs
```

`AAAA` decodes to three zero bytes, which does NOT throw — it returns
`false, "too long"`. And `driver.bytes` draws one length plus one per
byte (`driver.tl:392-402`), so that input consumes **4** draws, not the
8 reported.

**Measured line counts** (`wc -l`, on this branch's base — `main` plus
board item 3ICDH3lW, see Enablement):

```
_fuzz/driver.tl       451
_fuzz/driver_test.tl  471
_fuzz/source.tl       101
_fuzz/shrink.tl       237
```

`driver.tl` has 49 lines of headroom under the 500-line cap
(`_tool/lint.tl`), and that number decides the placement below.

**Readers of a Recorder's `draws` field** (`git grep -n "\.draws" --
_fuzz`): `driver.tl:213` and `driver.tl:329` both read a recorder from
`source.new`, not from `source.replay`; `shrink_test.tl:13` likewise.
Inside `_fuzz/shrink.tl`, `still_fails` calls `source.replay` but never
reads its `draws`. The ONLY reader of a replay recorder's `draws` is
`driver_test.tl:208`, and it consumes the whole sequence first
(`driver.bytes(replayed, 24)` at line 206) — so it reads the same
number either way.

## Change

Two files: `_fuzz/source.tl` and `_fuzz/driver.tl`, plus the tests in
`_fuzz/driver_test.tl`. `_fuzz/shrink.tl` is NOT touched.

### 1. `_fuzz/source.tl` — a replay Recorder records what it CONSUMES

In `replay` (source.tl:55-85), stop aliasing the input list into the
Recorder and accumulate the consumed draws instead. Replace

```teal
  local rec: Recorder = {draws = draws}
```

with

```teal
  local consumed: {Draw} = {}
  local rec: Recorder = {draws = consumed}
```

and append `d` in each accessor, after its `nil` guard and before the
`return v`:

```teal
    consumed[#consumed + 1] = d
```

— once in `rec.int` and once in `rec.float`. Amend `replay`'s doc
comment to say that the returned Recorder's `draws` holds what has been
consumed so far, not the sequence it was given.

This is the placement to use, not a private helper in `driver.tl`:
building the same consuming wrapper in the driver was measured at +34
lines there (`driver.tl` 485 of 500), against +3 in `source.tl`, which
has 399 lines of headroom. `source.tl` already owns the record/replay
contract, so the count belongs with it.

### 2. `_fuzz/driver.tl` — one classifier, used at every check site

Add one local, replacing the inline classification currently inside
`run_in_process`'s loop, placed directly above `budgeted`:

```teal
--- Run check once on one input, under the budget hook, classifying
--- the outcome into the detail a failure reports.
--- @param check function The property's check
--- @param input string The input to check
--- @param budget integer VM instructions this call may spend
--- @return boolean True when the property held
--- @return string What failed, when it did not
local function attempt(
    check: function(input: string): boolean, string,
    input: string,
    budget: integer
  ): boolean, string
  local armed = arm_budget(budget)
  local ok, held, why = pcall(check, input)
  if armed then
    disarm_budget()
  end
  if not ok then
    local thrown = tostring(held)
    if thrown == BUDGET_MESSAGE then
      return false, ("budget=%d exceeded"):format(budget)
    end
    return false, "threw: " .. thrown
  end
  if not held then
    return false, tostring(why or "no detail")
  end
  return true, ""
end
```

Re-express `budgeted` on top of it, so one function decides what a
failed check is called, at all three sites (the loop, shrink's
candidates, the re-check below):

```teal
local function budgeted(
    check: function(input: string): boolean, string, budget: integer
  ): function(input: string): boolean, string
  return function(input: string): boolean, string
    return attempt(check, input, budget)
  end
end
```

`budgeted`'s doc comment stays as it is — the contract it describes is
unchanged.

Then rewrite the loop body's failure arm. From (driver.tl:195-215 on this
branch's base):

```teal
    local input = opts.gen(rec)
    local armed = arm_budget(budget)
    local ok, held, detail = pcall(opts.check, input)
    ...
    if not ok or not held then
      local what: string
      ...
      local minimized_draws = shrink.shrink(
        opts.gen, budgeted(opts.check, budget), rec.draws)
      local minimized_input = opts.gen(source.replay(minimized_draws))
      return false, failure(opts.name, seed, i, minimized_input, #minimized_draws, what)
    end
```

to:

```teal
    local input = opts.gen(rec)
    local held, what = attempt(opts.check, input, budget)
    if not held then
      local minimized_draws = shrink.shrink(
        opts.gen, budgeted(opts.check, budget), rec.draws)
      local replayed = source.replay(minimized_draws)
      local minimized_input = opts.gen(replayed)
      local still_held, minimized_what = attempt(opts.check, minimized_input, budget)
      if not still_held then
        what = minimized_what
      end
      return false, failure(
        opts.name, seed, i, minimized_input, #replayed.draws, what)
    end
```

Two decisions, both settled here:

- **The re-check runs under the budget** (it goes through `attempt`, not
  a bare `pcall`): a minimized input can be the one that loops, and a
  driver that hangs while composing its own failure message is the bug
  3ICDH3lW just removed from shrinking.
- **A minimized input that HOLDS keeps the original detail** (`if not
  still_held then`). Shrink only returns candidates `still_fails`
  accepted, so this is not expected; the branch exists so a
  non-deterministic property degrades to today's behaviour instead of
  reporting a failure with no detail.

Amend `run_in_process`'s doc comment (`driver.tl:174-189`) in one
clause to say the reported detail and draw count describe the MINIMIZED
input, not the original iteration. Change no other prose, and do not
touch the crash path's `#rec.draws` at driver.tl:329 — that recorder
comes from `source.new` and its count is already exact.

### 3. `_fuzz/driver_test.tl` — one new test, one flipped assertion

- Add `test_the_reported_detail_and_draws_describe_the_minimized_input`,
  called on the line after its `end`. Use the probe property from
  Evidence verbatim (`iters = 1`, `gen = driver.bytes(src, 256)`, a
  check that throws over 5 bytes and returns `false, "too long"` over
  2). Assert three things about the message: it contains `too long`, it
  does NOT contain `threw:`, and it contains `draws=4`. All three are
  measured — the fix produces `detail_probe: seed=1 iteration=1
  input(base64)=AAAA draws=4: too long`. It needs no `without_coverage`
  wrapper: the property sets no `budget` and never loops, so nothing
  depends on the VM hook.
- **Flip one assertion in
  `test_a_shrink_candidate_that_loops_is_caught`** (added by 3ICDH3lW).
  It currently asserts the message contains `too big` — the ORIGINAL
  iteration's detail — which is exactly the pairing this item removes.
  Measured with the fix applied, that test's message becomes
  `candidate_loops: seed=1 iteration=1 input(base64)= draws=1:
  budget=100000 exceeded`: shrinking minimizes to the empty input, which
  loops, so the budget catches it and the detail now describes the input
  actually reported. Change the assertion to `msg:find("budget=100000
  exceeded", 1, true)` and its message to say the reported detail matches
  the reported input. Leave the rest of that test alone — its
  `without_coverage` wrapper, its `ok == false` assertion, and above all
  its `FUZZ_SEED` pin: seed 1 is what makes the first input 5 bytes, so
  removing the pin puts the reported detail back at the mercy of the
  lane's rotating seed.

## Non-goals

- **`_fuzz/shrink.tl` is not touched.** `still_fails` keeps accepting a
  candidate on ANY failure; making shrinking preserve the failure KIND
  is a different design with a different cost, and this item's fix makes
  it unnecessary for the message to be honest.
- **`failure()` does not move.** Its signature, its
  `seed=/iteration=/input(base64)=/draws=` grammar and the
  `budget=%d exceeded` and `threw: ` texts are unchanged;
  `driver_test.tl` asserts substrings of all of them and
  `.github/workflows/fuzz.yml` documents them.
- **`iteration=` still names the ORIGINAL iteration.** Only the detail
  and the draw count move to the minimized input; the iteration index is
  what makes a failure replayable with `FUZZ_SEED`.
- **Not the wall clock, not the budget's size.** `DEFAULT_TIMEOUT_MS`,
  `TIMEOUT_PER_ITER_MS`, `timeout_for`, `DEFAULT_BUDGET` and
  `BUDGET_MESSAGE` are unchanged, and `opts.gen` stays outside the
  budget.
- **`source.new`'s Recorder is unchanged.** Only `replay`'s `draws`
  semantics move; the recording wrapper already reports exactly what it
  drew.
- **No new module.** The 500-line cap is not near binding on either file
  after this change (measured below), so nothing is split out.
- **No `.cosmic-coverage` regeneration is expected** — no file is added
  and all three already carry a row. If the ratchet does complain, run
  exactly the regen command its failure message prints
  (`bin/cosmic --make coverage --baseline`) and commit the result; never
  weaken the gate any other way.

## Acceptance

Every command is run from the repository root and must print the
literal verdict line quoted after it.

1. **The full gate holds.**

       bin/cosmic --make ci

   Verdict line ends `ci: PASS`.

2. **The driver's tests pass, including the new one.**

       bin/cosmic --make test _fuzz/driver_test.tl

   Verdict line ends `test: PASS`. The runner's `✓` line reports 20 test
   functions, one more than the base's 19. Quote it.

3. **The reported detail and draw count describe the reported input.**
   The new test is the gate, but quote the message it asserts on, from
   `o/_fuzz/driver_test.tl.test.out` or a probe run, and show that it
   reads `draws=4: too long` — not `draws=8` and not `threw:`.

4. **Every fuzz property still passes at the default depth.**

       bin/cosmic --make test _fuzz

   Verdict line ends `test: PASS` (8 files).

5. **`_fuzz/shrink.tl` is byte-identical to its base.**

       git diff --stat origin/main -- _fuzz/shrink.tl

   Prints nothing.

6. **Caps hold.**

       wc -l _fuzz/driver.tl _fuzz/driver_test.tl _fuzz/source.tl

   All three under 500. Measured with the change applied: `driver.tl`
   462 and `source.tl` 104; `driver_test.tl` is 471 before the new test.

## Enablement

**Blocked by 3ICDH3lW** (PR #1310, in `check`), and the `blocked_by`
edge is recorded on this item. That is not a courtesy: this item's
`Change` re-expresses `budgeted` — a function 3ICDH3lW introduces — and
flips an assertion in `test_a_shrink_candidate_that_loops_is_caught`, a
test 3ICDH3lW adds. Written against `main` without it, both hunks would
not apply. Every line count in this spec is measured against `main` plus
3ICDH3lW; if that item is rejected rather than landed, this spec must be
re-refined against whatever `main` then holds rather than implemented
from memory.

Beyond that, nothing is needed and no decision is left open:

- **The fix shape is proven, not proposed.** Both variants were applied
  to a built tree on 2026-08-22 and run. The probe's message went from
  `input(base64)=AAAA draws=8: threw: …thrown_only_for_long_inputs` to
  `input(base64)=AAAA draws=4: too long`, and `bin/cosmic --make test
  _fuzz` reported `8 checks: 8 passed` with the chosen variant applied.
  The Change section's code is that verified body verbatim.
- **The placement question is answered by measurement**, not taste: the
  driver-local wrapper cost 34 lines in a file with 49 of headroom; the
  `source.tl` change cost 3 in a file with 399.
- **The one test the change breaks is named**, with its measured new
  message, so no session discovers it as a surprise.
- **No cast is needed.** `attempt` branches on `pcall`'s results and
  returns literal `true`/`false` with a `tostring`-ed detail, so the
  `-- cast:` justification rule has nothing to bite on.
