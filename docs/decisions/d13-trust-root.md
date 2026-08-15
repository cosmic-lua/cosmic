# D13 — the build's trust root is one pinned artifact behind one committed fetcher

- **date:** 2026-07
- **status:** amended 2026-07
- **context:** the #756 arc converged the build on "make as the pinned
  job graph, cosmic as the only build logic": every recipe is a single
  argv under a sha-pinned bootstrap, `SHELL` is poisoned globally with
  per-rule exceptions, sandbox annotations and per-rule env clamps
  document and (where opted in) enforce each rule's access. that
  discipline is only as strong as what the build ultimately trusts.
- **decision:** the chain, stated once: **kernel → committed `bin/make`
  → two sha-pinned artifacts → everything else.** `bin/make` is POSIX
  sh with one job — obtain the pinned bootstrap cosmic (release pinned
  in `cook.mk`), which then extracts the pinned landlock-make from
  `cosmos.zip` (release pinned in `3p/cosmos/cosmos_pin.tl`); it is the
  sole provisioner of both, and re-provisions on pin bumps. everything
  downstream — staged 3p, compiled tree, the cosmic binary, every gate —
  runs under those two artifacts. deliberately **outside** the root,
  enumerated: host `sh`/`curl`/`sha256sum` (and `od`/`sed`) for the
  first fetch; host `git` for version stamping; the digest-pinned CI
  container image. each link has a gate: the sha checks in `bin/make`
  refuse a wrong artifact; the makefile ratchet tests enumerate the
  real-shell exceptions and host-exec grants and statically scan recipe
  text for shell metacharacters; the sandbox canary plus the enforce
  lane prove enforcement works; the offline lane proves no undeclared
  network; the reproducible lane proves double-build determinism; the
  env-clamp fixture proves the `.ENV` clamp holds against a hostile
  caller environment.
- **rejected:** vendoring the binaries into git (the sha pin already
  fixes the bytes; vendoring adds repo weight, not trust); trusting any
  host toolchain beyond the first fetch (host make, cc, lua — where
  host variance lives); collapsing to a single artifact by shipping
  make inside the cosmic release binary (entangles the two release
  cycles for no reduction in what must be trusted — one fetcher, two
  pins is the achievable minimum).
- **consequences:** `bin/make` is the only place host variance can bite
  and the only committed shell that is not a per-rule exception; new
  binaries enter the build only through pin bumps; the ratchets keep
  the exception sets from regrowing silently. supply-chain review
  reduces to: read `bin/make`, audit two shas, trust the kernel.
- **amended 2026-07:** the chain is now **kernel → committed
  `bin/cosmic` → ONE sha-pinned artifact → everything else**, and the
  rejected option above — shipping make inside the cosmic release
  binary — is what happened. It was rejected for "no reduction in what
  must be trusted", and that reasoning was wrong on its own terms: a
  cosmic that carries its own build engine removes a pin, a fetch and a
  bootstrap step from the chain, and the entangled release cycles never
  materialised because the engine ships in the artifact that was already
  being released. `bin/cosmic` obtains the release named in
  `bin/cosmic.pin`, verifies its sha256, and execs it; cosmic extracts
  its own make from its own zip.

  Two gates named above went with the Makefile rather than being
  replaced: the makefile ratchet tests (they guarded real-shell
  exceptions and host-exec grants in a file that no longer exists — the
  recipe vocabulary is closed and its grants are DERIVED, so there is no
  exception set left to regrow) and the `.ENV` clamp fixture. The
  offline, reproducible, enforce and canary gates stand. Supply-chain
  review now reduces to: read `bin/cosmic`, audit one sha, trust the
  kernel.
