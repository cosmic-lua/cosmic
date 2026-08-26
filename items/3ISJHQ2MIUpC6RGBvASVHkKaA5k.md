definitions.lua is more honest than the generated types can carry:
bindings whose return shape depends on a LITERAL argument are
annotated with exact @overload lines that gentype erases to a union,
and the erasure is where two of the nine remaining from-any casts come
from. Evidence 2026-08-26 (cosmopolitan master 886741e0, cosmic main
b4ad036b): tool/net/definitions.lua:1859-1861 gives zip.open one exact
overload per mode ("r" -> zip.Reader?, "w" -> Writer?, "a" ->
Appender?) yet cosmic/zip.tl:222 must cast `handle as zip.Reader`
after calling with the literal "r"; definitions.lua:5486-5491 gives
unix.fcntl per-cmd overloads (F_GETFL -> integer, F_SETFL -> true, the
lock family) yet cosmic/fd.tl:187 casts `result as integer` for the
cmds it passes. Teal has no overloads, so no annotation fix helps; the
census's class-2 slot check does not flag these (each overload's tuple
is individually well-shaped). The unconstrained-cosmo fix, consistent
with the caller-errors-raise doctrine: split entry points whose
contracts are single-shape — zip.reader(path, opts) / zip.writer /
zip.appender beside the dynamic zip.open, and direct functions for the
fcntl cmds cosmic wraps — annotated exactly, conformance-probed, with
the dynamic originals kept for Lua callers. Each split kills the
downstream cast at its source.
