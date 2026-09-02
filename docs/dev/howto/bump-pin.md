# Bump a pin

steps to move the tree onto a new cosmos or tl release, or onto a new
cosmic release as the trust root, and to stage a change that needs the
new release first. for a contributor who has built the tree.

## bump cosmos or tl

1. edit `version` and the `sha` in `3p/cosmos/cosmos_pin.tl` or
   `3p/tl/tl_pin.tl`. the digest is the sha256 of the new archive:

   ```bash
   curl -fsSL <url> | sha256sum
   ```

2. land the new archive:

   ```bash
   bin/cosmic --make fetch
   ```

   for tl, `fetch` re-applies `3p/tl/tl_patch/` to the unpacked source.
   an entry whose `find` anchor does not occur exactly once in the new
   source fails here. re-audit that entry against the new source before you go on.

3. rebuild, which regenerates `o/_types/types_gen/` from the new
   release:

   ```bash
   bin/cosmic --make build
   ```

   the `cosmo.*` declarations come from `definitions.lua` inside the
   pinned cosmos `lua` binary, and `tl.d.tl` from the pinned tl source.

4. run the gate under the new binary, and fix what the new types break:

   ```bash
   o/bin/cosmic --make ci
   ```

5. for a cosmos bump, run the compare gate against the previous pin.
   `skills/optimize/SKILL.md` has the loop.

### validate against a cosmopolitan checkout

before a cosmopolitan release is cut, point the type generator at the
checkout's annotations instead of the pinned runtime's copy:

```bash
GENTYPE_DEFS=/path/to/cosmopolitan/tool/net/definitions.lua bin/cosmic --make build
```

`_types/gentype_defs.tl` reads that file when the variable is set.

## bump the trust root

`bin/cosmic.pin` names the cosmic that builds this cosmic.

1. pick a release of cosmic-lua/cosmic. a tag is `YYYY-MM-DD-<sha7>`,
   and the release's `SHA256SUMS` asset has the digest of `cosmic-lua`.
2. write the two lines, together:

   ```text
   url = https://github.com/cosmic-lua/cosmic/releases/download/<tag>/cosmic-lua
   sha256 = <digest>
   ```

   `bin/cosmic` reads them with `sed`, and verifies the sha before it
   runs anything.

3. start cold. `bin/cosmic` prefers `o/bin/cosmic` when one exists, so
   an existing build never exercises the new pin:

   ```bash
   bin/cosmic --make clean
   bin/cosmic --make fetch
   bin/cosmic --make build
   o/bin/cosmic --make ci
   ```

   the first command after `clean` downloads the new release into
   `o/bootstrap/cosmic`, assimilates it to a native ELF, and stamps it
   with the sha.

4. run the cold-build guard, which type-checks the whole tree with the
   new bootstrap exactly as build generation 1 does:

   ```bash
   o/bin/cosmic --make test _build/coldbuild_test.tl
   ```

5. commit `bin/cosmic.pin` with whatever the new checker required.

## stage a change that needs the tree's own checker

build generation 1 compiles the whole tree with the pinned release's
checker and patch set. a source that only the tree's own checker
accepts passes the converged `--make ci` and fails a cold build.
`_build/coldbuild_test.tl` runs generation 1's check on every pull
request, so that failure lands on the change that causes it.

1. land the checker or patch change alone.
2. wait for a release that carries it. release.yml runs daily at 06:00
   UTC, or dispatch it.
3. prove the candidate carries the change (next section), then bump
   `bin/cosmic.pin` to it.
4. land the code that needs the change.

a site that both checkers accept needs no staging. rewrite it that way
when the rewrite is small.

## prove a candidate carries a checker change

the carried tl patch reaches builders only through `bin/cosmic.pin`, so
a bump made to obtain a checker rule has to prove the candidate carries
it. the proof is one probe file the two binaries answer with opposite
exit statuses.

1. write the probe: one `.tl` file the current pin refuses and the
   candidate accepts. `_build/testdata/packn_probe.tl` is the worked
   example, for the entry that narrows `table.pack(...).n` from `any` to
   `integer`:

   ```teal
   -- The `_` prefix is required: an unused local is an error here, so
   -- without it this probe would exit 1 under every checker and prove nothing.
   local t = table.pack(1, "a")
   local _n: integer = t.n
   ```

   warnings are errors under every checker. a probe with an unused
   local exits 1 on both sides and proves nothing, quietly.

2. download the candidate:

   ```bash
   curl -fsSLo o/candidate <url>
   chmod +x o/candidate
   ```

3. run the probe against the current pin's binary and the candidate.
   `o/bootstrap/cosmic` is on disk after any cold `bin/cosmic` run:

   ```bash
   o/bin/cosmic _build/pin_probe.tl <probe.tl> o/bootstrap/cosmic o/candidate
   ```

4. read the last line, and the exit status:

   | verdict | exit |
   |---|---|
   | `pin-probe: DISCRIMINATES (baseline refuses, candidate accepts)` | 0 |
   | `pin-probe: DISCRIMINATES (baseline accepts, candidate refuses)` | 0 |
   | `pin-probe: VACUOUS (both accept)` | 1 |
   | `pin-probe: VACUOUS (both refuse; a differing message is not discrimination)` | 1 |
   | no verdict, the run did not happen: wrong argument count, an unreadable probe, a binary that does not run | 2 |

   both transcripts print in full above the verdict. a differing error
   message is not proof: a probe both binaries refuse says nothing
   about the rule, however far apart the two messages read.

the worked probe against the current pin reads like this, because the
pin already carries that entry:

```text
baseline: o/bootstrap/cosmic
Type check passed: _build/testdata/packn_probe.tl
exit=0
candidate: o/bin/cosmic
Type check passed: _build/testdata/packn_probe.tl
exit=0
pin-probe: VACUOUS (both accept)
```

[../explanation/bootstrap.md](../explanation/bootstrap.md) says why the
cold-build rule exists and why a release is built twice.
