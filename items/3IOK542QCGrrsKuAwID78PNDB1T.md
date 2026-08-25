G3 — decide the **untyped-probe fallout** class of `from any` casts: 15
of the tree's 192, measured 2026-08-25 against `d3e59de7` and mapped in
`docs/design/casts.md`. A test deliberately re-types an API to feed it
input the real signature forbids (`cosmic/quicksand/box/run_test.tl:114`
re-types `quicksand.new` as `function(any): any, any` to pass a bad
promise), or reaches a surface the type deliberately does not describe
(`cosmic/surface_test.tl:92`, the `__close` metamethod reads in
`cosmic/sqlite/close_test.tl`). Everything read off such a call, the
error message especially, is then `any`. The files and their site
counts: cosmic/fd_read_test.tl (1), cosmic/fs/find_close_test.tl (1),
cosmic/quicksand/box/init_test.tl (7), cosmic/quicksand/box/run_test.tl
(1), cosmic/sqlite/close_test.tl (2), cosmic/surface_test.tl (3). The
two halves want opposite answers. The invalid-input probes all want the
same thing — assert on an error message — so one test helper that makes
the untyped call and hands back a typed `(nil, string)` closes them. The
surface probes should NOT close: a test asserting that a type
deliberately hides something is doing its job, and its cast is honest.
That half is a candidate for a `-- cast:` reason of its own, which makes
this item partly a decision about what the reason vocabulary should say
before it is any code. The closure diff must lower the affected rows in
`_build/casts_baseline.tl` — run exactly the regen command the gate
prints and commit the result.
