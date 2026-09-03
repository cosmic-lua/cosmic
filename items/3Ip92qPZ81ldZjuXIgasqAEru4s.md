## Evidence

`_types/tlast_gen.tl:14` requires `_types/tlast.tl`, whose `:20`
requires `cosmic.child` solely for `dump_via_base` (tlast.tl:271-300):
one `child.run({DUMPER, prog, srcfile, out}, {stdout = "inherit",
stderr = "inherit"})` that checks `r.ok`. That import pulls
`cosmic/child/{init,io,fast,types}.tl`, `cosmic/fd.tl`, `cosmic/poll.tl`,
`cosmic/stream.tl`, `cosmic/time.tl` into the generator's closure,
which `_make/generate.tl:145-217` strict-compiles before the graph
exists (walk of `require()` from `_types/tlast_gen.tl`, `cosmo.*`
excluded: 24 files). This is the closure a cold build broke on when
`cosmic/child/init.tl:161,243` were adapted to `unix.wait`/`unix.pipe`'s
new table shapes. It is NOT the only exposed closure —
`_types/types_gen.tl`'s 26-file closure carries `fs/ops.tl`, `fs/dir.tl`,
`fd.tl`, `proc/*.tl` — so this item reduces exposure; the unblocker is
`generate-seed-types`.

## Change

`_types/tlast.tl`: replace `child.run` in `dump_via_base` with
`os.execute` over an argv-quoted command — `DUMPER`, `prog`, `srcfile`,
`out` are all paths the function itself created under `dest`, none
user-supplied, so shell quoting is a fixed `"%q"`-style wrap of four
known strings; success is `os.execute` returning `true`. Chosen over
moving the dump into `types_gen`'s phase because that phase's closure
is also exposed and the dumper is `o/3p/cosmos/lua` either way; chosen
over raw `cosmo.unix` fork/exec because that reintroduces the very
bindings (#340 wait, #328 pipe) whose shape is changing. Drop the
`cosmic.child` require; keep `cosmic.fs` (its `temp_dir`/`write`/`read`
are unchanged bindings on the read/write path this function needs).

Re-run the closure walk in the PR description to show `cosmic/child/*`,
`cosmic/fd.tl`, `cosmic/poll.tl`, `cosmic/stream.tl`, `cosmic/time.tl`
left the closure. `_types/tlast_test.tl` already calls `generate`
directly; it stays the proof that the dump still yields loadable
bytecode.

## Non-goals

Not the adaptation (`A3HK_gamw`), not `_make/generate.tl`, not
`types_gen`'s closure.
