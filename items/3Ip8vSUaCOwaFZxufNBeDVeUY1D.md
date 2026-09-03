## Evidence

Measured 2026-09-03 against `origin/main` (`96afd807`).

    git show origin/main:docs/design/cast-sites.tsv | awk -F'\t' '$3=="map view of a declared value"{print $1":"$2}'
    cosmic/quicksand/box/init_test.tl:143,145,146,148
    cosmic/sandbox/init_test.tl:192,193,197
    cosmic/sandbox/landlock_net_test.tl:127,128,132
    cosmic/sandbox/landlock_scope_test.tl:87,88,92
    (+ 4 library rows: coverage/init.tl 92,93; fetch/init.tl 388; box/merge.tl 135 — the tail item)

The three sandbox files carry the same helper, copied
(`git show origin/main:cosmic/sandbox/init_test.tl | sed -n '189,199p'`):

    local function with_mock_landlock(mocks: {string: function}, body: function(): boolean)
      local saved: {string: function} = {}
      for name, fn in pairs(mocks) do
        saved[name] = (landlock as {string: function})[name]; -- cast: record to map probe
        (landlock as {string: function})[name] = fn -- cast: record to map probe
      end
      local ok, err = pcall(body)
      for name, fn in pairs(saved) do
        (landlock as {string: function})[name] = fn -- cast: record to map probe
      end
      if not ok then error(err, 0) end
    end

`cosmic/quicksand/box/init_test.tl:140-150` is the same swap on
`quicksand.capabilities`, plus a record-to-map copy of the real
capabilities (`:143`). Precedent for a single cast behind a named
helper: `cosmic/check.tl:137` `is_exposed(module: any, name)`
(daab8101 routed 13 probe sites through it). `check.tl` is 358 lines.

## Change

- `cosmic/check.tl`: add
  `swap_members(module: any, members: {string: any}, body: function())`
  — save `(module as {string: any})[name]` for every key
  (`-- cast: probe module surface to swap a member its declared type owns`,
  the one cast), assign the replacements, `pcall(body)`, restore every
  saved value, rethrow with `error(err, 0)` (`-- throws:` per D23,
  `check` may throw). Declare it on the `check` record and document
  it beside `is_exposed`.
- `cosmic/sandbox/init_test.tl`, `landlock_net_test.tl`,
  `landlock_scope_test.tl`: delete `with_mock_landlock`; call
  `check.swap_members(landlock, mocks, body)` at its call sites
  (`git grep -n "with_mock_landlock(" origin/main -- cosmic/sandbox/`).
- `cosmic/quicksand/box/init_test.tl:140-150`: build `mocked` with
  `require("cosmic.deep").copy(real)` (typed `Capabilities`), apply
  `overrides` through `check.swap_members`-style assignment on the
  copy — one residual cast if `overrides` must stay `{string: any}`;
  swap `quicksand.capabilities` through `check.swap_members`.
- `_build/casts_baseline.tl`: `cosmic/sandbox/init_test.tl` 4 → 1,
  `landlock_net_test.tl` 3 → 0, `landlock_scope_test.tl` 3 → 0,
  `cosmic/quicksand/box/init_test.tl` 4 → ≤ 1, `cosmic/check.tl` 3 → 4
  (`bin/cosmic --make run _build/casts.tl --baseline`); reconcile
  `docs/design/cast-sites.tsv`; `### map view of a declared value` in
  `docs/design/casts.md` keeps its four library rows.
- `bin/cosmic --make ci` ends `ci: PASS`.

## Non-goals

The four library map-view rows (coverage, fetch, merge) belong to the
tail container's child; no behaviour change to what the mocks do.
