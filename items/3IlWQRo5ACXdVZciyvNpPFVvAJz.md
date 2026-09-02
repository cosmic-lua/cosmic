## Goal

G3 — an honest type layer. The two `cosmic/**` subtrees the parent's
three-way cut did not name: `cosmic/net/**` and `cosmic/quicksand/**`,
together 11 sites in 5 files — one diff, file-disjoint from every
sibling child.

## Evidence

Census Method re-run 2026-09-02 at `5a36e7c9`:

```text
cosmic/net/connect_test.tl:105 :141 :250  check.reap(pid, …)  <- lines 84, 118, 231 `local pid = proc.fork()`
cosmic/net/init_test.tl:127 :373 :414     check.reap(pid, …)  <- lines 84, 348, 395 `local pid = proc.fork()`
cosmic/net/io_test.tl:103   out[#out + 1] = line   loop var of `stream.lines(sock)`
                            (cosmic/stream.tl:56 `type LineIter = function(): string | nil, string`)
cosmic/quicksand/caps_test.tl:57, :60 (x2)  operand of '<<'
                            <- line 55 `local chown = caps.number_of("CAP_CHOWN")`,
                               line 59 `local kill = caps.number_of("CAP_KILL")`
                               (caps.number_of: integer | nil, string)
cosmic/quicksand/proxy/serve_test.tl:189  assert(proc.wait(worker))  <- line 172 `local worker = proc.fork()`
```

All five files import `cosmic.check`. Headroom: connect_test 440,
init_test 440, io_test 318, caps_test 154, serve_test 227.

## Change

- The seven `proc.fork()` producers → `check.must(proc.fork())`.
- `caps_test.tl:55, :59` → `check.must(caps.number_of(…))`.
- `io_test.tl:103` → `out[#out + 1] = check.must(line)`.

## Non-goals

- No file outside `cosmic/net/**` and `cosmic/quicksand/**`; no library
  file (`LineIter` stays).
- No checker change; no census doc edit; no committed strict checker.
- Do not change what a test asserts. Do not add a cast.

## Acceptance

- `bin/cosmic --make ci` ends `ci: PASS`.
- The Method's scan filtered to `^cosmic/(net|quicksand)/` and
  `_(test|example|benchmark)\.tl` reports **0**.
- Other shares unmoved from the pull-time baseline (2026-09-02:
  library 12; non-`cosmic/**` 0 / 11). Quote before/after.
- `git diff --name-only origin/main | grep -vE '^cosmic/(net|quicksand)/.*_test\.tl$'` prints nothing.
