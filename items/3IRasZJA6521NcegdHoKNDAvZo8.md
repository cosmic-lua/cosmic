Reviewing PR #1398 (item 3IQfhI33, the `assert(` census) surfaced that
D23's rule — "no other `cosmic.*` module may throw or exit", exempting
only `cosmic.check`, D22's CSPRNG, and an `-- assert:`-licensed
unreachable nil — is enforced against no census beyond `assert(`. A
broader census over the same file set (`git ls-files 'cosmic/*.tl'
'cosmic/**/*.tl' | grep -v '_test\.tl$\|_example\.tl$\|_benchmark\.tl$'`,
searched for `error(` and `os.exit(`, doc-comment lines excluded), run
2026-08-26 against PR #1398's head `9b7cee4d`, finds unrecorded sites in
five modules:

- `cosmic/hash.tl:100,105,133` — `digest`/`hmac` `error(...)` on an
  unknown algorithm and on a failed `GetCryptoHash`. The doc comment
  calls the first a deliberate caller-contract violation, which is
  D22's shape — and D23's amendment says that shape "still needs its
  own record". There is none.
- `cosmic/coverage/init.tl:129` — the `wrap` shim re-raises a failed
  `coroutine.resume` with `error(results[2], 0)`.
- `cosmic/child/init.tl:386,402` — `os.exit(127)` in the forked child
  after a failed `chdir`/`exec`.
- `cosmic/quicksand/box/run.tl:152,165,235,242,287` — `os.exit` on the
  post-`fork`/`exec` path.
- `cosmic/init.tl:41` — `os.exit` in the `cosmic.main()` entry helper.

Two distinct questions, and this item should settle both: which of
these are genuinely correct where they sit (a forked child cannot
return; an entry helper's caller is the OS — arguably the same
argument `cosmic/embed/init.tl`'s wrapper won in 3IQfhI33), and what
records or trailing justifications make that checkable rather than
remembered. Whatever the answer, the census that made it true today
has no gate: `--make lint` checks `-- cast:` and (per 3IRTkNx1) not
even `-- assert:`, and nothing at all looks at `error(`/`os.exit(`.
Consider whether the enforcement belongs with 3IRTkNx1's lint rather
than as a second pass.
