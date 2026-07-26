# 059 — the gate's git dependencies retire with the verbs; name that as an exit criterion

severity: low
type: ci / design
area: pr.yml (safe.directory), docs.yml (fetch-depth), version stamp, lint

## observation

CI carries git plumbing because two recipes shell out to git from
inside the sandboxed build:

- `git ls-files` — lint's file discovery (tracked plus
  untracked-not-ignored). every lane therefore runs
  `git config --system --add safe.directory` in setup.
- `git describe` — the Makefile-path version stamp. docs.yml checks
  out with `fetch-depth: 0` so describe can see tags.

both dependencies are already scheduled to dissolve by other audit
items: the `--make` version stamp reads the pin + `COSMIC_VERSION`
(050 proposes a committed file), and a `lint` verb (048/051) discovers
files from the **model**, not from git — the model already computes
exactly the tracked-shaped set, minus `o/`.

what should *not* dissolve: docs.yml's push to the `docs` branch is a
real git operation and stays a workflow step (054 records the split —
the build produces `o/docs`, the workflow pushes it).

## why name this explicitly

"the gate needs no git" is a meaningful property, not just tidiness:
git is host surface inside sandboxed recipes today (each git exec is a
hostx grant the ratchets must enumerate), and a git-free gate runs in
a barer container, on a tarball checkout, and under the derived fence
without a git-shaped hole in the floor. it is also easy to lose by
accident — a new recipe that shells to git re-acquires the whole
apparatus — so it should be an asserted property, not a hoped one.

## proposal

when 050 and the lint verb land, remove the safe.directory step and
`fetch-depth: 0`, and add the assertion: the no-shell/hostx ratchet's
successor (or the fence floor) refuses `git` as a recipe child. exit
criterion for 3i's gate: `bin/cosmic --make ci` passes in a container
with no git binary installed.
