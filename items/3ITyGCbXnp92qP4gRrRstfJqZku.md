## Capture

Widening the dup-body gate over cosmic (3IBuI5jY, PR #1440) surfaced
one cross-tree duplicate: _make/project.tl:98 carries a
byte-identical copy of cosmic/fs/find.tl:25's glob_to_pattern.

The fix needs a decision the widening PR deferred: glob_to_pattern
is internal to fs.find, and a module outside cosmic/ may only
require the public surface — so either the fs API grows a public
glob-to-pattern (a surface addition, weighed against G9's least-tree
promise), or project.tl's matching goes through an existing public
call (fs.glob / fs.find with a glob option), or the helper moves to
a spot both may require. Settle the shape, apply it, then add
"cosmic" to _build/dupes.tl's TREES and the test's reads line;
acceptance is dupes_test passing with cosmic in TREES.
