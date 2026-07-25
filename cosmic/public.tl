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
--- `table` (added by #500's battery wave) collides likewise, the `tbl`
--- binding convention avoids the shadow, and its surface (deep_*,
--- map/filter/reduce) is disjoint from the stdlib's — keep;
--- `require` is already internal; `env`, `time`, and the rest carry no
--- Lua global collision — keep.
local public: {string} = {
  "ansi",
  "benchmark",
  "check",
  "child",
  "codec",
  "compress",
  "coverage",
  "doc",
  "embed",
  "env",
  "envd",
  "errno",
  "example",
  "fd",
  "fetch",
  "flags",
  "format",
  "fs",
  "fuzzy",
  "getopt",
  "hash",
  "html",
  "ip",
  "json",
  "landlock",
  "log",
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
  "stream",
  "string",
  "sys",
  "syslog",
  "table",
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
--- likewise internal. Implementation shards of public modules live
--- inside their directory module (fs/, sqlite/, doc/, docs/, fetch/,
--- net/, child/, format/), so they no longer occupy top-level names
--- (#557); submodules under a public name stay non-API.
---
--- `doc` vs `docs` (#557's judgment call, recorded so this never
--- re-opens without new evidence): converged into the single public
--- `doc` family. Extraction from Teal source (parse/render/gendoc, the
--- index generator) and the embedded-index query surface behind
--- `--docs` (run/search/list_topics) are both `cosmic.doc`; two
--- top-level modules one letter apart was itself the ergonomics bug.
---
--- #566 capstone decisions, recorded so they never re-open without new
--- evidence: `make` is internal — its sole consumer is the `--make` CLI
--- handler; it is project-scaffolding tooling, not runtime API
--- (promoting internal→public later is cheap; the reverse is impossible
--- after the stable cut). `envd` stays public (a runtime battery for
--- user binaries: embedded env.d + envd.load(); zero in-repo consumers
--- is its expected shape). `check` stays public (the assertion half of
--- the shipped test battery alongside testrun/example/benchmark).
--- `errno` stays public (the error convention's user-facing interface:
--- wrappers document errno.is/errno.name_of by name).
---
--- #756 item 3: `build` is internal — the shell-free recipe steps
--- behind the `--build` CLI flag; build-system tooling like `make`,
--- not runtime API.
local internal: {string} = {
  "build",
  "cli",
  "make",
  "public",
  "require",
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
