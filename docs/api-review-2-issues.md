# api-review-2: issue seeds

Ready-to-file GitHub issue bodies for the pre-stable breaking wave from
`docs/api-review-2.md` (PR #587): six discrete issues (B1–B6) plus the
umbrella tracker, mirroring the #533 structure. File the children
first, then the umbrella with the real issue numbers substituted for
the `B*` placeholders. All children take the `api-review` label.

---

## B1 — title: `B1: address model — opaque ip.Addr in every public signature (pre-stable break)`

From the api-review-2 analysis (`docs/api-review-2.md`, PR #587).
Pre-stable **breaking** change; the largest item in the wave.

### Problem

Raw IPv4 integers are the public address currency. `ip.parse(str)`
returns an `integer`; `net` accepts `string | integer | ip.Addr` on
input but returns bare ints from `accept`, `getsockname`,
`getpeername`, and `recvfrom`; `is_loopback`/`is_private`/`is_public`/
`categorize` take ints; `ip.lookup` can only ever mean A records. When
IPv6 lands (whilp/cosmopolitan#144, deliberately post-stable), every
one of these signatures either breaks or forks into a parallel `*6`
API — the Go `net.IP` → `netip.Addr` lesson, where the cheap 2009
shape cost a parallel type system in 2021 that both still coexist.

### Ideal API

`ip.Addr` becomes the only address type in public signatures; the
v4-only *implementation* is unchanged.

- `ip.parse(str): Addr | nil, string` (today `integer | nil, string`)
- `ip.lookup(hostname): Addr | nil, string` (already Addr — keep)
- `Addr.family: "inet"` added now, so IPv6 later is a value extension,
  not a type change; keep `Addr:int()` for the v4 payload
- `Socket:accept([flags]): Socket, Addr, port`
- `Socket:getsockname() / getpeername(): Addr, port`
- `Socket:recvfrom(...): data, Addr, port`
- `Socket:sendto(data, Addr | string, port)` — the input union drops
  bare `integer`
- `ip.is_loopback / is_private / is_public / categorize(Addr)`; the
  int-taking forms go (Addr methods already exist)
- Reserve `net.dial(host, port): Socket | nil, string` (name + return
  shape only; resolution inside; from #501) so the most-used future
  entry point is born Addr-native

### Folds in

- #498's `−1` sentinel fixes in `ip.parse`/`resolve` and the
  `url.parse_host` IPv6 mis-split — same surface, same commit.

### TDD

- red: type-level test that no public `net`/`ip` signature mentions
  bare `integer` addresses; runtime tests for accept/getsockname/
  recvfrom returning Addr with `family == "inet"`
- green: reshape `lib/cosmic/ip.tl` + `lib/cosmic/net/socket.tl` +
  `net/init.tl`; sweep in-repo consumers (fetch, quicksand proxy)
- gates: `bin/make ci`, `bin/make perf-compare` (Addr allocation on
  accept/recvfrom hot paths — follow the #563 precedent:
  metatable-on-raw, no per-call wrap cost)

### Knock-ons

`fetch` internals, `quicksand.proxy`, examples/docs. No cosmopolitan
change required.

---

## B2 — title: `B2: stream contract — nil-on-EOF everywhere + a structural Reader/Writer (pre-stable break)`

From the api-review-2 analysis (`docs/api-review-2.md`, PR #587).
Pre-stable **breaking** change (one behavioral break + typing).

### Problem

Five byte-stream producers exist (`fd.Handle:read`,
`net.Socket:recv`, `fetch.Reader:read`, `child.Handle:read`, `sse` as
a consumer) with two EOF conventions and no shared structural type:

- `fd.Handle:read` returns bare `nil` on EOF (settled in #560/#569)
- `net.Socket:recv` returns `""` on peer close
  (`lib/cosmic/net/socket.tl:23`, with `Example_recv_eof`
  demonstrating the difference)
- `sse.events(reader)` is nominally typed to `fetch.Reader`
  (`lib/cosmic/sse.tl:65`), so it cannot consume a socket or file even
  though SSE is just bytes

This is the io.Reader lesson: define the one stream contract before
stable, and every post-stable battery (tls wrap, httpd request bodies,
gzip streaming, tar, buffered line readers) composes for free.

### Ideal API

- **Break:** `Socket:recv` returns `nil` on peer close (EOF), matching
  `fd`. `""` remains possible only as a zero-byte UDP datagram, which
  is honest.
- Define the structural interfaces once, documented as *the* stream
  contract:
  - `Reader`: `read([n]): string | nil, string` — bare nil = EOF
  - `Writer`: `write(data): integer | nil, string`
- Retype `sse.events` (and `fetch`'s reader) against the structural
  `Reader`; fd/net/fetch/child already almost conform.
- Record the EINTR posture per conforming type (poll retries
  internally; fd currently surfaces it). Give the deferred
  "signal-safety wave" (`lib/cosmic/fd.tl` header) a tracking issue
  and a pre-stable decision, even if the decision is "document, don't
  retry".

### TDD

- red: shared conformance test run against fd.Handle, net.Socket,
  fetch.Reader, child.Handle (EOF returns nil; error returns nil, msg;
  reads after EOF stay nil); sse test consuming a socket-backed reader
- green: recv change + interface records + retypes
- gates: `bin/make ci`; audit every in-repo `recv()` loop for
  `== ""` EOF checks (fetch internals, quicksand proxy, examples)

### Knock-ons

`docs/stdlib.md` networking example; `net/init_example.tl`
`Example_recv_eof` inverts; buffered `lines()`/`read_exact()` helpers
(#501's readline) become a single post-stable implementation over
`Reader`.

---

## B3 — title: `B3: compress — standard formats only, expose gzip, delete the bespoke prefixed deflate (pre-stable break)`

From the api-review-2 analysis (`docs/api-review-2.md`, PR #587).
Pre-stable **breaking** change.

### Problem

`compress.deflate`/`inflate` wrap raw deflate in a module-specific
4-byte little-endian size prefix (`lib/cosmic/compress.tl:38–65`) — a
format nothing else reads, one persisted byte away from being frozen
forever. Meanwhile the C layer (post whilp/cosmopolitan#170) already
supports `cosmo.Deflate/Inflate` with `format = "raw" | "zlib" |
"gzip"` (+`"auto"` detection) and bounded output — and cosmic exposes
no gzip at all, in a distribution whose HTTP client talks to a
gzip-speaking web.

### Ideal API

- `compress.compress(data, opts?: {format: "zlib" | "gzip" | "raw"}):
  string` — default zlib; current infallible contract unchanged
- `compress.decompress(data, opts?: {format: "zlib" | "gzip" | "raw" |
  "auto", max_output: number}): string | nil, string` — bounded
  (default 64 MiB) as today
- **Delete** `deflate`/`inflate` (the prefixed format) and
  `uncompress` (renamed for symmetry). Raw-deflate callers who need a
  length carry it themselves — that was always the honest contract.
- gzip *streaming* (Reader-wrapping) is post-stable and falls out of
  B2.

### TDD

- red: round-trip tests per format; gzip output verified against a
  fixture produced by system gzip (magic bytes + decompressible);
  zip-bomb bound test for each format; `"auto"` detection test
- green: rewrite `lib/cosmic/compress.tl` over the format option;
  remove prefix arithmetic entirely
- gates: `bin/make ci`, `bin/make perf-compare` (compress scenario in
  the perf harness)

### Knock-ons

Any in-repo `deflate`/`inflate`/`uncompress` callers; `docs/stdlib.md`
"infallible" example uses `compress.compress` (unchanged).

---

## B4 — title: `B4: hash — settle the digest/hmac algorithm shape; crc32 lands in codec (pre-stable decision)`

From the api-review-2 analysis (`docs/api-review-2.md`, PR #587).
Additive to implement, but the *shape* freezes at the stable cut —
decide now, before #502 fills out the digest family.

### Problem

`cosmic.hash` exposes exactly `sha256`, `sha256_hex`, `hmac_sha256`
(+ argon2 password hashing). The C layer already dispatches the whole
mbedTLS digest family by name — `cosmo.GetCryptoHash(name, data, key?)`
covers MD5/SHA1/SHA224/SHA256/SHA384/SHA512/BLAKE2B256, each with HMAC
(`definitions.lua:2438`) — and `cosmo.Crc32`/`Crc32c` are bound too.
Filling this out per-algorithm (`sha512`, `sha512_hex`, `hmac_sha512`,
…) explodes combinatorially, and the streaming digest that review 1
explicitly deferred post-stable needs an object API whose name must
not be squatted.

### Ideal API

- `hash.digest(algo, data): string` and `hash.hmac(algo, key, data):
  string` with an algo enum (`"sha256" | "sha512" | "sha384" |
  "sha224" | "sha1" | "md5" | "blake2b256"`); raw bytes out, callers
  hex via `codec.encode_hex`
- Keep `sha256` / `sha256_hex` / `hmac_sha256` as the blessed
  conveniences — they are the 95% case and already shipped
- **Reserve** `hash.new(algo): Hasher` (update/final) for post-stable
  streaming; record the reservation in the module header
- `codec.crc32(data, [initial]): integer` and `codec.crc32c(...)` —
  checksums are encoding-adjacent, not crypto; consistent with crc32
  already appearing in `zip.Stat`

### TDD

- red: known-answer tests (NIST/RFC vectors) per algorithm and HMAC;
  crc32 vector tests; error test for unknown algo (`nil, err`)
- green: thin wrappers over `GetCryptoHash`/`Crc32`/`Crc32c`
- gates: `bin/make ci`; `definitions.lua` needs no upstream change

### Knock-ons

#502 (wrap already-declared digest surface) is subsumed for the digest
half; the `unix.utime`/binary-confirmation half of
whilp/cosmopolitan#147 is unaffected.

---

## B5 — title: `B5: child — honest option types: fd.Handle in Options, no raw ints (pre-stable break)`

From the api-review-2 analysis (`docs/api-review-2.md`, PR #587).
Pre-stable **breaking** change — the public-record-type slice of #493.

### Problem

`child.Options.stdin` is a string-or-raw-fd union and
`stdout`/`stderr` are raw integer fds. Raw fds in a public record are
the leaky-abstraction finding already filed as #493 — but #493 is a
general backlog item, and the parts that touch *public record types*
freeze at the stable cut. Changing an Options field type post-stable
is breaking; tightening internals is not.

### Ideal API

- `Options.stdin: string | fd.Handle` — a string is piped (unchanged);
  a Handle is the child's fd 0
- `Options.stdout / stderr: fd.Handle` — raw `integer` forms removed
- Everything else in #493 (internal userdata leaks, hidden C options)
  stays backlog; this issue is only the public-type surface

### TDD

- red: spawn with `fd.open`-produced Handles for stdout/stderr;
  type-level test that Options mentions no bare `integer` fds
- green: `lib/cosmic/child/init.tl` + `child/io.tl` accept Handles
  (`:fd()` at the boundary); update examples
- gates: `bin/make ci`, `bin/make perf-compare` (spawn scenario —
  posix_spawn fast path must be unaffected)

### Knock-ons

`testrun`/`benchmark` internals if they pass raw fds; #493 shrinks to
its internal-only remainder.

---

## B6 — title: `B6: pre-stable recorded-decisions sweep (time, listen_tcp, stdlib.md drift, review-era PRs)`

From the api-review-2 analysis (`docs/api-review-2.md`, PR #587).
Cheap sweep; one PR. Decisions recorded in module headers so they
never re-open — the #566 pattern.

### Items

1. **time**: record the decision to keep the curated format trio
   (http/date/iso8601) and defer a `time.format(fmt, ts)` strftime
   passthrough to post-stable demand; export `is_leap_year` and
   `days_in_month` (already implemented internally,
   `lib/cosmic/time.tl:188–201`).
2. **net.listen_tcp** returns `(Socket, port, err)` — port in the
   middle is unusual; either normalize or record it as deliberate
   port-0 ergonomics. Recommendation: record, don't churn.
3. **docs/stdlib.md drift**: still documents `cosmic.io` (renamed in
   #532; lines 18, 148–160), `unveil` described as OpenBSD-only, and
   the module index omits `fd`, `check`, `errno`, `sandbox`, `envd`.
   User-facing and wrong today.
4. **Review-era PRs**: reconcile and merge-or-close #538 (errno
   constants export — `errno.constants` already exists on main;
   reconcile the duplicate) and #513 (docs fixes).
5. **fd EINTR posture**: file the tracking issue for the deferred
   "signal-safety wave" referenced in the `fd.tl` header, so the
   deferral is tracked rather than folklore (decision itself lives in
   B2).

### Gates

`bin/make ci`; no contract changes beyond the two time exports.

---

## Umbrella — title: `Tracking: pre-stable breaking wave 2 — freeze the data contracts (api-review-2)`

Umbrella tracker for the second and final pre-stable breaking wave,
from the api-review-2 analysis (`docs/api-review-2.md`, PR #587).
Successor to #533, which converged the *conventions* (error protocol,
namespace, nil-honesty, safety posture). This wave freezes the two
cross-cutting *data contracts* every future battery composes over —
addresses and byte streams — plus the remaining shape decisions that
become permanent at the stable cut. Breaking changes are still in
scope; after this wave they are not.

### The design goal

Post-stable batteries (tls, httpd, gzip streaming, tar, bufio, IPv6)
must be **value extensions, not type events**. Each issue below exists
because its current shape would force a v2 API later: raw-int
addresses block IPv6 (whilp/cosmopolitan#144), divergent EOF
conventions block a composable Reader ecosystem, the bespoke deflate
framing becomes permanent the first time someone persists it, and the
per-algo hash naming explodes combinatorially once #502 fills out the
digest family.

### Issues in suggested landing order

Ordered to minimize churn; **no cosmopolitan change or release-pin
bump is required anywhere in this wave** — gzip, the digest family,
crc32, and getaddrinfo are already bound or linked in the pinned
binary.

- [ ] **1. B6 — recorded-decisions sweep**: docs drift, time exports,
  listen_tcp decision, review-era PRs (#538, #513). Ship first:
  independent, unblocks nothing, removes noise from later diffs.
- [ ] **2. B2 — stream contract**: nil-on-EOF for `Socket:recv`,
  structural Reader/Writer, sse retype, EINTR posture recorded.
  Before B1 so the net surface is touched once per concern in a
  reviewable order (behavioral first, types second).
- [ ] **3. B1 — address model**: opaque `ip.Addr` everywhere, folds
  #498, reserves `net.dial`. The largest diff; lands on a net module
  whose stream semantics are already settled.
- [ ] **4. B3 — compress formats**: standard raw/zlib/gzip, delete the
  prefixed deflate. Independent of 2–3; sequenced here only to keep
  waves small.
- [ ] **5. B5 — child option types**: `fd.Handle` in Options, raw ints
  out. The public-type slice of #493; the rest of #493 stays backlog.
- [ ] **6. B4 — hash/codec shape**: `hash.digest`/`hash.hmac` +
  algo enum, `hash.new` reserved, crc32/crc32c into codec. Additive
  but shape-freezing; last because it subsumes part of #502 and the
  enum should reflect any names settled above.

### Dependency notes

- **Start-today, all independent of upstream:** every item. B2 → B1
  ordering is preferred (same files), not required.
- **Relationship to the audit backlog:** B1 folds #498 and reserves
  #501's `dial`; B2 makes #501's readline/lines a single post-stable
  implementation; B4 subsumes #502's digest half; B5 carves the
  public-type slice out of #493. Post-stable batteries (#500: httpd,
  log, cli, csv, tar, tls; whilp/cosmopolitan#143–#148) are
  deliberately **not** in this wave — they are additive once these
  contracts freeze.
- **After this wave: the stable cut.** Anything breaking discovered
  later needs its own justification against a stability promise, not
  a checkbox here.

Each linked issue carries the per-finding detail (evidence with
file:line, ideal signatures, red/green TDD steps, knock-ons). Check
items off as their PRs merge.
