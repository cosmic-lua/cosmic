G3, under `3IOK4SZH` — the second of the dynamic-value boundary's three
closures: the sites where the value's type IS knowable and an API simply
declares `any`. Decomposed 2026-08-25 into two children after re-measuring
against `47adef2c` (`git ls-files '*.tl' | xargs grep -n -- "-- cast:
.*from any"`).

**The open question this item carried is settled: no typed-require helper
is needed.** The item asked whether the "require a non-literal name, cast
to the module's record" shape would collapse into the helper
`3IOK4SZH`'s version-lookup child produced. It did not, and it does not
need to: that child (PR #1382) produced a specific export,
`cosmic.version_info()`, and what closed its casts was not the export but
the `is` guard behind it — `info is VersionInfo` over `any`, one
`type(x) == "table"` test. Every one of these sites already NAMES the
record it wants, one line later, in the `as` it performs. So the same
guard closes each of them where it stands, with no helper, no new public
surface, and no signature change.

That reframes the cut. The real split is not literal-vs-dynamic module
names; it is **where the `any` comes from**:

- **`3IR…` (guard half)** — the value arrives as `any` from a boundary the
  code does not own: a `require` the checker cannot resolve, a `pcall`ed
  chunk, a callback context an API types `any` on purpose. Twelve casts in
  nine files, all closed by `is` at the point of use. Nothing is
  redeclared, so the slice is mechanical and uniform.
- **`3IR…` (declaration half)** — the `any` is in one of OUR OWN
  signatures, inside `cosmic.sqlite` and `cosmic.fetch`. Eight casts in
  three files. Closing these means changing a public module's contract,
  which is four open decisions (a union parameter's reach through its
  callers; whether `Database` can be shared without re-creating the import
  cycle that made `any` the answer; whether `fetch`'s façade record can
  name the real `Options`/`Response`), so that child stays in `plan` until
  they are settled.

The two are file-disjoint by construction — they share only
`_build/casts_baseline.tl`, whose conflict is the mechanical regen the
gate prints — so they can run in parallel.

Verify when both children end: `git ls-files '*.tl' | xargs grep -h --
"-- cast: " | grep -c "from any"` is `99` today and should read `79`, with
`_perf/run.tl:132` (`rawget(arg, -1) as string`, an `or`-chain rewrite
rather than a guard) named as the one deliberate leftover inside the
touched files.
