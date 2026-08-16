--- Shared type definitions for the eval instrument (_eval).
--- The instrument stages a candidate binary into a reproducible run
--- directory (this file, suite.tl, stage.tl) and — in the sibling
--- scoring slice — checks the agents' output against it. Keeping the
--- records here, not duplicated in stage.tl and score.tl, is what lets
--- the two slices share one Manifest without drifting apart.

local record eval_types

  --- One eval task: a brief an isolated agent builds against.
  record Task
    --- Short slug: the workspace directory name under a run's <out>,
    --- and the id half of its `cmd/<id>`-shaped deliverable binary.
    id: string
    --- Path (repo-root relative) to the task's prompt fragment, e.g.
    --- "_eval/tasks/json-cli.md". The file holds the YOUR PROJECT
    --- paragraph staging substitutes into the frame, followed by an
    --- "Acceptance facts" list the scoring slice checks against —
    --- never shown to the agent.
    brief: string
    --- cosmic surfaces this task exercises (fs, json, sqlite, ...).
    --- Descriptive only: tunable in review, no version bump needed.
    surfaces: {string}
    --- Which failure classes this task is built to surface: "S"
    --- (silent bugs), "C" (checker-caught errors), "Y" (cycles to
    --- green), "G4" (gate-adoption), "G2" (containment). Frozen spec,
    --- pinned verbatim from the accepted #1135 §3.
    metrics: {string}
    --- "proven" (carried over from an earlier eval round) or "new".
    --- Frozen spec, same source as metrics.
    status: string
  end

  --- The suite: a versioned, ordered list of tasks. `version` bumps
  --- only when an id, metric set, or status changes — never for a
  --- `surfaces` edit.
  record Manifest
    version: integer
    tasks: {Task}
  end

  --- Staging-time metadata, written to <out>/meta.json by stage.tl.
  --- Probe fields are deliberately absent: the operator runs the
  --- leak probe after staging and saves its own output to
  --- <out>/probe.txt, which the scoring slice folds in separately.
  record Meta
    --- Unix seconds, when staging ran.
    timestamp: number
    --- The Manifest.version staged.
    suite_version: integer
    --- Path to the staged binary, as given to `--bin`.
    bin: string
    --- The staged binary's sha256, lowercase hex — the identity,
    --- since `bin` is only a path and two runs can both say
    --- "o/bin/cosmic" while staging different builds.
    bin_sha: string
    --- cosmic's own version string, read from the staged binary's
    --- build (cosmic.sys / cosmic._version), when available.
    cosmic_version: string
    os: string
    isa: string
    --- The three launch-command constants stage prints verbatim —
    --- recorded here so a run directory names what it was launched
    --- with, without re-deriving it from the printed text.
    model: string
    agent_tool: string
    timeout_secs: integer
  end

  --- Scoring-time metadata, written to <run dir>/results.json by
  --- score.tl. Field-for-field mirror of the staged Meta plus the two
  --- probe fields Meta deliberately omits (see Meta's doc comment):
  --- the operator-captured probe.txt, folded in here once staging is
  --- done and the operator has run the leak probe.
  record ResultMeta
    timestamp: number
    suite_version: integer
    bin: string
    bin_sha: string
    cosmic_version: string
    os: string
    isa: string
    model: string
    agent_tool: string
    timeout_secs: integer
    --- probe.txt's raw contents, verbatim. Empty when the file is
    --- missing from the run dir (never guessed).
    probe_output: string
    --- True iff probe_output contains anything but the READY/NONE
    --- pair the probe prompt asks for (see stage.tl's probe_command).
    --- Recorded, never a reason to abort scoring — the operator judges
    --- the run's validity from this field.
    leaked: boolean
  end

  --- One task's scored row.
  record Row
    task: string
    --- "completed" (artifact built and checked), "incomplete" (no
    --- built artifact -- NOT a silent bug), or "error" (the task's
    --- workspace itself is missing from the run dir).
    status: string
    --- From the task's committed functional check, never the agent's
    --- claims. 0 when status is not "completed" -- the check never ran.
    silent_bugs: integer
    --- Journal-derived, NULLABLE in v1: the retained artifacts are
    --- NOTES.md/final.txt only, and neither reliably yields a count of
    --- distinct --check failures without transcript retention (a named
    --- follow-up child on the epic). Left nil rather than guessed.
    checker_errors: integer
    --- Journal-derived, NULLABLE in v1, same reason as checker_errors:
    --- "cycles" needs a transcript of tool calls this slice does not
    --- retain. Left nil rather than guessed.
    cycles: integer
    --- Parsed from final.txt's five-line reply, when it parses.
    attempts_first_build: integer
    --- Parsed from final.txt's five-line reply, when it parses.
    attempts_green_ci: integer
    --- G4: did the agent reach the project's own gate unprompted.
    --- Journal-derived and NULLABLE in v1, same reason as cycles and
    --- checker_errors -- there is no transcript to derive it from
    --- mechanically, so it is left nil rather than guessed.
    gate_adopted: boolean
    --- G2, contained-task only. Journal-derived, same limitation as
    --- cycles/checker_errors/gate_adopted: no transcript exists in v1
    --- to count denials or recovery steps from, so both stay nil for
    --- every task and every platform rather than being guessed. Kept
    --- as separate fields (not folded into cycles) because a later,
    --- transcript-backed slice fills these in without touching the
    --- rest of the row.
    denials: integer
    denial_recovery_steps: integer
    --- From NOTES.md section (f), best-effort parsed. nil when the
    --- section is missing or its answer does not parse either way --
    --- never guessed. false is a lower bound: the row's other numbers
    --- may be optimistic.
    self_report_clean: boolean
    --- Path (relative to the run dir) to the task's workspace, which
    --- holds NOTES.md and final.txt -- the two files the journal is
    --- parsed from.
    journal_path: string
    --- NOTES.md section (b), verbatim, one entry per ranked item.
    --- Empty when the section is missing or unparseable.
    friction: {string}
  end

  --- The on-disk results format (JSON), written to <run dir>/results.json.
  record EvalResults
    meta: ResultMeta
    rows: {Row}
    --- "PASS" iff every proven task's row is "completed" AND
    --- sum(silent_bugs) == 0 over proven tasks. See score.tl's verdict
    --- function for the exact rule, including why an incomplete or
    --- errored proven task fails the gate on its own.
    verdict: string
  end
end

return eval_types
