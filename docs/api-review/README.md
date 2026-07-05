# Pre-stable API review: cosmo.* C bindings and cosmic.* stdlib

Date: 2026-07-05. Scope: the Lua C API in whilp/cosmopolitan as consumed by
whilp/cosmic, and the cosmic Teal API + generated types. Breaking changes are
in scope; no backwards compatibility. Each numbered item below is intended to
become one GitHub issue (repo noted per item). Items marked **[verified]**
were reproduced hands-on against a locally built cosmic binary during the
review; everything else is backed by cited source.

Priorities:

- **P0** — must land before stable: memory safety, security, silent data
  corruption, process-killing bugs, and type/shape contracts that are wrong
  in ways that freeze badly.
- **P1** — should land before stable: contract redesigns and convention
  sweeps that are breaking (so now is the time) or that make the API honest.
- **P2** — nice to have; additive or contained enough to land after stable
  without breaking anything.

Cross-repo mechanics for every cosmopolitan-side change: update
`tool/net/definitions.lua` in the same commit (annotation ratchet enforces
this), cut a cosmos release, bump `3p/cosmos/version.lua` in cosmic, run
`bin/make regen-types && bin/make test only=gentype`, fix wrappers, and run
`bin/make ci` + `bin/make perf-compare`.

---


The findings are split into chapters to respect the repo's 500-line file cap:

- [P0 — must fix before stable](p0.md) (items 1–13)
- [P1 — C-boundary and cross-layer contracts](p1-contracts.md) (items 14–21)
- [P1 — cosmic stdlib sweeps and reshapes](p1-stdlib.md) (items 22–31)
- [P2 — nice to have](p2.md) (items 32–39)

## Suggested sequencing (release waves)

1. **Safety wave (no contract debate):** #1 getopt UAF, #6 UUID randomness,
   #2 SIGPIPE, #3 transaction, #5 destructive probe, #10 spawn hygiene,
   #25 shm C fixes.
2. **Purge wave:** #27 surface purge + definitions.lua cleanup — shrinks
   every later diff.
3. **Honest-types wave:** #8 (renderer + stdlib nil sweep) + #29 options
   classes + #12 host_os — one breaking release where the type checker
   starts enforcing error handling.
4. **C-contract wave:** #14 error convention with #15 re, #17 zip C, #18
   json C, #28 compression, #34 argon2, #24 signals folded in; one cosmos
   release, one pin bump, one regen.
5. **cosmic-shape wave:** #11 child redesign, #19 fetch restructure, #13
   headers, #20 streaming, #21 url/ip, #22 errno sweep, #23 fs, #26
   quicksand, #4 fail-closed sandboxing.
6. **Rename/namespace wave:** #30 io→fd, #31 naming sweep, #32 directory
   modules — last, so churn doesn't rebase everything else.

Every wave: `bin/make ci` + `bin/make perf-compare` in cosmic; C changes
also `make -j o//tool/lua/test` upstream.

## Coverage note

Reviewed and found sound (no issues filed): lunix.c's internal consistency
(the Errno *representation* is the issue, not the discipline); ljson.c's
decoder security posture (UTF-8 validation, depth + C-stack guards, junk
detection); fetch's TLS story (verification required, no disable path,
downgrade refusal, cross-origin credential stripping); lzip writer
validation and crash-safety; cosmic's errno.tl, child_io pump correctness,
fs_path.normalize fast path, fs_walk d_type optimization, glob escaping,
envd parsing/precedence, tty.getpass, codec validators, fuzzy, uuid (API),
argon2 parameter defaults (OWASP-compliant, verified from a live hash),
quicksand's proxy stack / netns / proc / caps ordering, landlock.tl's core
design, poll's core design, url escaping family, fetch header-injection
defense, and the gentype drift-test mechanism itself.
