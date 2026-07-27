# D16 — every build input is enumerable from committed files, the version stamp included

- **date:** 2026-07
- **context:** the design's strongest property is that a build's
  external surface is enumerable from committed files: pins declare
  every byte that can arrive, `exec` runs only what pins landed, and no
  project code gets a socket. The version stamp was the one exception —
  its project half came from the `COSMIC_VERSION` environment variable.
  Two builds of the same commit could differ by ambient environment, so
  "same inputs, same artifact" silently acquired a precondition no
  committed file recorded; the gen2 = gen3 fixpoint held only because
  both generations happened to be stamped the same way. It was also
  invisible to staleness, which is the shape `write_if_changed` and the
  facts closures exist to prevent everywhere else.
- **decision:** the stamp is read from the tree — a committed
  `.version`, in the same literal grammar as a pin, so it is data the
  build never executes — falling back to `COSMIC_VERSION` and then to
  `unknown`. A release *writes* the file it builds from.
- **rejected:** `git describe` (a build that shells out to git cannot
  run in the sandbox this build system is for, and it re-acquires the
  `safe.directory` apparatus every CI lane carries); keeping the
  variable as the only source (it is the out-of-band input the derived
  fence exists to eliminate — grants come from argv precisely so
  nothing travels around them).
- **consequences:** a bare `cosmic --make build` of a clean tree is
  bit-reproducible with no environment coordination; the fixpoint test
  now declares the version in the tree it copies and passes **no**
  `COSMIC_VERSION` at all, which is what makes it a fixpoint over
  committed inputs. `COSMIC_VERSION` remains as a documented override
  for a build nobody tagged. The `git describe` stamp went with the
  Makefile.
- **the exception, stated:** cosmic's own releases take the env path,
  and cosmic's own tree commits no `.version`. A release tag names the
  commit it is tagging (`YYYY.MM.DD-<short-sha>`), which is not a fact a
  file inside that commit can hold. So for a TAGGED build the stamp is
  the one input not enumerable from committed files; release.yml
  computes it once and asserts `--version` reports it before upload.
  Every other build -- a developer's, CI's, the reproducibility lane's
  -- stamps `unknown` deterministically, which is what keeps the
  byte-compare honest. `.version` is for a project that versions itself
  independently of its commits; this one does not.
