## Capture

The narrow-* checker rules landed by 3ISJI4Lg's children obsolete the
workarounds they were built for, and the cold-build rule deferred
every retire to a pin that carries the rules. The sites, measured
2026-08-27 at main c78504bd:

- `cosmic/fs/types.tl:251-252` — `-- cast: metatable<any> is a
  nominal the checker refuses is-dispatch on`, plus its
  `type(mt) ~= "table"` guard: the #1439 entries make
  `if mt is {string: any} then` narrow directly (the cast's own
  comment is now false, which alone earns the retire).
- The guard-then-typed-local closure idiom in
  `cosmic/coverage/init.tl` (install_wrappers' `create_fn`/`exit_fn`
  locals, "Narrowing does not cross into a closure; these typed
  locals carry it") and `_tool/benchmark.tl`'s equivalent — the
  #1442 chunk-scan rule carries an is-fact into closures when the
  file never reassigns the name, so the idiom and its comment can
  simplify where the names qualify.

PULL-TIME GATE: `git merge-base --is-ancestor c78504bd <sha of the
tag bin/cosmic.pin names>` must hold (c78504bd is #1439's merge;
&#35;1442's d25e-era merge is behind it on main — verify both rules'
entries are in the pinned binary's own patch set by cold-checking one
probe file under `o/bootstrap/cosmic --check types`). At capture the
pin (2026-08-27-6b88a0d) predates both; the next release + pin bump
opens this. Slice shape: retire the sites, run `--make ci` (the
cold-build lane is the real gate), and update each site's comment to
say what the code now relies on.
