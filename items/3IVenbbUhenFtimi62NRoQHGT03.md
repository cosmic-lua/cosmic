Probing the carried tl patch by putting a modified `tl.lua` on
`package.path` silently measures the SHIPPED checker instead, and the
run reports a confident, wrong answer.

`require("tl")` inside the cosmic binary does not consult
`package.path`: the cosmic searcher resolves `/zip/tl.lua` from the
binary's own zip regardless of what the script sets. So the standard
way to test a patch change — copy `o/3p/tl/tl.lua`, edit it, point
`package.path` at the copy, run the checker — loads the embedded
checker and never touches the edit.

The failure is silent and it inverts the conclusion. Observed
2026-08-27 while verifying `3IVQJa0b`: a reverse-apply pass measured
the shipped checker, saw the patched behaviour, and concluded the
behaviour was stock tl rather than the patch's doing — the exact
opposite of the truth. Nothing errored; the numbers simply described a
different binary than the one the session believed it was running.

The working recipe is to preload the module so the searcher never
runs:

    package.loaded["tl"] = dofile("/path/to/modified/tl.lua")

This matters because reverse-applying a patch entry and re-running the
checker is the project's standard proof that a test guards something —
it is how `3IVL5DSr`, `3IVL4phw` and `3IVQJa0b` each established their
guarantee. A technique that can silently measure the wrong checker sits
underneath several of those proofs, and a session that reaches for the
obvious `package.path` form gets no signal that it has done so.

Worth deciding: whether the recipe belongs in prose a session will
actually read when it goes to probe the checker — the tl-patch material
in AGENTS.md, or `_make/patch.tl`'s own header, where someone changing
a patch entry is already looking — rather than being rediscovered per
item. A helper that does the preload correctly would be stronger than
prose, since it removes the wrong form from reach instead of warning
against it.
