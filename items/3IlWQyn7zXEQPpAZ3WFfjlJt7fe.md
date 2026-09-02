## Goal

G3 — an honest type layer. The second half of the flat `cosmic/*`
cut of the `cosmic/**` `check.must` sweep (3IQfJ1tn): the remaining
eleven flat test/example files, 32 sites, file-disjoint from every
sibling child.

## Evidence

Census Method re-run 2026-09-02 at `5a36e7c9`, per file with the
producer each row traces to:

```text
cosmic/tty_pty_test.tl (6): 239 240 248 <- line 223 `local pid = proc.fork()`; 290 291 299 <- line 280
cosmic/check_test.tl (5):   366 375 390 415 418 <- lines 362 368 384 409 411 `proc.fork()` (good/bad/killed/outer/inner)
cosmic/fd_test.tl (5):
  180  `local ok: number` (179) then `ok, err = f:fcntl(…)`; assert `ok ~= nil`
  220  `local data: string` (219) then `data, err = fs.read(filepath)`; assert `data == content`
  305  `local n: number` (304) then `n, err = f:write("test")`; assert `n == nil and err == "handle closed"`  DELIBERATE NIL BRANCH
  384  `local n: number` (383) then `n, err = f:write("ABC", 2)`; assert `n == 3`
  390  `data .. ` where line 389 re-assigns `data = assert(f:read(100))` into the `string | nil` local from line 379
cosmic/proc_test.tl (4):    69 <- 67 `proc.getsid(…)`; 210 211 <- 209 `proc.getpriority(…)`; 223 <- 222 `proc.getpriority(…)`
cosmic/script_test.tl (3):  15 185 262 <- ONE producer, line 12 `local test_subdir = fs.temp_dir(…)` (string | nil)
cosmic/json_test.tl (3):    75 <- 74, 80 <- 79, 93 <- 92  `json.encode(…)` (string | nil)
cosmic/signal_test.tl (2):  102 <- 90, 171 <- 155  `local oldmask = signal.sigprocmask(SIG_BLOCK, …)` (Sigset | nil)
cosmic/signal_example.tl (1): 24 <- 16  same shape
cosmic/stream_test.tl (1):  123 <- 106 `local pid = proc.fork()` in serve_once (flags `pid`, col 32)
cosmic/hash_test.tl (1):    164 <- 163 `hash.hash_password("correct")` (string | nil)
cosmic/codec_test.tl (1):   205 <- 203 `local encoded, err = codec.encode_latin1(original)`; 204 asserts `err == nil`
```

Imports: every file imports `cosmic.check` except `codec_test.tl`
(301 lines). Headroom: fd_test 444, check_test 425, proc_test 394,
tty_pty 307, script_test 294, signal_test 232, stream_test 183.

## Change

- 21 wraps at the producers listed: `check.must(proc.fork())` (×8),
  `check.must(proc.getsid(…))`, `check.must(proc.getpriority(…))` (×2),
  `check.must(fs.temp_dir(…))`, `check.must(json.encode(…))` (×3),
  `check.must(signal.sigprocmask(signal.SIG_BLOCK, …))` (×3),
  `check.must(hash.hash_password(…))`, and for `fd_test.tl:389–390`
  a fresh `local verify = check.must(f:read(100))` compared and
  printed in place of `data`.
- `fd_test.tl` 179, 219, 304, 383: widen the declaration to
  `number | nil` / `string | nil`. The asserts stay byte-identical;
  line 305 is a deliberate nil-branch test and is named in the PR
  as such.
- `codec_test.tl:203–204` → `local encoded =
  check.must(codec.encode_latin1(original))`, which asserts the same
  fact (encode succeeded) with the same error carried in the message;
  add `local check = require("cosmic.check")`. Name it in the PR.
- `proc_test.tl:68`'s `type(sid) == "number"` assert stays.

## Non-goals

- No file outside these eleven; no library file.
- No checker change; no census doc edit; no committed strict checker.
- Do not change what a test asserts. Do not add a cast.

## Acceptance

- `bin/cosmic --make ci` ends `ci: PASS`.
- The Method's scan filtered to `^cosmic/[^/]+_(test|example)\.tl` reports
  only rows belonging to the flat-A sibling's four files (or 0 once it lands).
- Other shares unmoved from the pull-time baseline (2026-09-02:
  library 12; non-`cosmic/**` 0 / 11). Quote before/after.
- `git diff --name-only origin/main` lists only the eleven files above.
