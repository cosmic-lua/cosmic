## Evidence

Found by the fresh-context review of cosmic-lua/cosmic#1618 (item
3IkoLMdh). Nothing in `_build/*_test.tl` or `_docs/*.tl` checks that a
backtick path reference in the prose docs names a file that exists,
so a moved or misnamed target survives every gate. It has recurred:
`docs/goals.md:8` pointed the paired-comparison method at
`skills/work/SKILL.md` (fixed by #1618), and D25 pointed at
`skills/work/decompose.md` before that file existed (#1610 created it,
#1615 gave it the section). Both were caught by a human reading, not a
gate. Re-measure at pull time on `origin/main`:

```
grep -ohE '`[A-Za-z0-9_./-]+\.(md|tl|lua|mk|yml)`' docs/*.md docs/**/*.md skills/*/*.md \
  | tr -d '`' | sort -u | while read p; do [ -e "$p" ] || echo "missing: $p"; done
```

(measure what it prints; a path that is a pattern or an example
rather than a reference is what the Change's allowlist is for).

## Change

`_build/doc_paths_test.tl` (runner mode): for every `docs/**/*.md`
and `skills/**/*.md`, every backtick span that looks like a repo path
with a known extension (`.md .tl .lua .mk .yml .sh`) and contains a
`/` must name a file or directory in the tree, or match an explicit
allowlist in the test of pattern-shaped spans (globs, `o/` outputs,
`<name>` placeholders). Fail naming file:line and the missing path.
The first run's report is this PR's fix list: correct each stale
reference in place (prose only) or allowlist it with a one-line
reason; the allowlist starts as small as the measured run allows.

## Non-goals

- No link checking of URLs; paths only.
- No change to what any doc says beyond fixing a stale path.
