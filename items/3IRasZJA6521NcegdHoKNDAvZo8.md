## Goal

G3 — an honest type layer, no escape hatches: D23's "no other
`cosmic.*` module may throw or exit" becomes TRUE by amendment rather
than false by omission. The census found five modules of unrecorded
`error()`/`os.exit()`; refinement classified every site, and the
outcome is one D23 amendment naming three licensed SHAPES (rules, not
site lists — D23's own amendment philosophy), one doctrine line
refresh, and one three-line code change.

## Evidence

Re-measured 2026-08-26 against main `b4ad036b`; every cited line
verified:

| site | what it is | verdict |
| --- | --- | --- |
| `cosmic/child/init.tl:386,402`, `cosmic/quicksand/box/run.tl:152,165,235,242,287` | `os.exit(126/127/code)` on post-`fork` child paths — a forked child that failed its `chdir`/`exec` cannot return into two copies of the caller's stack, and 126/127 are the shell's own grammar | licensed shape: **post-fork child exit** |
| `cosmic/init.tl:41` | `os.exit` in `cosmic.main()`, the entry helper whose caller is the OS — the same argument the generated embed wrapper won in 3IQfhI33's refinement | licensed shape: **entry-helper exit** |
| `cosmic/coverage/init.tl:129` | `error(results[2], 0)` in the `wrap` shim — re-raising the wrapped coroutine's OWN error, level 0; transparency is `coroutine.wrap`'s contract | licensed shape: **transparent re-raise** |
| `cosmic/hash.tl:100,133` | `error("unknown algorithm")` behind a `< total >` `{Algo: boolean}` guard — a TYPED caller cannot reach it (`Algo` is an enum, line 24); it exists for dynamic Lua callers, i.e. the caller-contract shape D23's first amendment says "still needs its own record" | record it in the same amendment: **caller-contract throw on an enum-guarded argument** |
| `cosmic/hash.tl:105` | `error("hash.digest: " .. err)` when `GetCryptoHash` fails AFTER the name was validated against `valid_algos` — the failure is unreachable for a validated name, which is exactly the shape D23 already licenses as an `-- assert:` | **convert to the licensed assert** |

`docs/decisions/d23-check-throws.md` is 68 lines; `cosmic/hash.tl` is
264; AGENTS.md's doctrine bullet is line 237 ("never throw from
library code — three shapes are exempt").

## Change

1. **`docs/decisions/d23-check-throws.md`** — a second amendment, in
   the `decide` skill's amend form (load `skills/decide/SKILL.md`
   before writing it): the census above found four shapes the closed
   list did not name, and the amendment licenses them as RULES —
   - a post-`fork` child path may `os.exit`: the child cannot return,
     and 126/127 are the exec-failure grammar every shell reads;
   - an entry helper whose caller is the OS (`cosmic.main`, the
     generated embed wrapper) may `os.exit` with the code it computed;
   - a wrapper whose job is transparency may re-raise the wrapped
     code's OWN error unchanged (`error(e, 0)`), because swallowing or
     re-typing it would change observable behavior;
   - a caller-contract throw guarding an enum-typed argument
     (`hash.digest`'s unknown algorithm) is licensed when the argument
     type already makes the throw unreachable for typed callers and
     the doc comment names the contract.
   Keep the existing "nothing else moves" posture: a reachable runtime
   failure stays fallible.
2. **`AGENTS.md:237`** — the bullet's "three shapes are exempt"
   becomes a pointer to D23's amended set rather than a re-counted
   list (the count has now changed twice; stop inlining it).
3. **`cosmic/hash.tl:102-106`** — `digest`'s post-validation failure
   becomes the licensed assert:

   ```teal
   -- assert: GetCryptoHash fails only on an unknown name, and algo
   -- was just validated against the total Algo map
   local d = assert(cosmo.GetCryptoHash(
     string.upper(algo) as cosmo.CryptoHashName, data)) -- cast: enum widening
   ```

   (Keep the existing cast and its reason; drop the `if not d ...
   error` pair. Mind the two-comment stacking — the `-- assert:` line
   goes directly above, the trailing `-- cast:` stays on its line; run
   the assert-justify and cast-justify lints on the file.)
4. **No site comments at the exit/re-raise sites** — the amendment
   licenses shapes, not seats; a future census gate (the 3IRTkNx1 lint
   family) checks sites against the rules. Note the gate gap in the
   amendment's consequences the way the first amendment noted the
   `-- assert:` convention.

## Non-goals

- **No behavior change anywhere but `hash.tl:105`**, and there only
  the throw's spelling (assert vs error — both raise; the message
  changes from `hash.digest: <err>` to the assert's own, which no test
  pins: `grep -rn "hash.digest:" cosmic/hash_test.tl` finds no message
  assertion — re-verify at pull).
- **No lint** — enforcement is 3IRTkNx1's family; this slice makes the
  rules the lint would check.
- **`cosmic/quicksand/proxy/serve.tl:374` is 3IQfhI33's** (in flight);
  do not touch it, and do not license it — its listen failure is
  reachable.
- **No new exemption for reachable failures**: `hash.hmac`'s empty-key
  `nil, err` and every other fallible return stay exactly as they are.

## Acceptance

- `bin/cosmic --make ci` ends `ci: PASS`.
- `grep -c "amended" docs/decisions/d23-check-throws.md` reports at
  least 2 (today 1 — the file carries one amendment note).
- `grep -c "three shapes are exempt" AGENTS.md` reports 0 (today 1).
- `grep -n "error(" cosmic/hash.tl | grep -v -- "---"` reports exactly
  two sites — `:100` and `:133`-equivalents, the enum-guard throws
  (today three).
- `grep -c -- "-- assert:" cosmic/hash.tl` reports 1 (today 0).
- `bin/cosmic --make test cosmic/hash_test.tl` ends `test: PASS (1
  file)`.
- `git diff --name-only origin/main` lists exactly:
  `AGENTS.md`, `cosmic/hash.tl`,
  `docs/decisions/README.md` (the derived index follows the status
  line — its drift gate prints the expected row),
  `docs/decisions/d23-check-throws.md`.

## Enablement

none needed. The `decide` skill holds the amendment form; every site
verdict above is argued from code already read at the cited lines, and
the one code change reuses the assert shape D23 already licenses.
