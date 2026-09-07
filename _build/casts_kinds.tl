--- The cast allowlist: every kind `docs/design/casts.md`'s `### `
--- headings name, as a structural test against the tree instead of a
--- hand-maintained inventory.
---
--- Each `Kind` claims a slice of the tree's `as` casts one of two ways:
--- a `pattern` (the `cosmic.ast` grammar -- `$X as $T`, a literal
--- target type, or `$T:<lua pattern>` predicate on the rendered type
--- text) applied to every file under `where`; or an `explicit` list of
--- exact sites, for a kind two neighbours share a file with and no
--- type-text predicate can tell apart (two casts to the same rendered
--- type, in the same file, doing two different jobs -- `cosmic/ast/
--- match.tl`'s two `as Node` sites are the sharpest example: one is
--- this tree's own AST surface, the other an incrementally-built
--- record, and nothing about either cast's TEXT says which). A kind
--- may carry both: `pattern`/`where` for the bulk of its sites, plus a
--- short `explicit` list for the handful a predicate cannot separate
--- from a sibling kind in the same file. An `explicit` entry is
--- `(path, exact trimmed source line)` -- stable under a line shifting
--- up or down the file, which a `(path, line number)` key would not
--- be, and precise enough that two casts sharing one line (`_cli.lint`
--- counts the LINE; this walks the AST, so a line holding two `as`
--- tokens is two sites) both resolve to the same entry.
---
--- `sites` is the shrink-only ceiling `_build/casts_test.tl` checks
--- every kind against: lower it by hand as a kind's sites are closed,
--- same discipline `_build/casts_baseline.tl` used to enforce per file.
--- Deleting a kind's entry outright, once its last site closes, is
--- itself part of that shrink -- casts.md's `### ` heading goes with it.

local record ExplicitSite
  --- The site's file, relative to the project root.
  path: string
  --- The exact trimmed source line the cast sits on.
  text: string
end

local record Kind
  --- The `### ` heading in `docs/design/casts.md` this kind names,
  --- verbatim.
  name: string
  --- A `cosmic.ast` pattern (`ast.compile_pattern`'s grammar), or `""`
  --- when this kind is `explicit`-only.
  pattern: string
  --- Path prefixes `pattern` applies to -- a directory (`"cosmic/fs/"`)
  --- or one exact file. Empty when `pattern` is `""`.
  where: {string}
  --- Sites a predicate cannot separate from a sibling kind sharing the
  --- same file and rendered type text.
  explicit: {ExplicitSite}
end

local KINDS: {Kind} = {
  {
    name = "tl compiler surface",
    pattern = "$X as $T",
    where = {
      "_tool/coverage/lines.tl", "_tool/discover.tl", "_tool/doc/signature.tl",
      "cosmic/_teal_ast_test.tl", "cosmic/_teal_discard.tl",
      "cosmic/ast/match_cast.tl", "cosmic/ast/match_test.tl", "cosmic/ast/node.tl",
    },
    explicit = {
      {path = "_types/tlast.tl", text = "return t as {any} -- cast: array view of a mixed AST table"},
      {path = "_types/tlast.tl",
        text = "local parse = tl.parse as function(string, string, string): ({any: any}, {any})"},
      {path = "_types/tlast_test.tl",
        text = "assert(#(stdlib_ast as {any}) > 0, -- cast: array view of a statement list"},
      {path = "cosmic/ast/match.tl", text = "return t as {any} -- cast: array view of a generic ast map"},
      {path = "cosmic/ast/match.tl",
        text = "local cap = match_cast.capture_name((n as {any: any})[\"casttype\"]) -- cast: tl-parser field this Node kind doesn't name"},
      {path = "cosmic/ast/match.tl",
        text = "return node[\"tk\"] as string -- cast: narrowed to string by is_rest_capture's own check"},
      {path = "cosmic/ast/match.tl",
        text = "and #arr(node[\"e2\"] as {any: any}) == 0 then -- cast: generic view of a call's args node"},
      {path = "cosmic/ast/match.tl",
        text = "return e1[\"tk\"] as string -- cast: narrowed to string by is_rest_capture's own check"},
      {path = "cosmic/ast/match.tl", text = "local mt = marker as {any: any} -- cast: generic ast node view"},
      {path = "cosmic/ast/match.tl",
        text = "local pnode = pv as Node -- cast: capture leaf is a node from the compiled pattern's own tree"},
      {path = "cosmic/ast/match.tl",
        text = "local name = pv[\"tk\"] as string -- cast: narrowed to string by is_capture's own check"},
      {path = "cosmic/ast/match.tl",
        text = "local pt = prev as {any: any} -- cast: generic ast node view of a prior binding"},
      {path = "cosmic/ast/match.tl",
        text = "caps[name] = nv as Node -- cast: a matched candidate node is a real Node"},
      {path = "cosmic/ast/match.tl",
        text = "if not (k is integer) and not IGNORE_KEYS[k as string] then -- cast: non-integer key is a field name"},
    },
  },
  {
    name = "userdata boundary",
    pattern = "$X as $T:..",
    where = {
      "_types/gentype_defs.tl", "cosmic/embed/init.tl", "cosmic/fs/dir_test.tl",
      "cosmic/fs/find.tl", "cosmic/fs/ops.tl", "cosmic/fs/tree.tl",
      "cosmic/fs/types.tl", "cosmic/fs/walk.tl",
    },
    explicit = {},
  },
  {
    name = "type-defeating test probe",
    pattern = "$X as $T",
    where = {
      "cosmic/check_assertions_test.tl", "cosmic/hash_test.tl",
      "cosmic/log_test.tl", "cosmic/quicksand/box/merge_test.tl",
    },
    explicit = {
      {path = "cosmic/check.tl", text = "return (module as {string: any})[name] ~= nil"},
      {path = "cosmic/check.tl", text = "local call = f as function(...: any): (any, any)"},
      {path = "cosmic/rand_test.tl",
        text = "ok = pcall(rand.int, 1.5 as integer, 3) -- cast: deliberate invalid input"},
      {path = "cosmic/quicksand/proxy/rules_test.tl",
        text = "assert(rules.auth_header(true as rules.ProxyRule) == nil, \"true injects nothing\")"},
    },
  },
  {
    name = "enum relation",
    pattern = "$X as $T",
    where = {
      "_fuzz/compress_fuzz_test.tl", "cosmic/compress_test.tl",
      "cosmic/hash.tl", "cosmic/sys.tl", "cosmic/sys_test.tl",
    },
    explicit = {
      {path = "cosmic/fetch/init.tl",
        text = "local k = (kind or \"invalid_request\") as ErrorKind -- cast: enum superset of binding string"},
    },
  },
  {
    name = "module surface record",
    pattern = "$X as $T",
    where = {"_fuzz/driver.tl", "_types/gentype.tl", "cosmic/coverage/init.tl"},
    explicit = {
      {path = "_types/tlast.tl", text = "local tl = tl_any as {string: any} -- cast: freshly loaded module surface"},
      {path = "_types/tlast.tl", text = "local hooks = tl.ast_hooks as {string: any} -- cast: carried-patch surface"},
      {path = "_types/tlast_test.tl",
        text = "local fresh_tl = tl_chunk() as {string: any} -- cast: freshly loaded module surface"},
    },
  },
  {
    name = "container variance",
    pattern = "$X as $T",
    where = {
      "cmd/cosmic/main.tl", "cosmic/_literal_format.tl",
      "cosmic/quicksand/proxy.tl", "cosmic/sandbox/init_test.tl",
    },
    explicit = {
      {path = "cosmic/quicksand/proxy/rules_test.tl",
        text = "assert(err:find(case[2] as string, 1, true), -- cast: tuple element"},
      {path = "cosmic/rand_test.tl",
        text = "assert(rand.shuffle(list as {any})) -- cast: widen {integer} to {any} param"},
      {path = "cosmic/sqlite/bind.tl",
        text = "local list = params as {any} -- cast: array-part probe of the params table"},
      {path = "cosmic/sqlite/bind.tl",
        text = "local named = params as {string: any} -- cast: map view of the params table"},
    },
  },
  {
    name = "generic T",
    pattern = "$X as $T",
    where = {"cosmic/deep.tl", "cosmic/fetch/extras.tl", "cosmic/shape.tl"},
    explicit = {},
  },
  {
    -- Same class as above, split out because its one site (a fresh
    -- table cast to the literal type name `T`) shares its file with
    -- "userdata boundary" casts of the same shape -- only the literal
    -- target type tells them apart, so this entry's `where` cannot
    -- merge with the broader `$X as $T` entry above without also
    -- claiming those sites.
    name = "generic T",
    pattern = "$X as T",
    where = {"cosmic/fs/walk.tl"},
    explicit = {},
  },
  {
    name = "map view of a declared value",
    pattern = "$X as $T",
    where = {"cosmic/ast/walk.tl", "cosmic/quicksand/box/init_test.tl"},
    explicit = {
      {path = "cosmic/check.tl", text = "local surface = module as {string: any}"},
      {path = "cosmic/quicksand/box/merge.tl",
        text = "acc = merge_section(\"\", acc, t as {string: any}) -- cast: record inspected as map"},
    },
  },
  {
    name = "binding contract shape",
    pattern = "$X as $T",
    where = {"cosmic/fd.tl", "cosmic/signal.tl"},
    explicit = {
      {path = "cosmic/fetch/init.tl",
        text = "local headers, raw_headers = fetch_headers.normalize(headers_or_err as {string: any})"},
      {path = "cosmic/fetch/init.tl", text = "status = status as integer, -- cast: dual-shape binding return"},
      {path = "cosmic/fetch/init.tl", text = "return fail(headers_or_err, reader_or_kind as string)"},
      {path = "cosmic/sqlite/bind.tl", text = "return raw_stmt:bind(i, v as string)"},
    },
  },
  {
    name = "runtime capability probe",
    pattern = "$X as $T",
    where = {
      "cosmic/_probe.tl", "cosmic/quicksand/init.tl", "cosmic/sandbox/init.tl",
      "cosmic/sandbox/plan.tl", "cosmic/stream.tl",
    },
    explicit = {},
  },
  {
    name = "metatable access",
    pattern = "",
    where = {},
    explicit = {
      {path = "_types/tlast.tl", text = "hooks.type_mt as {any: any}) -- cast: metatable as plain table identity"},
    },
  },
  {
    name = "function shape",
    pattern = "$X as $T",
    where = {"cosmic/net/connect.tl", "cosmic/net/socket.tl"},
    explicit = {},
  },
  {
    name = "record union after guard",
    pattern = "$X as $T",
    where = {
      "_make/closure.tl", "_make/stage.tl",
      "_perf/bench/micro_bench.tl", "cosmic/quicksand/box/run.tl",
    },
    explicit = {
      {path = "cosmic/check.tl",
        text = "local status = (wr as proc.WaitResult).status -- cast: record union after guard"},
    },
  },
  {
    name = "incremental record construction",
    pattern = "",
    where = {},
    explicit = {
      {path = "cosmic/ast/match.tl",
        text = "return out as Node -- cast: synthetic bare-list node for a rest-capture's value"},
      {path = "cosmic/fetch/init.tl", text = "return make_response(t as Response) -- cast: from any"},
      {path = "cosmic/quicksand/box/merge.tl",
        text = "return acc as types.BoxOptions -- cast: dynamic walk rebuilt as the record it walked"},
    },
  },
  {
    name = "pcall return shape",
    pattern = "$X as $T",
    where = {
      "_tool/coverage/minimum_test.tl", "cosmic/_teal_engine.tl",
      "cosmic/shm.tl", "cosmic/sqlite/extras.tl",
    },
    explicit = {},
  },
  {
    name = "binding constant by name",
    pattern = "$X as $T",
    where = {"cosmic/quicksand/caps.tl"},
    explicit = {},
  },
}

local record CastsKindsModule
  type ExplicitSite = ExplicitSite
  type Kind = Kind
  KINDS: {Kind}
end

local M: CastsKindsModule = {
  KINDS = KINDS,
}

return M
