# Work Loop

the autonomous work loop runs on a schedule (every 3 hours) or on-demand via GitHub Actions. it picks issues from the repository, plans and implements changes, then opens pull requests.

## Pipeline

```
make work
  └── retry up to 3 times:
        preflight → plan → do → push → check → act
```

### Preflight

implemented in `lib/work/work.tl` subcommands:

1. **labels**: ensure required labels exist (`todo`, `doing`, `blocked`)
2. **pr-limit**: exit if too many open PRs (default: 4)
3. **issues**: fetch open issues labeled `todo`, write `issues.json`
4. **issue**: pick highest-priority issue, write `issue.json`
5. **doing**: transition issue label from `todo` to `doing`

### Agent Steps

each agent step runs in `ah` (agent harness) with:
- `--sandbox`: pledge/unveil restrictions
- `--skill`: loads a skill file (plan, do, check)
- `--max-tokens`: budget limit
- `--db`: session database for observability
- `--must-produce`: required output file

**plan**: reads issue context, writes `o/work/plan/plan.md` — a structured work plan with goals, entry points, and implementation steps.

**do**: reads issue + plan + any feedback from previous iterations. creates a git branch, implements changes, runs validation. resets branch to default on retry.

**push**: `git push --force-with-lease -u origin HEAD`

**check**: reviews the diff against the plan. writes `o/work/check/actions.json` with a verdict. if verdict is "needs-fixes", writes `o/work/do/feedback.md` which triggers a retry.

**act**: executes actions from check phase — typically opening a PR or posting a comment. implemented in `lib/work/work.tl act` subcommand.

## Convergence

the retry mechanism works through Make dependencies:

1. `check` writes `feedback.md` when fixes are needed
2. `do_done` depends on `feedback.md`, so it becomes stale
3. next `make` invocation re-runs `do → push → check → act`
4. each attempt gets its own session database (`session-1.db`, `session-2.db`, `session-3.db`)

```makefile
work:
    -@LOOP=1 $(converge)    # first attempt (failure tolerated)
    -@LOOP=2 $(converge)    # second attempt (failure tolerated)
    @LOOP=3 $(converge)     # third attempt (must succeed)
```

## Configuration

environment variables:

| variable | default | description |
|----------|---------|-------------|
| `REPO` | `whilp/cosmic` | GitHub repository |
| `MAX_PRS` | `4` | max open PRs before stopping |
| `DEFAULT_BRANCH` | auto-detected | base branch for work |

## GitHub Actions

`work.yml` runs on schedule or manual dispatch:

```yaml
on:
  schedule:
    - cron: '0 */3 * * *'
  workflow_dispatch:
```

it:
1. checks out the repo with full history
2. fetches the `ah` binary
3. runs `make work`
4. uploads `o/` as an artifact for debugging

## Observability

after a work run, the `o/work/` directory contains:

```
o/work/
  issues.json           all fetched issues
  issue.json            picked issue with branch name
  doing.json            label transition result
  plan/
    plan.md             structured work plan
    session-*.db        agent session databases
  do/
    done                sentinel file
    feedback.md         check feedback (if retry needed)
    session-*.db        agent session databases
  push/
    done                sentinel file
  check/
    done                sentinel file
    actions.json        verdict and actions
    session-*.db        agent session databases
  act.json              action execution result
```

session databases are SQLite files queryable with `ah` tools.
