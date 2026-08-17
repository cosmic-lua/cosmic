Imported from whilp/cosmic#1223.

## Goal

G9 — the least tree that keeps its promises, via epic #1221.

Blocked by: #1222

## Change

Add the shared floor helper and move both `_build` gates onto it. They
already read and write `cosmic.literal`, so this slice is small by
construction — which is the evidence that the epic&#39;s format pick was right.

**`_tool/floor.tl` + `_tool/floor_test.tl`.** Two functions and an options
record, over `cosmic.literal`:

- `read(path: string, opts?: Options): {string: any} | nil, string` —
  `literal.parse_file`, forwarding `noun` and `on_duplicate`.
- `write(path: string, value: any): boolean, string` —
  `literal.format_file`.
- `Options` carries `noun` and `on_duplicate` and nothing else.

It lands in `_tool/` rather than `_build/` because `_tool/coverage/baseline.tl`
must require it in #1224 and `_build/` is repo-only. `_make/policy.tl`
already requires `_tool.coverage.baseline`, so a cross-tree require into
`_tool/` is established; `_build/` requiring `_tool/` is new but is the same
shape.

The helper owns bytes and resolution FORWARDING only. It holds no
comparison, no judgment, and no per-gate resolver of its own — whether 7
casts is worse than 5, and whether a missing name is a failure, stay in the
gates. That is the same split `_build/ratchet.tl` already makes between
reading a table and judging its rows.

**`_build/casts.tl` and `_build/public_surface.tl`** call the helper instead
of `cosmic.literal`. Four call sites, two per file: `baseline()` swaps
`literal.parse_file` for `floor.read`, `main()` swaps `literal.format_file`
for `floor.write`, and the `require(&#34;cosmic.literal&#34;)` line goes.

**Neither gate passes `on_duplicate`.** Both take #1222&#39;s refusal default,
and this CORRECTS the epic&#39;s sketch, which said the higher count wins for
casts. Two reasons it is wrong. The casts baseline is a ceiling, not a
floor — the gate fails when a file carries MORE casts than the baseline —
so &#34;higher wins&#34; is the direction that lets a merge silently permit casts
nobody reviewed. And both gates compare exactly in BOTH directions, so a
resolved duplicate can only ever produce a failure anyway; refusing at the
reader names the real problem (two branches disagreed about one key) and
points at the regen, instead of laundering it into a comparison failure
about a number neither branch wrote.

**`.gitattributes` gains `merge=union` for both `_build/*_baseline.tl`**,
with a comment recording the pairing: both files are one sorted
`[&#34;key&#34;] = value,` per line, so the common collision is two branches
touching alphabetically adjacent keys, and union yields the correct union
with no duplicate keys at all. A duplicate arises only when both branches
changed the SAME key, which is a real disagreement, and the reader refuses
it and names the regen command.

The measured facts this change rests on:

```facts
$ git ls-files | grep -c &#39;^_tool/floor&#39;
0
$ git ls-files &#39;*.tl&#39; | xargs grep -l &#39;require(&#34;cosmic.literal&#34;)&#39; | grep -c &#39;^_build/&#39;
2
$ grep -n &#39;literal\.\(parse_file\|format_file\)(&#39; _build/casts.tl _build/public_surface.tl
_build/casts.tl:97:  local data, err = literal.parse_file(path or BASELINE)
_build/casts.tl:124:  local ok, err = literal.format_file(BASELINE, counts)
_build/public_surface.tl:94:  local data, err = literal.parse_file(path or BASELINE)
_build/public_surface.tl:121:  local ok, err = literal.format_file(BASELINE, set)
$ wc -l &lt; _build/casts.tl
156
$ wc -l &lt; _build/public_surface.tl
150
$ grep -c &#39;merge=union&#39; .gitattributes
1
$ grep -rn &#39;require(&#34;_tool&#39; _make/policy.tl
12:local baseline = require(&#34;_tool.coverage.baseline&#34;)
$ git ls-files | grep -c &#39;^cosmic/embed/floor.tl&#39;
1
```

## Non-goals

`_build/casts_baseline.tl` and `_build/public_surface_baseline.tl` must be
byte-identical before and after for an unchanged tree — this is a machinery
swap, not a reformat, and a diff on either floor in this PR is a bug.

No change to either gate&#39;s comparison direction (casts still fails both
ways; the surface is still an exact set), to their failure wording, or to
what they measure — the failure contract and the regen verb are #1225.

No change to `cosmic/literal.tl`; #1222 already landed the contract this
slice consumes.

Do not touch `cosmic/embed/floor.tl`. It is the STRIP floor — what a
stripped artifact keeps — an unrelated meaning of the word that happens to
share a name. There is no module-path collision (`_tool.floor` versus
`cosmic.embed.floor`) and no reason to rename either.

Nothing in `_tool/coverage/` moves in this slice, and `.cosmic-coverage`
does not change. #1224 owns the coverage floor and is file-disjoint from
this one.

## Acceptance

- `bin/cosmic --make ci` ends `ci: PASS`.
- `bin/cosmic --make test _tool/floor_test.tl` ends `test: PASS (1 file)`,
  covering: a floor round-tripping through `write` then `read`; a duplicate
  key refused through `floor.read` with the key named; and an
  `on_duplicate` resolver forwarded through the helper, with its return
  value landing.
- Both `_build` floors regenerate byte-identically on an unchanged tree —
  this command prints exactly `clean`:
  `bin/cosmic --make run _build/casts.tl --baseline &gt;/dev/null &amp;&amp; bin/cosmic --make run _build/public_surface.tl --baseline &gt;/dev/null &amp;&amp; git diff --quiet _build/casts_baseline.tl _build/public_surface_baseline.tl &amp;&amp; echo clean`
- No `_build` file requires `cosmic.literal` any more — this command prints
  exactly `0` (its pre-change value is `2`, recorded as a fact above):
  `git ls-files &#39;*.tl&#39; | xargs grep -l &#39;require(&#34;cosmic.literal&#34;)&#39; | grep -c &#39;^_build/&#39;`
- `grep -c &#39;merge=union&#39; .gitattributes` is `3` (pre-change value `1`,
  recorded as a fact above).

## Enablement

Blocked by #1222 — the duplicate-key contract has to exist before a floor
can be declared `merge=union`, and this slice&#39;s whole resolution story is
that contract&#39;s default.

Beyond that, none needed. The one silent failure available here is a
reformatted baseline, and the byte-identity command in `Acceptance` is a
gate on exactly that. The one place an implementer would otherwise have to
reconcile a contradiction — the epic&#39;s &#34;higher count wins&#34; sketch for casts
— is decided in `Change` above with its reasoning, rather than left to be
rediscovered at review.


---
_Generated by [Claude Code](https://claude.ai/code)_