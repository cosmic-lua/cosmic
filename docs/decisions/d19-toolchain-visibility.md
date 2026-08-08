# D19 — what "public" means for toolchain modules, and the visibility lint

- **date:** 2026-08
- **context:** the visibility rule — position is the manifest, a module
  is public API exactly when it is `cosmic.<name>` with no `_` — existed
  but was unenforced, and two of its consequences were unsettled. First,
  build tooling outside `cosmic/` had grown requires of internal shards
  (`cosmic.fs.types` from eleven files, `cosmic.coverage.baseline` from
  `_make/policy.tl`), quietly freezing accidents of decomposition into
  API. Second, a family of modules that only the build ever calls —
  `testrun`, `example`, `benchmark`, `records`, `style`, half of
  `coverage`, plus `teal`/`format`/`doc` — squats on public `cosmic.*`
  names, and the rule as stated ("who requires it decides") pulled the
  other way from where they sit.
- **decision:** three parts.
  1. **The rule is now a lint** (`visibility`, in `_cli/visibility.tl`,
     run by `--check lint`): a file outside `cosmic/` may not require a
     cosmic-internal shard (`cosmic.<a>.<b>`, or any `cosmic._*`). What
     an outside caller legitimately needs, the public parent re-exports
     — `fs` re-exports its `Stat`/`Dir`/`WalkStat`/`FileInfo` types,
     `coverage` re-exports the ratchet (`gate`, `baseline_text`,
     `baseline_lowered`). `*_gen.tl` generators are exempt: a generator
     runs under the CURRENT binary before the tree rebuilds, so it may
     only use the surface that binary already embeds, and holding it to
     today's tree would break the bootstrap.
  2. **Toolchain modules stay public `cosmic.*` modules.** The strip
     floor forces `teal`, `format` and `doc` under `cosmic/` (the
     searcher requires `cosmic.teal`; a stripped artifact must boot),
     and the runners (`testrun`, `example`, `benchmark`, `records`,
     `style`, `coverage`) are the documented implementation of `--make`
     stages the artifact carries. Position is the manifest, so they are
     public; the obligation runs the other way — being public, they are
     held to the same standards (typed exports, honest errors, docs) as
     any battery, rather than moved to an internal tree the strip floor
     would forbid. *(Amended 2026-08, #992 — see below: the stated
     premise was wrong for most of the family, and part 2 is replaced
     by the `_tool/` rule.)*
  3. **Exports exist for callers, with one narrow exception.** An
     export with no callers is deleted, not documented (this record
     landed with the deletions of `unveil.apply`, `embed.FLOOR`,
     `doc.serialize`/`serialize_index`, `style.check_column_length`,
     `doc/gendoc.tl`, `quicksand.probe_ns`, `child.prepare_zip_exec`).
     The exception: a PURE helper may stay exported for its own unit
     tests when its doc marks it internal (`sys.normalize_host_os`,
     `teal.hint_for_message`, `sandbox.plan_landlock`,
     `quicksand.probe`, `searcher.tree`) — pure means no syscalls and
     no resources, so the worst misuse is a wasted call. A helper with
     side effects (probe_ns forked per call; prepare_zip_exec returned
     a raw fd) does not qualify, whatever its test value: its tests
     move behind the public surface or go.
- **consequences:** shard boundaries inside `cosmic/` can be refactored
  freely — nothing outside can see them, and the lint keeps it that
  way. Public parents grow small re-export blocks where outside callers
  need a shard's values; that block is the module's statement of what
  it supports. The exempted generators drift toward the oldest
  supported surface by construction; when a generator needs a new API,
  the change waits one pin cycle. The toolchain modules' names stay on
  the public surface and their polish debt (naming, type exports) is
  real API debt, tracked like any other.
- **amendment (2026-08, #992): a root `_tool/` tree; part 2 is
  replaced.** Part 2's stated premise — "the strip floor forces the
  toolchain modules under `cosmic/`" — was checked against the actual
  boot chain and is factually wrong for most of the family. The
  stripped boot chain is `embed/init.tl` → `searcher.tl` → (optional)
  `teal.tl`; it touches nothing else. Meanwhile `format`, `example`
  and `coverage.lines` hard-`require("tl")` at load, so they CANNOT
  run in a stripped artifact — they were dead payload the floor
  shipped. What actually forced them public was part 1's lint. So:
  - **`_tool/` is a root-level internal tree**, sibling of `_cli` and
    `_make`, for the modules only the toolchain calls: the runners
    (`testrun`, `example`, `benchmark`), the build's record grammar
    (`records`), the pure lint checks (`lint`, formerly
    `cosmic.style`), and — as the split lands — coverage's ratchet
    half and doc's extraction half. It is embedded in the cosmic
    binary (it is in the dispatcher's import closure) and never in
    user artifacts (it is not in theirs).
  - **Toolchain trees may require each other** (`_cli`, `_make`,
    `_build`, `_docs`, `_tool`, `cmd`): they ship and version as one
    toolchain, so a require between them freezes nothing a user can
    see. Part 1's lint is unchanged — none of them may require a
    cosmic-internal SHARD.
  - **`cosmic/` may not require a `_` tree.** The dependency points
    one way: batteries know nothing of the toolchain. Where the two
    share a constant (check's `EXIT_SKIP` beside records'), each side
    defines it and a toolchain test asserts agreement.
  - Part 3 (exports exist for callers) is unchanged and applies to
    `_tool/` modules like any others.
