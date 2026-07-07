--- The PUBLIC module manifest: the single source of truth for which
--- top-level cosmic.* modules are supported, documented API surface.
---
--- Every requireable name directly under cosmic.* must appear in exactly
--- one of the two lists below; public_test.tl enumerates the modules
--- embedded in the binary and fails when one is missing or stale.
--- Internal modules are implementation shards: they can change or
--- disappear without notice, so user code must not require them.

--- Public, documented, stable modules (see the module table in CLAUDE.md).
---
--- Names that shadow a Lua global when bound naturally are avoided:
--- io became fd (#532), assert became check (#561). Decisions on the
--- remaining stdlib-colliding names, recorded so this never re-opens:
--- `string` collides but the entrenched `str` binding convention avoids
--- the shadow and the module is a strict superset-by-addition — keep;
--- `require` is already internal; `env`, `time`, and the rest carry no
--- Lua global collision — keep.
local public: {string} = {
  "benchmark",
  "check",
  "child",
  "codec",
  "compress",
  "doc",
  "docs",
  "embed",
  "env",
  "envd",
  "errno",
  "example",
  "fd",
  "fetch",
  "format",
  "fs",
  "fuzzy",
  "getopt",
  "hash",
  "html",
  "ip",
  "json",
  "landlock",
  "make",
  "net",
  "pledge",
  "poll",
  "proc",
  "quicksand",
  "rand",
  "re",
  "sandbox",
  "shm",
  "signal",
  "sqlite",
  "sse",
  "string",
  "sys",
  "syslog",
  "teal",
  "testrun",
  "time",
  "tty",
  "unveil",
  "url",
  "user",
  "uuid",
  "zip",
}

--- Internal implementation shards and tooling: not API. The cli
--- directory module (the binary's dispatcher and its helpers) is
--- likewise internal.
local internal: {string} = {
  "child_io",
  "cli",
  "doc_render",
  "doc_types",
  "docindex",
  "docs_lookup",
  "docs_render",
  "fetch_headers",
  "format_rules",
  "gendoc",
  "net_socket",
  "public",
  "require",
  "sqlite_bind",
  "sqlite_params",
  "sqlite_row_iter",
  "sqlite_stmt_cache",
  "version",
}

local record PublicModule
  public: {string}
  internal: {string}
end

local M: PublicModule = {
  public = public,
  internal = internal,
}

return M
