# 032 — import scans re-read and re-regex every source per consumer

severity: low
type: refactor (performance, consistency)
area: `_make/validate.tl`, `_make/deps.tl`, `_make/graph.tl`

## issue

three consumers each scan sources for `require` edges independently:

- `validate.check_imports` reads and regex-scans every source file,
- `deps.direct` re-reads files per closure node,
- `graph.project_mk` computes a transitive closure per compiled file —
  O(files × edges) `fs.read` + gmatch per facts generation.

beyond the wasted io on large projects, the duplication means the scanners
can *disagree* — and since 4a15b92 they do: the validator's scanner got
comment-stripping and a frontier anchor, `deps.direct` did not (see 039).
the planned fence work needs the same edge map a fourth time.

## where

- `_make/validate.tl:209` — the validator's scan.
- `_make/deps.tl` (`direct`) — the closure's scan.
- `_make/graph.tl:132-150` — closure-per-file in `project_mk`.

## suggested fix

one memoized edge map per model build: scan each source once (one shared
pattern — fixing 018 fixes it everywhere), cache `path → {imports}`, and
derive validator checks, dependency closures, and facts from that map.
closures then memoize per node instead of recomputing per root. the map's
natural home is beside the project model, computed lazily on first use.

## verification

facts output (`o/project.mk`) byte-identical before and after on this repo;
a coarse timing of `--make check` on the repo (359 files) should drop
measurably. no behavior change is expected except 018's, if the shared
pattern lands with it.
