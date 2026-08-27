## Capture

Third data point in 24h that the release compare step's design leaks:
it runs the tree's _perf harness and bench modules bare under the
PREVIOUS release binary, so any _perf/** use of a cosmic API newer
than that release crashes the lane at load-time type check. Instances:
run.tl's cosmic.version_info (killed 08-26's run; fixed #1415),
literal_bench's two-arg literal.format (would have killed 08-27's
run; fixed #1420), and gate.tl's compare.triage_many (inert only
because gate.tl never runs bare). Each fix is a tolerant map view +
capability probe — a pattern that will keep recurring as the stdlib
grows.

Class guard candidates, one to pick and build:
1. A CI check that type-checks every non-test _perf/** file under
   the pinned bootstrap binary (o/bootstrap/cosmic — always at least
   as old as the previous release), failing the PR that introduces a
   skew instead of the release three days later. Cheap: the sweep is
   ~30 files, seconds.
2. Change the compare step to measure the previous release with its
   OWN embedded scenarios (self-consistent by construction) — but
   then scenario definitions can drift between sides and the compare
   loses like-for-like.
3. A lint rule taxing new cosmic API uses in _perf/** — noisy,
   version-blind.

Option 1 is the evidence-backed pick: it reproduces exactly the
failure mode (my debug sweep was precisely this check, run by hand,
and it found #1420's site before the lane did).
