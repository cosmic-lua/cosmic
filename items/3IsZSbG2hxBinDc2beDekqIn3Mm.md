## Evidence

A binary built by `--make build` is a base executable with the staged payload
embedded; `_make/artifact.tl`'s `bases_of` picks the base. A project whose
payload generator wrote `o/<unit>/embed_gen/base` is built onto that file;
every other project is built onto "the running cosmic", the executable image
of the process doing the build (`artifact.build(proj, b, cosmic)`).

The trust root makes that image the wrong shape. `bin/cosmic` downloads the
pinned release, verifies it, then runs `--assimilate` on it IN PLACE before
saving it as `o/bootstrap/cosmic`, so the sandbox can exec it without the APE
loader. Assimilation is one way: the polyglot header becomes a native ELF
header for the host. The zip survives, the portability does not. Every build
under that bootstrap therefore copies an ELF as its base, and every downstream
artifact is a Linux x86-64 binary that only looks like a cosmic build. Nothing
reports it: the build has no notion that a runtime can be the wrong shape.

Measured 2026-09-04: cosmic-lua/work's `o/bin/gitboard`, built under
`o/bootstrap/cosmic`, starts with `7f454c46` (ELF); cosmic's own `o/bin/cosmic`
starts with `4d5a` (MZ, the fat APE) only because `cmd/cosmic/embed_gen.tl`
supplies `base` from the cosmos pin. Every `_make/testdata` fixture built in
CI has the same defect. cosmic-lua/work worked around it with a runtime pin
and its own generator (cosmic-lua/work#8); that workaround is unnecessary
once this is fixed.

## Change

Keep the published bytes, and make the fallback refuse to guess.

1. `bin/cosmic`: save the verified download as `o/bootstrap/cosmic.ape`
   (pristine) and assimilate a COPY into `o/bootstrap/cosmic`. One stamp
   covers both; a pin bump re-downloads both; `--make clean` removes both
   (`_make/clean.tl`).
2. `_make/artifact.tl` `bases_of`: "the running cosmic" resolves to the
   `.ape` sibling of the executable when one exists with a matching stamp;
   otherwise to the executable itself when its first two bytes are `MZ`;
   otherwise the build REFUSES with a message naming the assimilated image,
   that a build onto it would be host-only, and the two ways out (run the
   published release, or declare a base in the unit's generator). A refusal
   is a `nil, string` from `build`, never a throw.
3. Tests, in the same PR: `_make/artifact_test.tl` covers the three
   resolutions (sibling present, MZ executable, refusal) with fixture files;
   `_make/fixtures_test.tl` asserts the `hello` fixture's artifact starts with
   `MZ` when built under the bootstrap (it does not today); `_make/clean_test.tl`
   covers the sibling's removal; any existing test that assumed the fallback
   base is the executable is fixed rather than skipped. `_cli/fence_test.tl`'s
   assimilated-bootstrap assumptions stay true, since the assimilated copy
   still exists.
4. Docs: the `bin/cosmic` header comment and AGENTS.md's trust-root paragraph
   say a pristine copy is kept and why.

After this lands, remove cosmic-lua/work's `3p/cosmic/cosmic_pin.tl` and
`cmd/gitboard/embed_gen.tl` in a follow-up there; the fallback then yields
the same fat artifact.

## Non-goals

Embedding a second copy of cosmic inside its own zip so the running image can
reproduce itself (doubles the artifact); requiring every project to pin cosmic
(breaks the promise that a project pinning nothing gets a cosmic with its code
in it); reconstructing an APE header from an assimilated ELF.
