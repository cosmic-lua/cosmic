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
end

return eval_types
