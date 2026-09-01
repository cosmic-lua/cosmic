## Goal

Make `cosmo.Fetch`/`cosmo.FetchStream`'s failure-path tuple conform to
the boundary's canonical `T|nil, err string, errno?` shape (or, if kept
as-is, make that an explicit, documented exception) — part of G3's
"the boundary is exact" inventory (parent: cosmo-contracts container,
census item 3IR2TQdUPE14YWg2XOZBljh1iL7, slice "top-level cosmo
surface").

## Evidence

- C source: `tool/net/lfetch.c:301` includes `tool/net/fetch.inc`;
  `LuaFetch` at `fetch.inc:74`, `LuaFetchStream` at
  `tool/net/lfetch.c:705`, both routing failures through the shared
  `LuaFetchError` helper at `fetch.inc:16`:
  ```c
  static int LuaFetchError(lua_State *L, const char *kind, const char *fmt, ...) {
    ...
    lua_pushnil(L);
    lua_pushstring(L, buf);
    lua_pushstring(L, kind);
    return 3;
  }
  ```
  On success, `LuaFetch` instead pushes `(status, headers, body, url)`
  — 4 values (`tool/net/definitions.lua:2710`); `LuaFetchStream` pushes
  `(status, headers, reader, url)` (`definitions.lua:2734`).
- `tool/net/definitions.lua:2708-2714` (Fetch) and `:2732-2738`
  (FetchStream):
  ```
  ---@return integer|nil status, table<string,string> headers, string body, string url
  ---@return string? error
  ---@return cosmo.FetchErrorKind? kind
  ```
  Slot 2 is `headers` on success, `error` on failure. Slot 3 is `body`
  (or `reader`) on success, `kind` on failure. Arity is 4 on success, 3
  on failure.
- Probe transcript, from the cosmopolitan repo root against
  `o//tool/lua/lua` built by `make -j$(nproc) o//tool/lua/lua`:
  ```
  $ o//tool/lua/lua -e 'local cosmo=require("cosmo"); local a,b,c,d = cosmo.Fetch("http://this.host.invalid.tld.example/", {timeout=2}); print(a,b,c,d)'
  nil	getaddrinfo(this.host.invalid.tld.example:80) error: EAI_Name does not resolve No error information	dns	nil

  $ o//tool/lua/lua -e 'local cosmo=require("cosmo"); local a,b,c,d = cosmo.Fetch("http://example.com/", {timeout=8}); print("status=",a, "url=",d, "body_len=", c and #c)'
  status=	200	url=	http://example.com/	body_len=	559
  ```
  `cosmo.FetchStream` reproduces the identical 3-value failure shape
  when pointed at the same unresolvable host.
- Cosmic-side spend (`grep -rn 'cosmo\.Fetch' cosmic/` /
  `grep -rn 'cosmo\.FetchStream' cosmic/` in a `cosmic-lua/cosmic`
  checkout): `cosmic/fetch/init.tl:233`:
  ```teal
  local status, headers_or_err, body_or_kind, final_url = cosmo.Fetch(url, to_fetch_options(opts))
  if not status then
    return fail(headers_or_err, body_or_kind)
  end
  -- cast: from any
  local headers, raw_headers = fetch_headers.normalize(headers_or_err as {string: any})
  return make_response({
      status = status as integer, -- cast: dual-shape binding return
      ...
      body = body_or_kind,
      ...
    })
  ```
  and `cosmic/fetch/init.tl:362-365` (`FetchStream`, same pattern, comment
  "the raw union isn't narrowed statically as StreamReader (it carries
  the kind string on failure)"). Two explicit `-- cast:` escape hatches
  are needed at the one wrapper site to reconcile this shape — direct
  evidence the deviation costs real friction downstream, not just a
  documentation nit.

## Change

Classify and, if a change is warranted, propose one of:
1. Keep the shape but make it an explicit, named exception to the
   `T|nil, err string, errno?` convention (documented in the
   binding-contract-shape rule in `AGENTS.md`), since it is long-standing,
   load-bearing, and used by every fetch-shaped binding consistently
   between `Fetch` and `FetchStream`; or
2. Normalize by returning a single failure-info value in slot 2 (e.g. a
   record `{message, kind}`) instead of overloading slots 2 and 3 by
   branch, and updating cosmic's wrapper + generated types in lockstep,
   as its own change (never inside an optimization, per this repo's own
   `AGENTS.md` "Conventions" section).

Land any actual contract change with a matching `definitions.lua`
annotation change in the same commit and a cosmic-side type regen +
wrapper fix as its own follow-up PR.

## Non-goals

- No change to `Fetch`/`FetchStream`'s SUCCESS-path shape (4 values) —
  only the failure-path/slot-reuse question is in scope.
- No re-litigating `path.join(nil)` (#276) or `unix.clock_gettime`
  (#277).
- No bundling with `cosmo.DecodeLua`'s separate offset-slot deviation
  (a different capture).

## Acceptance

- A decision is recorded (accept-as-exception, or a concrete
  normalized shape) with the binding-contract-shape rule in this repo's
  `AGENTS.md` updated to reflect it.
- If normalized: `definitions.lua` for both bindings updated in the
  same commit; a matching cosmic-side type regen + wrapper fix (removing
  the two `-- cast:` sites at `cosmic/fetch/init.tl:233-244` and the
  equivalent at `:362`) lands as its own PR, never inside an
  optimization.
