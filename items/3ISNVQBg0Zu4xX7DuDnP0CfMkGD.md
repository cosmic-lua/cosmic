Once D30 lands (item 3IRasZJA), the `-- throws:`/`-- exits:`
justification grammar it defines has no enforcement — the same gap the
`-- assert:` convention had between D23's amendment and 3IRTkNx1's
lint (PR #1401, accepted). Evidence, measured 2026-08-26 at main
`b4ad036b`: the census
`git ls-files 'cosmic/*.tl' 'cosmic/**/*.tl' | grep -v '_test\.tl$\|_example\.tl$\|_benchmark\.tl$' | xargs grep -nE '(^|[^_[:alnum:]])error\(|os\.exit\('`
(doc-comment lines excluded) finds 19 sites in 7 files outside
`cosmic/check.tl` (D23's module, 14 sites) and `cosmic/rand.tl`
(D22's, 6 sites), and nothing in `--make lint` looks at
`error(`/`os.exit(` at all. The rule wants the same token-exact walk
`check_assert_justification` uses (a naive grep double-counts
`process_error(` calls in `cosmic/_teal_engine.tl` and comment/string
occurrences), a module-level exemption for exactly `cosmic/check.tl`
and `cosmic/rand.tl`, and the trailing-or-line-above comment
acceptance the `-- cast:` lint already implements. Blocked on
3IRasZJA: the grammar must exist in the tree before a lint can demand
it.
