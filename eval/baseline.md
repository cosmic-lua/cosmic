# baseline

One row per run, newest last. Numbers compare across commits of one
agent and model on one task; the verdict is the grader's, never the
journal's. `notes (cli)` was the task before it asked for examples and
an executable; `notes` is `eval/task/notes.md`.

| task | next commit | agent | verdict | minutes | tool calls | cost | what the journal ranked first |
|---|---|---|---|---|---|---|---|
| notes (cli) | 6c8b40d | claude-code, sonnet | met, via hand-written `.d.tl` stubs | 15.4 | 96 | $3.21 | `require("cosmic.*")` fails outside cosmic's tree |
| notes (cli) | 0a23fec | claude-code, sonnet | met | 6.1 | 67 | $1.13 | the entry-point and argv contract stated nowhere |
| notes | 9412150 | claude-code, sonnet | met, binary built by hand through SQL | 13.5 | 126 | $3.04 | no verb produces an executable |
| notes | 9412150 + #1896 + #1898 | claude-code, sonnet | met | 6.8 | 70 | $1.33 | argv (a misreading; the transcript disproves it) |
| notes | 8a24c47f | claude-code, sonnet | met | 8.0 | 85 | $1.76 | the test and example rule stated nowhere |
