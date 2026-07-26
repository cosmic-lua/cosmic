# 031 — `--build` retirement clock has no in-tree tracking

severity: low
type: cleanup (scheduled, untracked)
area: `_cli/args.tl`, `cmd/cosmic/main.tl`, `_cli/driver.tl`, `Makefile`

## issue

the design decides "`-c` wins; `--build` retired across two release cycles"
(make.md), and `-c` has shipped in a release. but nothing in the tree
tracks the clock: no issue, no comment naming the release after which the
flag dies, no deprecation notice in `--build`'s output. scheduled
retirements without a tracker become permanent residents.

`--build` cannot be deleted *yet*: the top-level `Makefile` drives every
recipe through `--build <verb>` because it runs the pinned bootstrap, which
predates `SHELL := cosmic -c`. the dependency chain is:

1. Makefile migrates to the generated rules (`-include o/cosmic.mk`, 3i),
2. then the `--build` longopt (`_cli/args.tl:36`), its parse branch
   (`cmd/cosmic/main.tl:297-300,417-419`), and `driver.build` become dead,
3. `-c` and `--build` share `_cli/build/` (the verb vocabulary), which
   stays — only the flag surface goes.

## suggested fix

open a tracking issue naming the two-release window and the deletion list
above; add a one-line deprecation notice to `--build`'s stderr ("--build is
deprecated; recipes should use -c") in the release that starts the clock.
when the clock expires, the deletion is mechanical.

## related

`_build/makefile_ratchet_test.tl:292`'s metacharacter-scanning ratchet is
in the same bucket: make.md calls it "unnecessary" under the closed
vocabulary, but it still guards the hand-written Makefile's real recipes
and only becomes deletable when that Makefile goes. mark it as
scheduled-to-die in place so the intent survives.
