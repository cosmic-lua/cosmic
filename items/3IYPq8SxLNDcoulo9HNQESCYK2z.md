## Goal

G3 — an honest type layer, no escape hatches. G3's frame is the mechanism
that polices an unchecked assertion until the gap closes; the per-site
`-- cast: <reason>` justification is its worked example. A live inline
`path:line` citation is the same hole in prose: a positional claim about
today's tree that `--check lint` accepts whatever it points at. Retire the
form, so a doc's positional evidence is either verified or not made.

## Evidence the slice rests on

Measured 2026-08-28 against `origin/main` `40776231`, with the binary at
`o/bin/cosmic`.

**The inline check bounds the line number and nothing else.** In
`_cli/citations.tl`, an INLINE reference (a whole backticked span that is
nothing but `path:line`, `_cli/citations.tl:92-107`) reaches only
`check_one` (`_cli/citations.tl:164-188`): path exists (`fs.is_file`,
line 170) and `cite.last > #lines` (line 181). A FENCED reference (a
`-- path:line` comment as a block's first line) additionally reaches
`check_quote` (`_cli/citations.tl:197-210`), which compares the trimmed
quoted line against the trimmed source line. Confirmed by running the
gate, editing only the line number in `docs/design/make/resolution.md:231`:

    :163 (today, wrong)  -> Style check passed, exit 0
    :175 (the real line) -> Style check passed, exit 0
    :400 (absurd, in a 405-line file) -> Style check passed, exit 0
    :999 (past EOF)      -> doc-citation ... past end of file, exit 1

**The defect is the class, not the site.** Nine backticked `path:line`
citations live outside the one snapshot document. Six of the nine name a
line that does not hold what their sentence says:

| site | cites | what is really there | where the claim lives |
| --- | --- | --- | --- |
| `docs/agent-usability.md:47` | `_cli/require_hints.tl:166` | `end` | `is_module_not_found`, line 200-202 |
| `docs/decisions/d34-reproduction-against-remeasured-baseline.md:13` | `.github/workflows/release.yml:184` | `--bin o/perf/prev/cosmic-lua` | `--baseline-bin`, line 188 |
| `docs/design/casts.md:55` | `cosmic/json.tl:135` | `--- @return ...` | `decode_object` declared line 137 |
| `docs/design/casts.md:56` | `cosmic/json.tl:155` | a doc comment | `decode_array` declared line 157 |
| `docs/design/make/resolution.md:231` | `_perf/run.tl:163` | the `load_module` header | `pcall(require, name)`, line 175 |
| `docs/guides/testing.md:132` | `cosmic/net/connect_test.tl:247` | `end` | `net.listen_tcp("127.0.0.1", 0)`, line 153 |

Two more are stale in substance: `docs/agent-usability.md:62` names a
rendering `fd: number, events: Events)` that no longer exists in
`cosmic/poll.tl`, and `docs/decisions/d28-shape-combinators.md:10` cites
the ten-cast run in `_eval/score.tl` that `shape.into` replaced. Only
`docs/decisions/d18-step-skip.md:98` still lands. Every one of the nine is
green today.

`docs/design/casts.md:56`'s citation is additionally INVISIBLE to the
rule: its sentence wraps a code span across a line break, so the
per-line backtick pairing in `_cli/citations.tl:268` pairs the wrong
backticks and never sees the span. The lint recognizes 8 of the 9.

**Blast radius.** Across the 97 markdown files in `lint_sources`, the
lint's own recognizer sees 25 inline citations: 17 in
`docs/design/nil-flow.md` — the tree's one `Measured against` snapshot,
exempt by design and untouched here — and 8 live. The grep below matches
25 LINES: 16 in that snapshot and 9 live. The two counts differ in both
directions and both differences are understood: the grep also catches the
wrapped `docs/design/casts.md:56` span the lint misses, and one
`nil-flow.md` line carries two citations the grep counts once. Nine live
sites are the whole conversion.

    git grep -nE '`[A-Za-z0-9_./-]+\.[A-Za-z0-9_-]+:[0-9]+(-[0-9]+)?`' \
      -- '*.md' ':!docs/design/nil-flow.md' | wc -l   # 9

**The rejected slice.** Fixing this one citation — repointing it to `:175`
— re-creates the defect on contact. PR #1490 (`refs/pull/1490/head`,
`894c33ba`, open) deletes eleven lines above the call. Merging the repoint
against it is textually CLEAN (`git merge-tree --write-tree --messages`
returned tree `51c66155`, exit 0, no conflict message), and in that merged
tree `_perf/run.tl:175` is a blank line while `pcall(require, name)` sits
at `:164`. A repoint therefore buys a green gate and a wrong number, by
exactly the mechanism that produced the bug. Converting this one site to a
fenced citation is the mirror failure: the same merged tree makes the
fenced form fail loudly (`the quoted line is not _perf/run.tl:175 —
document has ..., source has ``), which is correct behaviour but makes the
item a hard ordering dependency on #1490 for one line of prose. Closing
the class is the only slice that costs the same and holds.

## Change

Three edits, one rule.

**1. `_cli/citations.tl` — refuse the live inline form.** In
`check_citations`'s inline branch (`_cli/citations.tl:267-275`), a
recognized inline citation in a document that is NOT a snapshot produces
exactly one `doc-citation` finding and does not call `check_one`; a
snapshot document's inline branch is unchanged (`check_one` runs and
checks the path only, `_cli/citations.tl:177-179`). The rule applies to
every path, `o/`-prefixed ones included — a position nothing can read is
the objection, and a generated file's position is less readable, not
more. Keep the existing column (`line:find(span, 1, true) or 1`). The
finding's message, verbatim, formatted with the citing file, its line,
the citation text and the cited path:

    <file>:<line>: inline citation `<text>` pins a line nothing
    verifies — this check can only tell that <path> is that long. Quote
    it as a fenced citation (a `-- <path>:<line>` comment as the code
    block's first line, then the line itself, whose text is compared),
    or drop the `:<line>` and name the symbol in prose. A document
    describing a past commit says so with a `Measured against ` line.

Rewrite the module header comment (`_cli/citations.tl:11-17`), which today
says the inline form is checked "at the strength it admits"; it now says
the inline form admits no strength in a live document and is refused
there. Measured now: `wc -l _cli/citations.tl` is 288, 212 lines under the
500-line cap.

**2. The nine sites — drop the line span, name the symbol.** Keep every
sentence's substance; remove only the `:<line>` and, where the sentence
needed the number to point at something, name that something. Exactly:

- `docs/agent-usability.md:47` — `` `_cli/require_hints.tl:166` matches ``
  becomes `` `_cli/require_hints.tl`'s `is_module_not_found` matches ``
- `docs/agent-usability.md:62` — `` (source: `cosmic/poll.tl:41-46`). ``
  becomes `` (source: the `Poller` record in `cosmic/poll.tl`). ``
- `docs/decisions/d18-step-skip.md:98` — `` (`_tool/testrun.tl:54-68`), ``
  becomes `` (`_tool/testrun.tl`'s child-environment loop), ``
- `docs/decisions/d28-shape-combinators.md:10` — `` `_eval/score.tl:194`
  is the `` becomes `` `_eval/score.tl`'s `load_meta` is the ``
- `docs/decisions/d34-reproduction-against-remeasured-baseline.md:13` —
  `` `.github/workflows/release.yml:184`), `` becomes
  `` `.github/workflows/release.yml`'s perf-compare step), ``
- `docs/design/casts.md:55-56` — the two citations collapse into one path:
  `` `cosmic/json.tl` declares `decode_object(str): {string: any} | nil,
  string` and `decode_array(str): {any} | nil, string`, so a ... ``
- `docs/design/make/resolution.md:231` — `` `_perf/run.tl:163` is that
  case in this repo — `` becomes `` `_perf/run.tl`'s `load_module` is
  that case in this repo — ``
- `docs/guides/testing.md:132` — `` the precedent is
  `cosmic/net/connect_test.tl:247` (`net.listen_tcp("127.0.0.1", 0)`) ``
  becomes `` the precedent is `cosmic/net/connect_test.tl`
  (`net.listen_tcp("127.0.0.1", 0)`) ``

Reflow each paragraph to the house 90 columns after editing.

**3. `docs/guides/lint.md` — teach the rule.** Add a `## doc-citation`
section between `## visibility` (line 335) and `## running one rule's
worth of output` (line 344), in the shape the other sections use: what the
rule checks, the diagnostic, the fix. It must say that both forms check
the path, that only the fenced form compares text, that a live inline
`path:line` is refused, and that a document describing a past commit
declares itself with a `Measured against \`<sha>\`` line. Show the refused
form and its diagnostic inside an UNTAGGED fence (inline spans inside a
fence are never scanned, so the bad example cannot flag the guide), and
show the fenced form as this exact self-citation, which is stable and true:

    -- docs/guides/lint.md:1
    # Lint Rules

Measured now: `wc -l docs/guides/lint.md` is 353, 147 lines under the cap.

**4. `_cli/citations_test.tl` — the rule's tests.** Measured now: 171
lines, 329 under the cap. Six existing tests change verdict or message and
three must not move:

- `test_inline_citation_that_resolves` (`_cli/citations_test.tl:43-47`)
  asserts 0 findings for `` `src/sample.tl:2` ``, a path that exists at a
  line that exists. Rewrite it as **`test_live_inline_citation_is_refused`**:
  the same document must now yield exactly one `doc-citation` finding whose
  message contains `pins a line nothing verifies` and `fenced citation`.
  This is the mutation test — it fails before the change and passes after.
- `test_range_inside_the_file` and `test_generated_citation_is_skipped`
  flip from 0 findings to 1; rename each to say the inline form is refused.
- `test_inline_citation_past_end_of_file` and
  `test_inline_citation_naming_no_file` still assert one finding; their
  message assertions become the refusal message.
- `test_snapshot_leaves_positions_unjudged` (0 findings) and
  `test_snapshot_still_checks_paths` (one `names no file`) must NOT change
  — they are the guard against the rule over-firing on snapshots.
- The fenced tests, `test_prose_span_that_merely_contains_a_path` and
  `test_a_document_with_no_citations` are untouched.

If the coverage ratchet or the size ratchet complains, run exactly the
regen command the failure message prints and commit its result. Do not
weaken a gate any other way.

## Non-goals

- **Do not repoint any citation to a corrected line number, and do not
  convert any of the nine sites to the fenced form.** Both re-create the
  defect against PR #1490, proved above. `_perf/run.tl` is the file under
  #1490; the treatment for `docs/design/make/resolution.md:231` is the
  symbol name, and that is why this item carries no `blocked_by`.
- **Do not touch `docs/design/nil-flow.md`.** It is the tree's one
  `Measured against` snapshot; its 16 matching lines are exempt by design
  and must still be 16 after.
- **Do not change `_cli/lint.tl`.** The `.md` wiring already exists at
  `_cli/lint.tl:375-379`, and the file is 419 lines against the 500 cap.
- **Do not widen the recognizer.** No cross-line code-span pairing, no
  existence check on bare backticked paths, no sweep for `path:line`
  outside a backticked span — the last would flag the quoted runtime
  traceback at `docs/agent-usability.md:132`, which is not a tree
  citation. The wrapped-span blind spot is filed separately.
- **Do not rewrite the substance of the nine sentences.** The prose in
  `docs/agent-usability.md` and `docs/decisions/d28-shape-combinators.md`
  describes a tree that has since moved; correcting that is other work.
  Remove the line span, name the symbol, stop.
- **Do not add a decision record**, and do not change the `Measured
  against` snapshot mechanism or the `doc-citation` rule name — the rule
  name is what the gate prints and what the guide indexes.
- **Do not tag any new fence `teal`.** `_build/snippets_test.tl` compiles
  every `teal` fence in the tree at full strictness and holds it to the
  formatter; the guide's new examples are markdown, so they stay untagged.

## Acceptance

Every value below was measured 2026-08-28 at `origin/main` `40776231`.

- `bin/cosmic --make ci` ends `ci: PASS`.
- `bin/cosmic --make test _cli/citations_test.tl` passes, including
  `test_live_inline_citation_is_refused`.
- The mutation, runnable from the repo root and writing nothing into the
  tree:

      printf 'See `cosmic/json.tl:1` here.\n' > "${TMPDIR:-/tmp}/cite.md"
      bin/cosmic --check lint "${TMPDIR:-/tmp}/cite.md"

  Today this prints `Style check passed: /tmp/cite.md` and exits 0. After
  the change it must exit 1 and print a line containing `doc-citation`.
- No live inline citation remains:

      git grep -nE '`[A-Za-z0-9_./-]+\.[A-Za-z0-9_-]+:[0-9]+(-[0-9]+)?`' \
        -- '*.md' ':!docs/design/nil-flow.md' | wc -l

  9 today, must be 0.
- The snapshot document is untouched:

      git grep -cE '`[A-Za-z0-9_./-]+\.[A-Za-z0-9_-]+:[0-9]+(-[0-9]+)?`' \
        -- docs/design/nil-flow.md

  prints `docs/design/nil-flow.md:16` today and must print it after.
- The rule is served by the binary: `bin/cosmic --docs guide.lint | grep -c
  doc-citation` is 0 today and must be at least 1.
- Caps hold: `wc -l _cli/citations.tl` ≤ 500 (288 today), `wc -l
  _cli/citations_test.tl` ≤ 500 (171 today), `wc -l docs/guides/lint.md`
  ≤ 500 (353 today).

## Enablement

None needed to start; this slice IS the enabler, and it lands its three
tiers together because the rule is worthless without a clean tree and a
builder cannot be told the rule any later than the message that fires it.

- **core** — the lint rule, and its message, which names both ways out
  (fence it, or drop the line and name the symbol) so a session that
  trips it does not have to read `_cli/citations.tl` to recover.
- **docs** — the `## doc-citation` section in `docs/guides/lint.md`,
  which ships in the binary and is what `cosmic --docs guide.lint` serves;
  the rule is the only one besides `reads-declaration` that the guide does
  not currently enumerate.
- **not blocked.** PR #1490 (`894c33ba`) is open over `_perf/run.tl`, the
  file this item's flagship citation names. `git merge-tree --write-tree
  --messages` against `refs/pull/1490/head` returns exit 0 with no conflict
  for the chosen treatment, and the treatment leaves no line number to go
  stale in the merged tree — so no `blocked_by` edge. The two rejected
  treatments would each have needed one.
