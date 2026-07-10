# API review 2: post-#533 assessment and the last pre-stable breaks

Date: 2026-07-10. Scope: review of the completed #533 convergence wave
(13 issues + the T8 follow-ups, all closed), a gap analysis of the
combined cosmo/cosmic surface against a Go-stdlib-style baseline for
general-purpose computing, and — the payload — the breaking changes
that should still land before the stable cut. Everything additive is
explicitly sequenced *after* stable; the point of this document is to
separate the two.

Method: full inventory of the 46 public cosmic modules (signatures read
from source), a survey of what the cosmopolitan C core links into the
`lua` binary versus what it exposes, and a cross-check against the
existing backlog (audit issues #491–#510, #500/#501/#502 umbrellas;
cosmopolitan #141–#148) and the recorded judgments in #533/#566/#557 so
nothing settled is re-litigated.

## 1. Verdict on the #533 wave

The work is in good shape. Specifically:

- **The error convention is real.** `nil, err, errno` at the C boundary
  (locked by `test_lfuncs_errors.lua` / `test_unix_errno.lua` upstream),
  `T | nil, string` / `boolean, string` in Teal, one shared formatter
  (`errno.str`), and the documented deviations (lsqlite3 result codes,
  argon2 2-tuple) are recorded rather than accidental.
- **The namespace is coherent.** Shadowing names are gone (`io`→`fd`,
  `assert`→`check`), shard families are directory modules, `doc`/`docs`
  converged, and `public.tl` records *why* for every borderline entry —
  the #566 capstone means the public list won't silently re-open.
- **Safety posture is consistent.** Fail-closed sandboxing, SSRF
  opt-out, zip-slip-safe extract, bounded decompression, CSPRNG-backed
  uuid/rand, constant-time compare, no-throw library discipline.
- **Resource handling is uniform.** `__close`/`__gc` on every handle
  type (fd/Pipe/Socket/Dir/Database/Statement/Reader/child.Handle).

Residual debt from the wave itself (small): `docs/stdlib.md` still
documents `cosmic.io` (renamed in #532) and omits `fd`, `check`,
`errno`, `sandbox`, `envd`; two open PRs from the review era (#538
errno constants, #513 docs fixes) are unmerged; and `fd`'s EINTR
posture is documented as deferred to a "signal-safety wave" that has no
tracking issue.

## 2. The structural finding

The #533 wave converged *conventions* (errors, naming, nil-honesty).
What it did not do — and what Go's stdlib history says to do **before**
stable — is converge the two cross-cutting *data contracts* that every
future battery will build on:

1. **The address model.** Addresses appear in public signatures as raw
   IPv4 integers (`ip.parse(str): integer`, `Socket:accept(): Socket,
   ip, port`, `sendto(data, ip, port)`, `getsockname(): ip, port`).
2. **The stream model.** Five byte-stream producers exist
   (`fd.Handle:read`, `net.Socket:recv`, `fetch.Reader:read`,
   `child.Handle:read`, `sse` as a consumer) with two different EOF
   conventions and no shared structural type.

Both are cheap to fix now and effectively impossible to fix after the
cut. Go shipped `net.IP` in 2009 and spent a decade paying for it until
`netip.Addr` (2021) — and still carries both. It shipped `io.Reader` on
day one and got an entire composable ecosystem for free. cosmic is at
the fork in that road right now: IPv6 (#144) and TLS (#143) are already
on the post-stable roadmap, and both will be shaped by whatever address
and stream contracts stabilize this month.

## 3. Breaking changes to make before stable

Ranked. B1–B3 are true breaks; B4–B6 are contract *decisions* that are
additive to implement but must be made now because their shape is
frozen by the cut.

### B1. Opaque address type in `ip` and `net` (enables IPv6 post-stable)

Today `ip.Addr` exists but the raw `integer` is the real currency:
`ip.parse` returns an int, `net` accepts `string | integer | ip.Addr`
on input but returns bare ints from `accept`/`getsockname`/
`getpeername`/`recvfrom`, and `ip.lookup` can only ever return A
records. When AF_INET6 arrives (#144), every one of these either breaks
or forks into a parallel `*6` API.

The break: make `ip.Addr` the only address type in public signatures.

- `ip.parse(str): Addr | nil, string` (today: `integer | nil`)
- `accept(): Socket, Addr, port`; `getsockname/getpeername(): Addr,
  port`; `recvfrom(): data, Addr, port`; `sendto(data, Addr|string,
  port)`
- Keep `Addr:int()` for the v4 payload; add `Addr.family` now (always
  `"inet"` for the moment) so v6 is a value extension, not a type
  change.
- Fold in #498's `−1` sentinel fixes (`ip.parse`/`resolve`) — same
  surface, same commit.
- `is_loopback/is_private/is_public/categorize` move to
  Addr-or-accept-Addr; the int-taking forms go.

IPv6 *engineering* stays post-stable exactly as the first review
decided — this only reshapes signatures so that decision stays cheap.
Also decide `net.dial(host, port)` (filed in #501) now to the extent of
reserving its name and return shape (`Socket | nil, string`, resolution
inside), since it is the API most users will actually call.

### B2. One stream contract: nil-on-EOF everywhere + a structural Reader

`fd.Handle:read` returns `nil` on EOF (settled in #560/#569).
`net.Socket:recv` returns `""` on EOF (`net/socket.tl:23`, with an
example demonstrating the difference). `fetch.Reader:read` has its own
shape; `sse.events(reader)` is nominally typed to `fetch.Reader`
(`sse.tl:65`), so it cannot consume a socket or a file even though SSE
is just bytes.

The break:

- `Socket:recv` returns `nil` on peer close (EOF), matching `fd`.
  (`""` stays possible only as a zero-byte datagram for UDP, which is
  honest.) This is the one behavioral break; it is exactly the kind of
  silent-footgun difference that survives into every server loop
  written after stable.
- Define the structural interface once (a `Reader` interface record:
  `read([n]): string | nil, string` where bare nil = EOF; and `Writer`:
  `write(data): integer | nil, string`), document it as *the* stream
  contract, and retype `sse.events` (and `fetch`'s reader) against it.
  fd/net/fetch/child already almost conform; this is mostly typing plus
  the recv change.
- Record the EINTR posture per conforming type (poll retries
  internally; fd surfaces it — give the deferred "signal-safety wave" a
  tracking issue and a decision before stable, even if the decision is
  "document, don't retry").

This is what makes post-stable batteries composable: gzip streaming,
tar, httpd request bodies, `tls.wrap(socket)`, line-buffered readers —
all of them consume/produce the same Reader instead of five ad-hoc
shapes.

### B3. `compress`: standard formats only, expose gzip, delete the bespoke framing

`compress.deflate`/`inflate` wrap raw deflate in a module-specific
4-byte little-endian size prefix (`compress.tl:38–65`) — a format
nothing else on earth reads. Meanwhile the C layer (post-#170) already
does `Deflate/Inflate` with `format = "raw" | "zlib" | "gzip"` and
bounded output, and cosmic exposes none of that: no gzip in the
distribution whose fetch client talks to a gzip-speaking web.

The break: reshape to standard formats before anyone persists the
bespoke framing.

- `compress.compress(data, opts?: {format: "zlib"|"gzip"|"raw"}):
  string` (default zlib, unchanged behavior for the current infallible
  path)
- `compress.decompress(data, opts?: {format: "zlib"|"gzip"|"raw"|"auto",
  max_output: number}): string | nil, string`
- Delete `deflate`/`inflate` (the prefixed format) and `uncompress`
  (renamed for symmetry). Raw-deflate users who need a length carry it
  themselves — that was always the honest contract.
- gzip *streaming* (file-to-file, Reader-wrapping) is post-stable and
  falls out of B2.

### B4. `hash`: fix the algorithm-shape now (decision, mostly additive)

`hash` exposes exactly `sha256`, `sha256_hex`, `hmac_sha256`. The C
layer already dispatches the whole mbedTLS digest family by name
(`GetCryptoHash("SHA512", data, key?)` — MD5/SHA1/224/256/384/512/
BLAKE2B256, each with HMAC), and `Crc32`/`Crc32c` are bound too. Filling
this out is filed (#502) and additive — but the *shape* is not: per-algo
functions combinatorially explode (`sha512`, `sha512_hex`,
`hmac_sha512`, …), and a streaming digest (explicitly deferred
post-stable by review 1) needs an object API.

Decide now, in one commit that also settles the names:

- `hash.digest(algo, data): string` and `hash.hmac(algo, key, data):
  string` with an algo enum; keep `sha256`/`sha256_hex`/`hmac_sha256`
  as the blessed conveniences (they are the 95% case and already
  shipped).
- Reserve `hash.new(algo): Hasher` (update/final) for the post-stable
  streaming work so nothing squats on the name.
- `crc32`/`crc32c` land in `codec` (they are checksums, not crypto) —
  consistent with crc32 already appearing in `zip.Stat`.

### B5. `child` options: honest types before the cut

`child.Options.stdin` is a string-or-raw-fd, `stdout`/`stderr` are raw
integer fds — the leaky-abstraction finding already filed as #493. The
parts of #493 that touch *public record types* (Options fields,
anything returning raw userdata) must be scheduled pre-stable; the rest
of #493 can wait. Accepting an `fd.Handle` where an fd is meant, with
the raw-int form removed or demoted, is the minimal honest shape.

### B6. Small recorded decisions (cheap, do in one sweep)

- **`time`**: keep the curated format trio (http/date/iso8601); add a
  `time.format(fmt, ts)` strftime passthrough post-stable if demanded.
  Record it in the module header so it doesn't re-open. Export
  `is_leap_year`/`days_in_month` (already written, trivially useful).
- **`net.listen_tcp`'s 3-tuple** `(Socket, port, err)` with port in the
  middle is unusual; acceptable, but record it as deliberate (port-0
  ergonomics) or normalize now.
- **Merge or close the two open review-era PRs** (#538 errno constants
  export — export exists in `errno.constants`, reconcile; #513 docs).
- **Fix `docs/stdlib.md` drift** (`cosmic.io`, missing modules) — it is
  user-facing and wrong today.

## 4. Gap map vs a Go-stdlib baseline

What "strong general-purpose computing" still needs, cross-referenced
against the backlog. **Filed** = already tracked, don't re-file.
**New** = surfaced by this review. All items here are additive
(post-stable-safe) once B1–B5 fix the contracts they build on.

| Area (Go analog) | cosmic today | Status |
|---|---|---|
| HTTP server (`net/http`) | none; raw TCP loops only | Filed #500 (httpd, Wave 3). Note: `ParseHttpMessage`, header/cookie/range parsers are compiled **and linked** into the lua binary already — the C cost is a binding, not a port. Needs B2. |
| TLS (`crypto/tls`) | client-only, buried in fetch | Filed #143 (U4) + #500. mbedTLS server bits (`ssl_srv.c`, X.509 gen in `net/https/`) are compiled in-tree; only redbean consumed them. `tls.wrap(socket)` shape depends on B1+B2. |
| IPv6 (`net`, `netip`) | IPv4 only, by type | Filed #144 (U5). **B1 is the pre-stable half.** |
| DNS control (`net.Resolver`) | `ip.lookup` (blocking, A-only) | Filed #145 (U6 timeout resolver), #146, #147. |
| Digests (`crypto/*`, `hash/crc32`) | sha256 family only | Filed #502/#501; **B4 is the pre-stable half.** |
| Symmetric crypto (`crypto/aes`, AEAD) | none (mbedTLS has AES-GCM/ChaCha20-Poly1305 linked, unexposed) | Filed #193 (crypto.encrypt/decrypt). Post-stable; one good AEAD API, not primitive soup. |
| gzip (`compress/gzip`) | C yes, cosmic no | **New — B3.** Streaming variant post-stable. |
| tar (`archive/tar`) | none (zip only) | Filed #500. Pure-Lua over B2 readers is fine. |
| strings/strconv | 7 functions | Filed #501 (contains/replace/fields/pad/lines/…). Additive; worth an early post-stable batch since it's the most-touched module in user code. |
| Leveled logging (`log/slog`) | syslog only | Filed #500 (`cosmic.log`). |
| Structured CLI (`flag`+subcommands) | getopt only | Filed #500 (`cosmic.cli`). |
| CSV / TOML | none | Filed #500. |
| Buffered/line IO (`bufio`) | only `fetch.Reader:lines` | Filed #501 (net readline) — generalize: `lines()`/`read_exact()` as Reader-interface helpers (B2), one impl for fd/net/fetch/child. |
| Templates (`text/template`) | `html.escape` only | Filed #500 P3 tail. Post-stable, low priority. |
| WebSocket | none | Filed #500 P3. Server C exists only in redbean/turfwar (not linked); treat as its own project. |
| Table utilities (`maps`/`slices`) | none | Filed #500 (`cosmic.table`). |
| uuid parse/validate | generate-only | **New, minor.** Additive. |
| Property testing | attempted, failed (#402) | Filed. |
| utf8 | Lua 5.4 built-in | Skip — document that `utf8` is the answer. |

**Deliberately not ported from Go** (recommend recording these as
non-goals): context/cancellation objects (per-call timeouts + poll
deadlines are the Lua-shaped answer), goroutines/channels (the model
here is `child` + `shm` + `poll`, which is coherent), `math/big`,
reflection-driven encoding, an `io/fs` VFS layer (zipos already covers
the embedded case), and a `sort` package (Lua `table.sort`).

## 5. Sequencing

1. **Breaking wave (pre-stable, cosmic-only, no upstream release
   needed):** B1 (address model, folds #498), B2 (EOF + Reader,
   retypes sse), B3 (compress formats), B5 (child option types), B6
   sweep. Nothing here requires a cosmopolitan change — gzip, digests,
   crc32, getaddrinfo are already bound or linked.
2. **Pre-stable C-side: nothing mandatory.** That is worth saying out
   loud: the C boundary work from #149–#153/#170 was sufficient; the
   remaining upstream items (#143–#148) are additive bindings.
3. **Stable cut.**
4. **Post-stable battery waves,** in leverage order: strings/table/log/
   cli batch (pure Teal, high daily value) → digests fill-out (#502) +
   codec crc32/base64url → tls (U4) → httpd over the linked HTTP parser
   → tar/gzip-streaming/csv → the P3 tail.

The one-sentence version: the #533 wave finished the conventions; what
remains before stable is freezing the two *data contracts* every future
battery composes over — addresses and byte streams — plus deleting the
one non-standard format (prefixed deflate) before anyone persists it.
