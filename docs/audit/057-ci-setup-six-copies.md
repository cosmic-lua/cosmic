# 057 — the CI environment block is copied six times, and docs.yml has none

severity: medium
type: ci / maintainability
area: `.github/workflows/pr.yml`, `release.yml`, `docs.yml`

## observation

the digest-pinned container block (`buildpack-deps@sha256:…` +
`--privileged`) and the "prepare non-root builder" step (useradd,
chown, safe.directory) are repeated **six times**: five jobs in pr.yml
(build, offline, reproducible, smoke-build, enforce) plus release.yml's
build. the repetition is deliberate per the comment ("repeated per job
(#734) so each pin stays a visible, reviewable edit") — but six copies
achieve the opposite: a digest bump must hit six sites, and missing one
means **lanes silently run different environments**, which is precisely
the unpinned-input leak #734 exists to prevent. copies drift; that is
audit 030's lesson in YAML.

meanwhile **docs.yml has neither**: no pinned container, no non-root
builder, `shell: bash -x {0}`, running `bin/make doc-publish` — real
build machinery — on whatever `ubuntu-latest` serves that month. the
exact environment leak the other lanes were pinned against.

second shared fragment: the upload/download-artifact zip workaround
(find + unzip/python-zipfile) is written twice, in pr.yml's smoke job
and release.yml — with a comment in one pointing at the other ("same
trap release.yml documents").

## proposal

- one local composite action (`.github/actions/ci-env/action.yml` or a
  reusable workflow) holding the container reference is not possible —
  container config is job-level — but the digest can still live once:
  a top-level YAML anchor is unsupported in GHA, so the practical
  shapes are (a) a single `env`-independent comment-enforced check (a
  tiny test asserting all `image:` lines in `.github/workflows/*` are
  identical — the ratchet pattern this repo already uses everywhere),
  and (b) a composite action for the builder-preparation step, which
  *is* shareable. do both: the digest gets a drift ratchet, the setup
  gets one definition.
- bring docs.yml into the same pinned container + builder shape, or
  record at the file why doc-publish is exempt from #734. (its git
  *push* needs credentials and network either way — that part stays a
  workflow concern; see 059 for the split.)
- extract the artifact-unzip fragment into the composite action or fix
  it at the source (upload-artifact's archive behavior), once, and
  point both consumers at it.

## test to add

the drift ratchet: a `_build` test that reads
`.github/workflows/*.yml`, collects every `image:` line, and asserts
one distinct value — so the next digest bump that misses a site fails
in CI instead of running lanes on skewed environments.
