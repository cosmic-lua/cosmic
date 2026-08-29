## Goal

G8 — the flow system. The ready bar's "measured, not inferred" rule
(`skills/work/decompose.md`) enumerates only STATIC facts: a file's
length, a pattern's match count, a function's location. Every example it
gives is answered by reading bytes. A spec sentence that says what a
verb DOES, which branch a condition selects, what a report prints, or
where a rule fires is a different kind of fact — and reading the source
to answer it is inference, not measurement. The bar cannot tell the two
apart, so behavioural claims pass it unmeasured, and they keep being
wrong.

## Evidence

Three instances, each re-verified for this spec on 2026-08-29. Each is a
claim about behaviour that read as obviously true, survived authoring
and at least one read, and was ALREADY FALSE about the code it
described when it was written — each fell the first time somebody RAN
the thing. Two carry a command that still falsifies them in the tree
today; the third was swept before it could merge and is pinned on
`main` by the tests that replaced it.

**1. `next`'s skipped count.** `skills/work/loop.md` said the count of a
session's own items in `check` "surfaces only when `check` is at its
limit and nothing else fires". Checkable now on `board`, from
`/home/user/cosmic/o/board`:

```
$ grep -c 'kind = "none"' _work/action.tl
4
```

Two of those four sit inside the single `if ph.reviewing > 0 then`
branch, and BOTH `:format(...)` the same `shape` count string; the WIP
comparison against `flow.LIMITS["check"]` only chooses which sentence
carries it. Reading the branch says "limit"; running the branch says
"always". Fixed on merged history — `git show 68f9fba2` on
whilp/cosmic, squashed into `main` as #1494.

**2. D35's firing region.** `docs/decisions/d35-dismissal-owes-evidence.md`
said the perf gate's restore fires "exactly when `N < f < 2r`". Swept
against the shipped `compare.diff` + `reproduce.restore` over
`f` in [0, 300] step 2.5 and `r` in [0, 20] step 0.5, the predicate
`f > 10 and f < 2r` disagrees with the code at **4097 of 4961 points** —
the real absorbed region is bounded by `[L(r), U(r)]` with an unbounded
upper arm, and is not even an interval. The corrected region and its
bisected band edges are on `main` today, pinned by
`_perf/reproduce_test.tl`'s `test_the_firing_region_is_where_the_record_says`
and `test_the_region_edges_are_where_the_record_says`; the false claim
never reached `main`, because the sweep ran before the merge.

**3. `builders` is read by `show`.** `3IYYwdp7`'s spec kept the
`builders` field on the grounds that it "stays written, read by `show`".
Checkable now, from `/home/user/cosmic/o/board`:

```
$ grep -c 'builders' _work/gitshow.tl
0
```

`show` does not mention the field. Widening the search has to name
which half of `_work` it covers: the bare `grep -rn 'builders'
_work/*.tl` matches 46 lines across 8 files, seven of them `_test.tl`.
Restricted to the machinery — the non-test half — it is one file:

```
$ grep -rl 'builders' _work/*.tl | grep -v _test
_work/item.tl
```

`item.tl` holds the record declaration, the parse and serialize halves,
the duplicate check, and `record_builder` — so the field is written and
persisted and rendered by nothing. The claim was one `grep -c` away and
nobody ran it.

**What this spec does NOT claim.** The item's filing cited a fifth
instance: a coordinator's own sweep reporting `loop.md` and `review.md`
"clean" of stale passages when they carried three between them. That is
a claim about a session's report, and a session's report leaves no
artifact in the tree or in git — there is nothing to re-run, so it is
not carried here as measured evidence. Its shape is nonetheless the one
this change's absence clause addresses: a narrow grep finding nothing is
a fact about the PATTERN, not about the tree.

