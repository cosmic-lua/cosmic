Build a reusable slug library: a module `slug.tl` at the workspace root exposing a function `slugify(s: string): string` that turns arbitrary text into a URL slug. The rules: lowercase the input; every maximal run of characters that are not ASCII letters or digits becomes a single `-`; strip any leading and trailing `-`; the empty string (or input with no letters or digits) slugifies to the empty string. Beside it write `slug_test.tl` with at least five distinct `test_*` functions covering the rules, including the empty-input and punctuation-run cases. Also provide a thin CLI wrapper: a compiled binary `o/bin/slug` (source `cmd/slug/main.tl`) that requires the module, slugifies its first command-line argument, prints the result followed by a newline, and exits 0. Take the whole project to a green `ci` gate.

## Acceptance facts

- The workspace contains `slug.tl` and `slug_test.tl`, and `slug_test.tl` defines at least five `test_*` functions.
- `./cosmic --make test slug_test.tl` passes.
- `./cosmic --make build` produces an executable `o/bin/slug`.
- `./o/bin/slug 'Hello, World!'` exits 0 with stdout exactly `hello-world`.
- `./o/bin/slug '  --Multi--  Space__Test  '` exits 0 with stdout exactly `multi-space-test`.
- `./o/bin/slug '!!!'` exits 0 with stdout exactly one empty line.
- `cmd/slug/main.tl` contains `require("slug")` — the CLI uses the module rather than reimplementing it.
- `./cosmic --make ci` ends with `ci: PASS`.
