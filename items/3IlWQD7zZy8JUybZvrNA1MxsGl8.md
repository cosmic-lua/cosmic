## Goal

G3 — an honest type layer. The `cosmic/fetch/**` cut of the
`cosmic/**` `check.must` sweep (3IQfJ1tn): five fetch test files,
one diff, file-disjoint from every sibling child.

## Evidence

Census Method re-run 2026-09-02 at `5a36e7c9`; the `cosmic/fetch/**`
rows and the producer each traces to:

```text
serve() helpers — `return math.tointeger(port), pid` flags PID (col 32), not tointeger
  (tl declares math.tointeger: function(any): integer; proc.fork(): integer | nil, string):
cosmic/fetch/init_test.tl:58         <- line 39  `local pid = proc.fork()`
cosmic/fetch/multiheader_test.tl:41  <- line 22  `local pid = proc.fork()`
cosmic/fetch/retry_test.tl:60        <- line 32  `local pid = proc.fork()`
cosmic/fetch/stream_test.tl:37       <- line 16  `local pid = proc.fork()`
cosmic/fetch/verbs_test.tl:69        <- line 50  `local pid = proc.fork()`
other forks:
cosmic/fetch/init_test.tl:184  assert(proc.wait(pid2))  <- line 163 `local pid2 = proc.fork()`
cosmic/fetch/init_test.tl:223  assert(proc.wait(pid))   <- line 196 `local pid = proc.fork()`
loop variable:
cosmic/fetch/stream_test.tl:69  table.insert(lines, line)  <- `for line in result.reader:lines()`
  (cosmic/fetch/body.tl:137 `body:lines(): function(): string | nil, string`)
declared return narrower than received — cosmic/fetch/verbs_test.tl, 10 rows:
  :86 :91 :97 :102 :111 :119 :129 :139 :155 :166  `in return value`
  each a closure declared `(fetch.Response, fetch.Error)` returning fetch.get/post/put/
  delete/fetch, which return `Response | nil, Error`; the closures are passed to
  `echo_request(run: function(string): (fetch.Response, fetch.Error))` (line 73), whose
  line 77 `assert(r ~= nil, …)` is the guard.
```

18 rows, 5 files. All five files import `cosmic.check`. Headroom:
init_test 307, multiheader 84, retry 189, stream 208, verbs 245.

## Change

- The seven `proc.fork()` sites → `local pid = check.must(proc.fork())`
  (`pid2` likewise). `fork` returns 0 in the child, never nil, so the
  child branch is unaffected.
- `stream_test.tl:69` → `table.insert(lines, check.must(line))`.
- `verbs_test.tl`: widen the declared return type in `echo_request`'s
  parameter (line 73) and in each of the ten closures to
  `(fetch.Response | nil, fetch.Error)`. The existing `assert(r ~= nil,
  …)` at line 77 already guards; do NOT wrap the closures' returns in
  `check.must`, which would make that assert vacuous and hide `err`.

## Non-goals

- No file outside `cosmic/fetch/**`; no library file (`Body.lines`'
  declaration stays).
- No checker change; no census doc edit; no committed strict checker.
- Do not change what a test asserts. Do not add a cast.

## Acceptance

- `bin/cosmic --make ci` ends `ci: PASS`.
- The Method's scan filtered to `^cosmic/fetch/` and
  `_(test|example|benchmark)\.tl` reports **0**.
- Other shares unmoved from the pull-time baseline (2026-09-02:
  library 12; non-`cosmic/**` 0 / 11). Quote before/after.
- `git diff --name-only origin/main | grep -vE '^cosmic/fetch/.*_test\.tl$'` prints nothing.
