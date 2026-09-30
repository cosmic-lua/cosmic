--- The variables that name a CI run, its runner or its container rather
--- than anything a test is given, which a gating suite's workers are not
--- given (cosmic_ci.orchestration's `forget_run`): each of `exact`, and
--- each that begins with one of `prefixes` -- GitHub's, and the driver's
--- own switches -- but those of `kept`. `exact` holds systemd's per-unit
--- ones where a runner is a service, CI, and the container's HOSTNAME
--- (its ID, new every job); `kept` holds COSMIC_CI_REQUIRE_SANDBOX,
--- which a test reads (build/sandboxed_verdicts_test.tl).
---
--- Data alone, in text Lua reads as well as Teal: the tree's own
--- build/ci_tree_test.tl, which cannot require a module of ci/, loads
--- it to find a tree source that names one of them.
return {
  exact = { "CI", "INVOCATION_ID", "JOURNAL_STREAM", "HOSTNAME" },
  prefixes = { "GITHUB_", "RUNNER_", "ACTIONS_", "COSMIC_CI_" },
  kept = { "COSMIC_CI_REQUIRE_SANDBOX" },
}
