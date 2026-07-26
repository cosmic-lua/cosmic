# 050 — `COSMIC_VERSION` is the one build input not enumerable from the tree

severity: low
type: design / feature
area: docs/design/make.md (version stamp); `cmd/cosmic/embed.gen.tl`

## observation

the design's strongest property is that a build's external surface is
enumerable from committed files: pins declare every byte that can
arrive, `exec` runs only what pins landed, no project code gets a
socket. the version stamp is the one exception — its cosmic half comes
from the `COSMIC_VERSION` environment variable, defaulting to
`unknown`.

consequences, small but real:

- **two builds of the same tree differ by ambient environment.** the
  reproducibility story ("same inputs, same artifact"; the gen2 = gen3
  fixpoint) silently acquires a precondition — equal `COSMIC_VERSION` —
  that no committed file records. the fixpoint procedure in
  make-plan.md sets it for gen2's build and not visibly for gen3's,
  which is either a doc gap or an accident of both being `unknown`.
- **it is invisible to staleness.** the graph rebuilds on file changes;
  an env change producing a different artifact from an unchanged tree
  is the exact shape `write_if_changed` and the facts closures exist to
  prevent elsewhere.

env-var inputs also cut against the fence direction: grants are derived
from argv precisely so nothing travels out of band.

## proposal

make the version an ordinary tree input with an override, rather than
an ambient one: the generator reads a committed file when present
(e.g. `embed/.version`, or a field beside the pins), else falls back to
`COSMIC_VERSION`, else `unknown` — and the release workflow *writes*
the file it builds from. a bare `--make build` of a clean tree is then
bit-reproducible with no environment coordination, and the one
out-of-band input the design still has becomes a documented override
instead of a requirement.
