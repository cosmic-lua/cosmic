Evidence (fresh-context review of PR #1534, 2026-08-29):
`.github/actions/gate-status/action.yml` carries the comment "every
other trigger this workflow declares (`push`, `workflow_dispatch`)
carries no pull-request payload" — but pr.yml now also declares
`merge_group` (landed by PR #1534), which the enumeration does not
name. The behavior is correct (the SHA expression's `github.sha`
fallback covers merge_group, and pr.yml's own comment explains it);
only the action's enumerating comment is now incomplete and misleads a
reader who starts there. The change is a one-line comment correction
in the action file adding `merge_group` to the enumeration.
