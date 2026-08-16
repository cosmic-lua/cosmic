Build a log-report tool. First create the fixture `testdata/events.log` with exactly these 7 lines:

```
2026-08-01T10:15:00Z INFO start
2026-08-01T10:59:59Z WARN low-disk
2026-08-01T11:00:00Z INFO tick
2026-08-01T11:30:12Z ERROR crash
2026-08-01T12:00:00Z INFO tick
2026-08-01T12:00:01Z INFO tick
2026-08-01T13:59:59Z WARN slow
```

Each line is `<ISO 8601 UTC timestamp> <LEVEL> <message>`. The tool is a compiled binary `o/bin/logreport` (source `cmd/logreport/main.tl`) taking one argument, the log file path. It parses every line, aggregates events into one-hour UTC buckets — an event belongs to the bucket its timestamp falls in, so a timestamp exactly on the hour (`11:00:00`) belongs to the `11:00` bucket, not the previous one — and prints one line per non-empty bucket in ascending time order, formatted `<YYYY-MM-DDTHH:00Z> <count>`, followed by a final line `total <n>`. An empty input file produces just `total 0`. A missing or unreadable file prints an error to stderr and exits non-zero. Ship tests (including a bucket-boundary case) and take the project to a green `ci` gate.

## Acceptance facts

- `./cosmic --make build` produces an executable `o/bin/logreport`.
- `./o/bin/logreport testdata/events.log` exits 0 with stdout exactly these 5 lines in order: `2026-08-01T10:00Z 2`, `2026-08-01T11:00Z 2`, `2026-08-01T12:00Z 2`, `2026-08-01T13:00Z 1`, `total 7`.
- The `11:00` bucket count is 2, not 1 or 3 — `2026-08-01T11:00:00Z` sits exactly on the boundary and must land in the `11:00` bucket (S-trap: off-by-one at the bucket edge).
- The `12:00` bucket count is 2 — `12:00:00Z` and `12:00:01Z` land together (same boundary rule from the other side).
- Given an empty file `empty.log`, `./o/bin/logreport empty.log` exits 0 with stdout exactly `total 0`.
- `./o/bin/logreport testdata/absent.log` exits non-zero, stdout is empty, stderr is non-empty.
- The workspace contains at least one `*_test.tl` whose tests include an on-the-hour boundary timestamp, and `./cosmic --make ci` ends with `ci: PASS`.