**A claim that went STALE is a different failure, and is not carried
either.** An earlier draft of this spec listed `review.md`'s sentence
that a subagent naming nothing "derives the BUILDER's identity — and
`review` and `verdict` both REFUSE a session its own build, so an
unnamed reviewer cannot record a verdict at all". That sentence was
TRUE when it merged. `29011923` (#1494) added it at
2026-08-28T23:07:06Z, and both refusals were live at that moment:
`gitreview.tl` carried an unguarded `if flow.built_by(it, session)` and
`gitverdict.tl` its non-empty-session equivalent, `flow.built_by`
compared names by root, and the session ladder derives an inherited
`CLAUDE_CODE_SESSION_ID` — so a reviewer that named nothing did take
the builder's identity and was refused. `db981771` deleted both
refusals at 2026-08-29T03:16:28Z, 4h09m later, with no machinery change
in between; #1495 replaced the by-then-false sentence at
2026-08-29T04:35:33Z. Prose going stale under a machinery change is a
real failure, and it has its own items (`3IYoARc5`, `3IZaO4Vj`) — but
it is not a claim asserted without running, because no command run at
authoring time would have caught it. It does not count toward this
item's thesis.

**The item's own spec sidecar was wrong too.** At the moment this pass
opened, `items/3IZ0nP5RQEOKtnuYUdd9j6E4POu.md` held a verbatim copy of
`3IVgswRI`'s spec — a different item, about `_cli/returns.tl`'s type
grammar — pasted at `new` and never read against the title. It passed
every check the bar runs, because the bar reads section headings.

## Change

Two files, both `main` prose. No code.

**`skills/work/decompose.md`.** Under the ready bar, immediately after
the existing `**measured, not inferred.**` paragraph and its
`naming the command beside its output` follow-on, add one paragraph
that extends the same rule to behavioural facts. It must say, in the
file's existing voice and to its 90-column house style:

- what kind of fact this covers: what a verb prints, which branch a
  condition selects, what a report contains, where a rule fires, what a
  gate refuses. Reading the source to answer one of these is inference.
- the discipline: the spec carries the command AND the observed output
  it produced, not a description of what the code should do. A
  behavioural claim with no output pasted beside it has not been
  measured.
- the tell a refiner can apply: any spec sentence whose subject is a
  verb, a gate or a report and whose tense is present — "`next`
  surfaces …", "`show` reads …", "the restore fires exactly when …",
  "`verdict` refuses …" — is a prediction until a command has produced
  it.
- absence is behavioural too: a grep that returns nothing establishes
  that the PATTERN matched nothing, not that the thing is absent. Widen
  the pattern, or name what the narrow one could miss.
- the honest limit, stated plainly: nothing enforces this.
  `gitboard check` lints that the five sections are present and
  non-empty; it cannot tell an executed claim from a plausible one, and
  no static check can. This is a rule the refiner applies and the
  reviewer checks, and the command-with-output written beside the claim
  is its only artifact.

Then add one bullet to the `## anti-patterns` list — **behaviour by
reading** — naming the failure and citing D35's `N < f < 2r` as the
worked instance, in the same shape as the existing `acceptance by
vibes` bullet's citation of PR #1264.

**`skills/work/review.md`.** The bounce clause beginning `a bounce that
quotes a wrong or unmeasured tree-fact` names only tree-facts, which is
the same static-only framing. Widen that one sentence so an unmeasured
BEHAVIOURAL claim is the same named countermeasure, and so the fix it
demands is the command with its observed output. Do not restructure the
paragraph or touch the `--enable` sentences around it.

Measured now, from `/home/user/cosmic/o/wk-3IZ0nP5R`:

```
$ wc -l skills/work/decompose.md skills/work/review.md
  246 skills/work/decompose.md
  309 skills/work/review.md
  555 total
```

Both have ample headroom under the 500-line cap; the `.md` files are not
subject to it in any case.

The rule is asserted in exactly three places, inventoried with:

```
$ grep -rn "tree-fact\|measured, not inferred\|measured claim" skills/ docs/ AGENTS.md
skills/work/SKILL.md:341:   every measured claim carries its command (the ready bar demands
skills/work/review.md:290:a bounce that quotes a wrong or unmeasured tree-fact names its
skills/work/review.md:292:without measuring it — and the fix is a freshly measured claim, with
skills/work/decompose.md:175:**measured, not inferred.** every tree-fact the spec relies on (a
```

The third, `SKILL.md`'s pull-time re-measure step, needs no edit: it
says every measured claim carries its command and the claiming session
re-runs it, which a behavioural claim's command satisfies unchanged.

## Non-goals

- **No change under `_work/**`.** The board machinery's stale comments —
  including the `gitverdict` doc comment named in the staleness note
  above — belong to `3IZaO4Vj`. This item touches `main` prose only.
- **No new gate, and no prose implying one.** `_work/spec.tl`'s section
  lint is unchanged and `gitboard check`'s output is unchanged. A static
  check cannot distinguish an executed claim from a plausible one; the
  paragraph must say so rather than gesture at enforcement.
- **No change to the five ready-bar section names** or to what
  `gitboard check` requires. The rule lives inside the existing
  `measured, not inferred` discipline, not as a sixth section.
- **No rewrite of the worked example** and no change to the existing
  `measured, not inferred` paragraph's own sentences — the new paragraph
  extends it, it does not replace it.
- **No inline `path:line` citations** in either file. `docs/guides/lint.md`'s
  `doc-citation` rule refuses the live inline form; name the symbol or
  quote it as a fenced citation.
- No edit to `skills/work/SKILL.md`, `loop.md` or `parallel.md`.

## Acceptance

- `bin/cosmic --make ci` ends `ci: PASS`.
- The new paragraph exists and states the limit. Both must be 1:

  ```
  $ grep -c 'run it, don.t read it' skills/work/decompose.md
  $ grep -ci 'no static check' skills/work/decompose.md
  ```

  Both return 0 today.
- The anti-pattern bullet exists:

  ```
  $ grep -c 'behaviour by reading' skills/work/decompose.md
  ```

  Returns 1; returns 0 today.
- The review-side clause covers behaviour. This returns 1; it returns 0
  today:

  ```
  $ grep -c 'unmeasured tree-fact or behavioural claim' skills/work/review.md
  ```

- No inline `path:line` citation is introduced. `bin/cosmic --make lint`
  ends `lint: PASS (N files)` with no `doc-citation` diagnostic; today
  the same command passes, so this is a no-regression check.
- The three-site inventory is unchanged in count — the rule is extended
  where it lives, not relocated:

  ```
  $ grep -rl "tree-fact\|measured, not inferred\|measured claim" skills/ docs/ AGENTS.md | wc -l
  ```

  Returns 3 (the three files above), as it does today.

## Enablement

none needed. The change is prose in two `main` files that already exist;
no blocker items, no new dependency, no tooling. `bin/cosmic --make ci`
already gates `skills/**` markdown through the `doc-citation` lint, and
the four Evidence commands above are runnable today from the two
checkouts named beside them.
