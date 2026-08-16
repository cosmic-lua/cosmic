Build a child-process TCP echo orchestrator as one compiled binary `o/bin/echotrip` (source `cmd/echotrip/main.tl`) with two modes. Server mode, `echotrip serve`: listen on 127.0.0.1 with an OS-assigned ephemeral port (bind port 0 and recover the real port), then — only after the listener is ready — print exactly one line `PORT=<n>` to stdout (flushed), accept a single connection, echo every byte received back to the client until the peer closes, and exit 0. Orchestrator mode, `echotrip` with no arguments: spawn `o/bin/echotrip serve` as a child process with its stdout captured on a pipe, read the `PORT=<n>` line from the pipe as the readiness handshake (no fixed sleeps, no retry-until-connect polling), connect to 127.0.0.1 on that port, send exactly `round-trip-42` plus a newline, read the echo back, and verify it byte-for-byte. On success print exactly `OK round-trip-42` to stdout, wait for the child to exit, and exit 0; on any failure print a message to stderr and exit non-zero, leaving no child running. Ship tests and take the project to a green `ci` gate. Only loopback networking is used; nothing external.

## Acceptance facts

- `./cosmic --make build` produces an executable `o/bin/echotrip`.
- `./o/bin/echotrip serve` (run in the background) prints as its first stdout line a line matching `^PORT=[0-9]+$`, and a scorer-side TCP client connecting to 127.0.0.1 on that port that sends `probe` plus newline receives exactly `probe` plus newline back; after the client closes, the server process exits 0.
- `./o/bin/echotrip` exits 0 and its stdout is exactly `OK round-trip-42`.
- 10 consecutive runs of `./o/bin/echotrip` all exit 0 with identical stdout (S-trap: a readiness race between server bind and client connect fails intermittently under repetition).
- After `./o/bin/echotrip` exits, no `echotrip` process remains running (the orchestrator reaps its child).
- The workspace contains at least one `*_test.tl`, and `./cosmic --make ci` ends with `ci: PASS`.
