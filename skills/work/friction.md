# Collecting friction

`/work N --friction` runs the same orchestrator pass as `/work N` and
keeps a friction log alongside it: every inefficiency, confusion, or
wrong turn that made the pass or any agent in it slower, more
expensive in tokens, or worse in what it produced. the log is the
pass's second deliverable. it ends up on the board as one item to
triage, and every countermeasure in it that already passes the spec
bar is filed as its own item before the pass ends. the point is
enablement: the same wrong turn seen twice is a gate, a doc, or a
brief sentence waiting to be written, and this log is where the
evidence for it is measured rather than remembered.

## what counts as friction

anything where the goal and what actually happened differ in a way
that cost time, tokens, or quality. the usual shapes:

- a fact the spec should have carried but did not, discovered by
  building (a line cap with no headroom, a claim that turned out
  false, a file the spec named that had moved);
- work that was done and then discarded (a bounce that reverted its
  diff, a review that stopped because CI was still running, a spawn
  the lock made redundant);
- tool or doctrine text that steered wrong (a refusal message that
  names the bypass, a brief rule that contradicts a `help` topic, a
  placeholder that decoded escapes when pasted);
- effort spent rediscovering something the tree already documents
  (probe files to learn a language rule, a full gate run where a
  per-file check answered the question);
- a wrong or unsafe outcome that a gate did not catch, however it was
  caught in the end.

pure waiting on CI or a merge queue is not friction unless something
was spent during the wait.

## the shape of one observation

every entry has four parts, and the second one carries numbers:

1. **goal** — what the agent, or the orchestrator, was trying to do
   at that point, in one sentence.
2. **actually happened** — what occurred instead, with the
   indicators that size the cost: wallclock for the stretch, tool
   calls in it, tokens (input, output, cache read, cache create),
   errors and repeated identical calls, and for a builder the call
   index of the first edit. a comparison point helps when one
   exists (the same item on a second attempt, a sibling agent).
3. **contributed** — what in the spec, brief, tool, doctrine, tree,
   or environment made the difference between 1 and 2. name the
   file and line where there is one.
4. **improvement** — the countermeasure, ranked by leverage the way
   `gitboard help bar` ranks enablement: a gate in the tool over a
   doc, a doc over a skill sentence. say whether it already passes
   the spec bar; if it does, it is filed before the pass ends.

## the log

one file per pass, `friction-<date>-<label>.md` in the session's
scratch directory, opened before the first board verb runs:

```text
# friction: <date> <label> (/work N --friction)

## orchestrator
- <observation, four parts>

## <kind> <handle> (<model>) — <outcome>, <wall>, <tool calls>, <tokens>
- <observation, four parts>
...

## candidates
- <countermeasure> — filed as «handle» | stays here for triage: <why>
```

the orchestrator section is written as the pass runs, not after: a
refusal, a retry, a lost lock race, a respawn, a brief that had to be
edited by hand — each goes in when it happens, with the verb and the
verdict line that showed it. the agent sections are written when
each agent reports, from two sources that are kept apart in the
entry: what the agent said about itself, and what its transcript
shows.

## what the agent reports

the brief is emitted by `gitboard brief` and pasted verbatim; the
friction ask rides after it as an environment note, the same place
the worktree path and the GitHub reach go. the note is one paragraph:

```text
Friction: end your final report with a `## Friction` section of at
most five entries. Each entry names the goal you had at that point,
what actually happened instead (with how long it took and how many
tool calls it cost, as best you can tell), what in the spec, brief,
tree, tool, or environment made the difference, and what would have
prevented it. Report where the spec or brief was unclear, where a
tool refused or misled you, where you rediscovered something the
tree documents, and any work you did and then threw away. An empty
section is a real answer; never pad it.
```

the agent's own account is evidence about the brief and the spec —
what read as unclear to a fresh window — and is quoted as such, not
taken as the measurement.

## what the transcript shows

the Agent tool result names the transcript (`.output`, a JSONL file).
never read it whole; mine it for the indicators and quote those. with
`jq` on the path:

```sh
T=<transcript>
# tool calls by name, and the total
jq -r '.. | objects | select(.type=="tool_use") | .name' "$T" | sort | uniq -c
# results that came back as errors, with the call's first line
jq -r '.. | objects | select(.type=="tool_result" and .is_error==true)
       | (.content|tostring)[:160]' "$T"
# wallclock: first and last timestamp
jq -r 'select(.timestamp) | .timestamp' "$T" | sed -n '1p;$p'
# tokens: input, output, cache read, cache create
jq -s '[.[] | .. | objects | select(has("input_tokens") and has("output_tokens"))]
       | {inp: (map(.input_tokens)|add), out: (map(.output_tokens)|add),
          cache_read: (map(.cache_read_input_tokens//0)|add),
          cache_create: (map(.cache_creation_input_tokens//0)|add)}' "$T"
# commands run more than once (keyed on their first line)
jq -r '.. | objects | select(.type=="tool_use" and .name=="Bash")
       | .input.command | split("\n")[0]' "$T" \
  | sort | uniq -c | sort -rn | awk '$1>1' | head
# index of the first edit (a builder's exploration budget)
jq -r '.. | objects | select(.type=="tool_use") | .name' "$T" | grep -n -m1 'Edit\|Write'
```

the numbers go into the entry's second part verbatim. a long gap
between two calls is the model thinking or a tool running; which one
is read off the call that preceded it (a `--make ci` gap is the gate,
a `sed -n` gap is not).

## the orchestrator's own friction

the orchestrator observes itself by the same four parts. the things
worth watching for, because they recur: a verb refused and the
message that refused it; a spawn that produced nothing (a review that
stopped on running CI, a claim another session took first, an agent
killed and respawned); anything done twice; a brief edited by hand,
and why; a wait with no signal to wait on. each is one entry with
the verdict line or refusal text quoted.

## closing the pass

the friction log closes with the ledger, in this order:

1. every countermeasure that passes the spec bar is filed now —
   `gitboard new "<title>" --parent <goal> --spec-file <spec>` —
   with the log's entry as its Evidence; the candidates list names
   the handle.
2. the whole log is filed as one unparented item, title
   `friction: <date> <label>`, `gitboard new ... --spec-file <log>`,
   so it enters triage and the next refiner can attach, compare, or
   end it. a log with nothing in it is still filed: an empty log is
   a measurement.
3. the pass report names the log's handle and the handles it filed.
