# fuzz

`cosmic.fuzz` checks byte-string properties in isolated child processes.
Each run replays committed inputs before a deterministic generated sample.
A result distinguishes `pass`, `failure`, `crash`, `timeout`, and `error`.

## write a property

```teal
--- env: FUZZ_SEED FUZZ_ITERS
--- reads: testdata/fuzz
local fuzz = require("cosmic.fuzz")
local codec = require("cosmic.codec")

local function test_hex_round_trip()
  fuzz.assert_ok(fuzz.run({
    name = "hex_round_trip",
    gen = function(src: fuzz.Recorder): string
      return fuzz.bytes(src, 128)
    end,
    check = function(input: string): boolean, string
      local decoded, err = codec.decode_hex(codec.encode_hex(input))
      return decoded == input, err or "hex round trip changed the bytes"
    end,
  }))
end
```

The defaults are seed 1 and 256 generated inputs. `FUZZ_SEED` and
`FUZZ_ITERS` override them; `Options.seed` and `Options.iters` take precedence.
An invalid integer setting is an error. `iters = 0` explicitly selects corpus
only. Declare both environment inputs and the corpus path in test headers so
cached test results track them.

Names use letters, digits, underscores, dots and hyphens, excluding `.` and
`..`. They must be unique within an entry script. Use distinct names across
scripts sharing a corpus root, such as `json_round_trip` and `url_round_trip`.

A worker re-enters the same script and selects one property. Setup outside
`run` therefore executes again and must tolerate re-entry. Worker selectors
are checked against a request owned by the direct parent; ambient
`FUZZ_ISOLATE` and stale requests fail. `skipped` is only a worker's response
for an unselected sibling. The parent requires a completion record for its
selected property and a successful process exit before returning `pass`.
Nested `fuzz.run` calls inside a property are refused.

## capture and replay

Before invoking the generator, the worker records its phase and iteration.
Before invoking the check, it records the actual bytes. A signal or timeout
is attributed to that capture; generation failures have no invented input.
The supervisor kills and reaps a timed-out worker before reading its files.
An exit without a completion record is an infrastructure error, including
an exit with status zero.

`Result.generated` and `Result.corpus` count successful checks. `iteration`
is the failing position within the generated sample or corpus, identified
by the run's phase and counts. `has_input` distinguishes an empty input from
no input. `failure_kind` distinguishes an assertion, a throw, and an
instruction-budget timeout.

Each check receives a 50-million-instruction budget by default. Set `budget`
to change it. The worker has a wall-clock backstop of the greater of 30
seconds or 10 milliseconds per generated input; `timeout_ms` overrides that
entire allowance. It is a property-level timeout, including setup, corpus,
generation and shrinking, rather than a per-input wall clock.

A failed input is replayed once in a fresh worker without calling the
generator. The original run remains failed when replay passes, changes
failure category, or cannot run: `reproduction` says `not_reproduced` or
`unavailable`. Matching category and signal yields `reproduced`; this does
not claim that two failures have the same underlying cause.

For explicit replay, set `Options.replay_input` to the captured bytes. This
bypasses both the corpus and generation. Checks must derive their assertions
from those bytes. Structured values can be encoded into the input, or a
property can interpret a recorded choice sequence to construct values such
as cyclic tables. Such an interpreter still depends on the property's code
version; bytes alone cannot capture arbitrary external state.

## keep a regression

Default corpus entries are raw files at `testdata/fuzz/<name>/*.input`,
replayed in sorted path order. `corpus_dir` changes the root.

Failed runs retain a unique directory under `o/fuzz` for scripts, or under
the test step's persistent output directory in `o/` for `--make test`.
`artifact_dir` overrides this root. The automatically cleaned `TEST_TMPDIR`
is not the default artifact location. Passing runs remove their transient
protocol files. Failure results expose `saved_input` and `saved_result`.

`fuzz.read_result(path)` reads a versioned result file. It preserves binary
inputs and error messages through base64 fields. `fuzz.promote(result,
"testdata/fuzz")` explicitly copies its captured bytes into the property's
corpus directory using a SHA-256 filename; repeating promotion is idempotent.
Generation and testing never automatically write to the source corpus.

Ordinary assertion failures and throws use bounded draw-sequence shrinking.
Only candidates in the same category are retained, and the reported bytes
are the actual accepted candidate rather than a later regeneration. Budget
failures, crashes and wall-clock timeouts are captured and replayed without
shrinking. An interrupted shrink preserves the original failure.
