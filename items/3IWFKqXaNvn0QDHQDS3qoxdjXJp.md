A blocker edge carries a `--reason`, and that reason goes stale faster
than the edge does: the thing it names as undecided gets decided while
the edge itself stays correct. There is no verb that edits it.

Measured 2026-08-27 (session 0b13d2b4), board at `63e1a754`:

```
$ o/bin/gitboard block 3IUBNQZZ 3IVF3HbV --reason "…"
gitboard-block: 3IUBNQZZ already waits on 3IVF3HbV
```

`block` refuses an edge that exists rather than restating its reason,
and the only other route — `unblock` then `block` — drops a live
blocker for one commit, during which `next` would offer the item as
pullable. So the reason was updated by editing
`items/3IUBNQZZ8UHrBZD8Tgb7BgEx2zD.tl`'s `block_reason` table and
committing (`3f80716e`), which is the one-off workaround the work
skill allows when a verb is missing.

Two shapes would fix it, and picking between them is this item's job:
`block` becoming idempotent-with-restatement (an existing edge plus a
new `--reason` rewrites the reason and says so in the verdict line), or
a separate `reason` verb. The first keeps the vocabulary small; the
second keeps `block` honest about creating edges only.
