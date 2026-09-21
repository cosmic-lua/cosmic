# CI operation driver

`bootstrap-driver.sh` verifies the immutable prerelease pin on downloads, cache
hits, and the copied runner. It copies `driver.tl.in` to a temporary project
outside the candidate checkout. The runner must also live outside that checkout
so Cosmic treats the candidate only as the explicit working directory.

The driver writes a committed `start` event before launching each operation and
a separate `complete` event afterward. A killed driver therefore leaves an
`incomplete` operation visible to `report`. Output is inherited, so command
output is never accumulated in memory. Use file redirection around the driver
when a retained log is needed.

Run an operation with:

```sh
cosmic driver.tl run DB WORKER RUN ATTEMPT PHASE CANDIDATE TIMEOUT_MS EXECUTABLE ARGS...
```

Write a Markdown report with:

```sh
cosmic driver.tl report DB REPORT.md
```
