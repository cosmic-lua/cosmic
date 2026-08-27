## Capture

Widening the dup-body gate over _perf (3IBuI5jY, PR #1440) surfaced
five duplicate groups the gate refuses: two find_bin variants
(embed/embed_startup/startup at ~:36 and http/download/stream at
~:27), read_request (the http family), send_all
(download:60/stream:51), the tmpdir cleanup
(embed:195/embed_startup:161/fs:183/startup:157/tar:145) and the
server cleanup (download:154/http:177/stream:156).

Export each into a shared non-bench module (e.g.
_perf/bench/support.tl — no _bench suffix, so the runner's glob never
discovers it) and require it; the per-module cleanup() wrappers that
remain (`tmpdir = support.remove_tree(tmpdir)`) normalize under the
gate's FLOOR and stay exempt. Then add "_perf" to _build/dupes.tl's
TREES and the test's reads line. The gate is zero-tolerance: the tree
enters only clean, which is the acceptance — dupes_test passes with
_perf in TREES.
