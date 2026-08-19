> Capture note, 2026-08-19: spec refined to the ready bar; filed unparented because plan and ready sat at their limits. Attach under 3I1IfJ22 (the G2 sandbox epic) and promote when a slot opens; blocked_by edges to record at attach time are in the "Blocked by" section (ids: R1 report = 3I7LBrUN, wave-1 bindings = 3I7LDODd, wave-2 bindings = 3I7LEsGv, pin bump 1 = 3I7LGcLa).

## Goal

G2, requirement R7: a `net` section in the sandbox policy — per-port TCP
containment on ABI ≥ 4 kernels — for hosts where unprivileged user
namespaces are disabled and quicksand's netns cannot start. The proxy
keeps hostname/HTTP-level policy; landlock net owns the port tier.

## Change

Builds on the R1 report shapes and the wave-1 pin (both in
`blocked_by`). The vocabulary, settled to mirror `fs` exactly:

1. **`cosmic/sandbox/init.tl`**: `record Net` — `connect_tcp:
   {integer}`, `bind_tcp: {integer}` — and `Options.net: Net`. Same
   semantics as fs groups: a present-but-empty list denies that
   category entirely; an absent key leaves that category unrestricted;
   an absent `net` section means no network policy. `validate` refuses
   a non-integer or out-of-range (0–65535) port, naming index and
   value, before anything is applied.
2. **`cosmic/sandbox/landlock.tl`**: `RestrictOptions` gains the net
   masks; `restrict` passes `handled_access_net` to
   `unix.landlock_create_ruleset` and adds one
   `unix.landlock_add_net_rule` per allowed port. `abi_mask` (line 137)
   learns the ABI-4 gate: below ABI 4 the net request is not
   expressible — under `strict` that refuses; otherwise the section
   reports `"skipped"` with the ABI in `missing`, through the R1
   `Enforcement`/`Report` path, never silently.
3. **Report**: `Report.net: Section`, same grammar as fs/sys — which is
   why R1 lands first.
4. **Tests** (`landlock_test.tl` at 353/500 — split a
   `landlock_net_test.tl` beside it rather than crowding the cap):
   GitHub's ubuntu runners are kernel 6.8 = ABI 4, so this is live in
   CI: bind a loopback listener on an ephemeral port; apply
   `net = { connect_tcp = {<that port>} }`; connect succeeds; a second
   listener's port, not granted, refuses with EACCES. `bind_tcp = {}`
   then refuses a fresh bind. On ABI < 4 or non-Linux the tests skip on
   the probed ABI, the same convention the suite already uses (this
   repo's sandbox kernel: ENOSYS, measured).

## Non-goals

- no UDP (the kernel offers none), no address-level policy (that is the
  proxy's), no changes to quicksand (its consumption is the follow-up
  slice), no `fs`/`sys` behavior changes.
- no emulation below ABI 4 — unenforcing platforms stay honest, per the
  goals.md non-goal.

## Blocked by

The R1 report slice and the wave-1 pin bump — mirrored in `blocked_by`.

## Acceptance

- `bin/cosmic --make test cosmic/sandbox/landlock_net_test.tl cosmic/sandbox/init_test.tl`
  ends `test: PASS (2 files)`.
- `bin/cosmic --make ci` ends `ci: PASS`.
- the PR quotes the CI run's net test names passing on the ubuntu lane
  (the ABI-4 live proof this spec is written against).

## Enablement

none needed once its blockers land — the vocabulary, gating, and test
strategy are settled above; the file split preempts the 500-line cap.
