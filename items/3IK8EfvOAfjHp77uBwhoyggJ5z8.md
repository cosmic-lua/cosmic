Research pass: 2026-08-23, per skills/optimize ("running a research
pass"), driven by four round-1 agents (full-suite baseline read, cosmic
sweep, C-layer/startup sweep, literal-vs-json probe) plus a round-2
verification pass. Tree at main 0fb444d6-equivalent; binary o/bin/cosmic
built from it. All probe numbers below are SCOUTING numbers (os.clock/
shell loops, medians of 3+), not the _perf gate; accept/reject stays
with the harness.

## Problem
fs_walk_tree 354.74µs, 73KB/op vs sibling fs_files_tree 170.06µs,
2.77KB/op on the same 210-entry tree. cosmic/fs/walk.tl:75 calls
unix.stat(AT_SYMLINK_NOFOLLOW) unconditionally per entry, then
types.wrap plus a fresh Entry table — but the dirent d_type (second
return of DirHandle:read(), cosmic/fs/types.tl:111-118) already
answers the walk'\''s only own question ("is this a real directory").
Probe split (200 iters): raw d_type walk 81µs; walk+stat-per-entry
276µs; current fs.visit 429-447µs. Prototype lazy visit: 171µs when
the visitor never touches e.stat (−62%), 354µs when it does (−21%).

## This completes issue #469'\''s deferred pass (link, not duplicate)
whilp/cosmic#469 (closed completed 2026-07-05) gave files()/
collect_all() the d_type engine (fs_files_tree −55%) and explicitly
scoped walk()/collect() OUT: "walk() hands every visitor a full
WalkStat, per its documented contract … a future pass could revisit
them with an explicitly lazy-stat visitor API, but that'\''s a bigger,
contract-changing effort out of scope here." That engine lives today
in cosmic/fs/find.tl:246-283 (DT_DIR descends statless, DT_UNKNOWN
falls back to stat).

## Change (hypothesis)
Descend from d_type in walk.tl (stat fallback only on DT_UNKNOWN) and
make Entry.stat lazy — populated on first access (memoized accessor or
stat() method; an API decision for plan). Route fs.find (find.tl:
102-119, built on visit, paying stat-per-entry just for
e.stat:is_dir()) through the d_type path too. Expected: fs_walk_tree
−50-60% for stat-free visitors, −20% even stat-touching; fs.find
drops to find_iter-class cost. This walker underlies fs.remove_all
and --make'\''s tree scans.

## Constraints
Entry is a plain record — a metatable-backed lazy field is invisible
to field access but visible to pairs()/deep-copy; symlink-cycle
prevention preserved by construction (d_type never follows symlinks —
a symlinked dir is DT_LNK, same guarantee as AT_SYMLINK_NOFOLLOW);
walked.errors currently records stat failures for entries the visitor
never sees (walk.tl:97) — with lazy stat those surface only on access
or via the DT_UNKNOWN fallback: that errors-semantics delta is a
deliberate plan-phase decision. Pin with walk_test + a lazy-stat test.

## Risk
Medium — contract-adjacent (the exact wall #469 stopped at). Ambition
high: structural, benefits every tree traversal.
