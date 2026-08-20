## Evidence

2026-08-20 audit at main 0b2907b9, by reading `_cli/reads_lint.tl:46-52`
(landed #1279). (1) ANY `--- reads:` header — even one naming a
directory unrelated to what the glob enumerates — silences ALL
`fs.glob` diagnostics in the file; the rule cannot verify coverage,
so a stale or wrong declaration recreates exactly the cached-PASS
incident (#1227) the lint was landed to prevent. (2) The trigger
`line:find("fs%.glob%s*%(")` matches inside comments, string
literals, and identifiers ending in `fs` (`myfs.glob(`) — the
allowlist entry for reads_lint_test.tl exists precisely because of
the string case. All three current fs.glob test callers are handled
correctly today, so this is a robustness gap, not a live FP. Fix
shape: tie each declaration to the glob argument it covers, and
anchor the trigger to a call position.
