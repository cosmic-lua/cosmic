D23 says "**No other `cosmic.*` module may throw or exit.** The only
other sanctioned throws are D22's" — and the tree already has two
executable library throws that neither record covers:

- `cosmic/embed/init.tl:186` — `local chunk = assert(loadfile("/zip/main.user.lua"))`
- `cosmic/quicksand/proxy/serve.tl:374` — `if not listen_fd then assert(listen()) end`

Measured 2026-08-26:

```text
git ls-files 'cosmic/*.tl' 'cosmic/**/*.tl' \
  | grep -v '_test\.tl$\|_example\.tl$\|_benchmark\.tl$' | xargs grep -n 'assert('
```

reports 24 hits; 22 are inside `---` doc comments (usage examples for
`net`, `poll`, `sqlite`, `quicksand`, `sandbox`, and the narrowing
prose in `cosmic/_teal_hints.tl`). The two above are the only ones that
run.

Neither is the "unreachable nil" shape that item 3IQZalzf's D23
amendment licenses: `loadfile` on a user artifact can genuinely fail,
and `listen()` is a real runtime failure inside a server loop. So each
needs its own answer — return `nil, string` and let the caller decide,
or a recorded exemption arguing why no caller can — and D23's closed
list stays false until they get one.

Found while refining 3IQZalzf (D23's throw exemption list); filed
rather than folded in, because that item's Non-goals wall off "when may
library code throw" in general.

A second, smaller concern rides here: the amendment introduces a
`-- assert: <why the nil cannot occur>` comment convention mirroring
`-- cast:`, and nothing enforces it. `--make lint` already has the cast
check (`_tool/`'s pure lint checks) to model it on.
