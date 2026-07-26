# Coverage's environment-sensitive tests

The ratchet floors in `baseline.txt` encode **which lines execute**, and
that depends on the machine. Two of CI's heaviest complications exist to
hold those inputs still:

- the **digest-pinned container** (#734) — an OS image roll moved the
  floor (#722's churn), so the image became a pin;
- the **non-root builder** in every lane — tests skip differently as
  root, so *identity* became a pinned build input too.

Both treatments are correct. The shape worth noticing is that an
environment-sensitive metric forced CI to pin the environment twice, and
each newly discovered sensitivity adds another pin. The structural fixes
(skip-aware coverage; flooring on the cross-lane intersection) are
recorded in [make-3i.md](../../docs/design/make-3i.md). This file is the
cheap half that is worth having regardless: **an inventory, so the next
floor churn is diagnosable in minutes instead of rediscovered.**

Keep it current. A test that skips on a condition the host controls
belongs here the day it is written.

## What varies, and what it moves

| condition | tests | effect on coverage |
|---|---|---|
| **euid == 0** | `cosmic/fs/walk_test.tl` skips its EACCES path — root can traverse an unreadable directory, so the error branch is unreachable | `cosmic/fs/walk.tl`'s permission-error lines. This is the sensitivity the non-root builder exists for, and it was folklore until now |
| **Landlock available** (Linux ≥ 5.13, and not already restricted by an outer sandbox) | `cosmic/landlock_test.tl`, `cosmic/unveil_test.tl`, `cosmic/sandbox_test.tl`, `_cli/fence_test.tl` | `cosmic/landlock.tl`, `cosmic/unveil.tl`, `cosmic/sandbox.tl`, and `_cli/driver.tl`'s fence path. The enforce lane is where these actually run |
| **pledge available** | `cosmic/pledge_test.tl` — note it skips in BOTH directions: the fail-closed path is unexercisable where pledge works, and the success path where it does not | `cosmic/pledge.tl` |
| **Linux namespaces** (`unshare`, uid_map writes, capabilities) | `cosmic/quicksand/**` — `proc_test` alone carries 17 skips, plus `box/run_test`, `caps_test`, `netns_test`, `proxy_test`, `init_test` | all of `cosmic/quicksand/**`. The largest single block, and the reason those files' floors are low |
| **a real tty** | `cosmic/tty_test.tl`, `cosmic/tty_pty_test.tl` | `cosmic/tty.tl`. Neither stdin nor stdout is a tty under make, so the interactive branches never run in any lane |
| **the network / a free port** | `cosmic/net/connect_test.tl`, `cosmic/net/init_test.tl`, `cosmic/quicksand/proxy/serve_test.tl` | `cosmic/net/**`. The offline lane deliberately runs with only loopback |
| **fork available** | `cosmic/quicksand/proxy/serve_test.tl`, `cosmic/child/init_test.tl` | the child/proxy paths that need a second process |
| **the make engine present** (`check.needs`, audit 029) | every `_make` graph test | all of `_make/**`. Unlike the rows above this one HARD-FAILS in CI rather than skipping — a graph-test surface that silently becomes green skips is the failure 029 closed |

## Reading a floor that moved

1. Compare the `missing:` line in `o/coverage-summary.txt` against this
   table before assuming a regression. A block of newly-missing lines in
   one of the files above is an environment change, not a code change.
2. `check.skip` messages go to the test's `.err`, so
   `grep -h SKIP o/coverage/**/*.test.err` says what the run actually
   skipped. That is the fastest confirmation.
3. Only then look at the diff.

The floors are deliberately **conservative** — most are well under what
a full lane achieves, because the file is a floor and not a snapshot.
Do not "refresh" it wholesale to make one row pass: rewriting it from
whatever machine is at hand bakes that machine's environment into every
row, which is the failure this whole file is about.
