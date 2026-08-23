## Evidence

Observed 2026-08-23 in a scheduled session landing `3IFUaiGA` (PR #1332).
`gitboard land 3IFUaiGA` refused:

```
gitboard-land: REFUSED (403: this client may not merge PR #1332 into the base
branch — a permission refusal, not the diff. ...
PUT /repos/whilp/cosmic/pulls/1332/merge: HTTP 403: Merging into a protected
base branch is not permitted for this session type.)
```

The refusal message is good — it names the cause, says the accept stands, and
tells the session to merge by another route and re-run `land`, which then took
the already-merged path and ended the item cleanly (`gitboard-land: PR #1332 was
already merged` / `gitboard-done: 3IFUaiGA completed (land)`). That recovery
worked exactly as written.

What is worth deciding is that the FIRST path never works from this kind of
session: a scheduled Claude Code session on the web reaches GitHub through the
GitHub MCP server, whose merge call succeeded on the same PR seconds later
(`merge_method: squash`), while `gitboard`'s own token cannot merge into a
protected `main` at all. So every scheduled run pays the same refused call plus a
manual out-of-band merge before `land` can finish — the finish-first rule's
first action, refused by construction.

Candidate shapes: have `land` detect the 403 and say which route to use rather
than treating it as a per-run surprise; document the out-of-band merge as the
expected path for session types that cannot merge; or give the board branch's
token merge rights. Not obviously one of the three — hence a capture, not a
slice.
