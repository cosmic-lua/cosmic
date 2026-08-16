Build a word-statistics tool as a small multi-module project. The library is three separate modules in a `textstat/` directory: `textstat/tokenize.tl` exposing `tokenize(s: string): {string}` (lowercase the input and split it into maximal runs of ASCII letters; everything else is a separator); `textstat/count.tl`, which requires `textstat.tokenize` and exposes `count(s: string): {string: integer}` mapping each word to its occurrence count; and `textstat/report.tl`, which requires `textstat.count` and exposes `report(s: string): string` producing the final report text. Each of the three modules gets its own `*_test.tl` beside it. The binary is `o/bin/wordbag` (source `cmd/wordbag/main.tl`, requiring `textstat.report`), which reads the file named by its first argument and prints the report: the top 3 words as `<word> <count>` lines, ordered by count descending then word ascending, followed by `unique <n>` (the number of distinct words). First create the fixture `testdata/sample.txt` with exactly these 2 lines: `the quick brown fox jumps over the lazy dog` and `the dog barks`. Take the whole project to a green `ci` gate.

## Acceptance facts

- The files `textstat/tokenize.tl`, `textstat/count.tl`, `textstat/report.tl` exist, each with a sibling `*_test.tl` (`textstat/tokenize_test.tl` etc.).
- `textstat/count.tl` contains `require("textstat.tokenize")` and `textstat/report.tl` contains `require("textstat.count")` — a real import chain, not three islands.
- `cmd/wordbag/main.tl` exists and contains `require("textstat.report")`.
- `./cosmic --make build` produces an executable `o/bin/wordbag`.
- `./o/bin/wordbag testdata/sample.txt` exits 0 with stdout exactly these 4 lines: `the 3`, `dog 2`, `barks 1`, `unique 9` (ties among count-1 words break alphabetically, so `barks` beats `brown`).
- `./cosmic --make test` passes all four test files.
- `./cosmic --make ci` ends with `ci: PASS`.
