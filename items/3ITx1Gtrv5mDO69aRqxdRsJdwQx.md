## Evidence

The pin-bump procedure (landed 3ISVlHT6, restated verbatim in
3ITpcO21's spec) proves a candidate release carries a feature with
`git merge-base --is-ancestor <feature-sha> <tag sha>`. That reads the
wrong sha: a release's TAG commit is not the commit its binary was
built from.

Measured on release `2026-08-27-6b88a0d` (2026-08-27, whilp/cosmic):

- tag object: `refs/tags/2026-08-27-6b88a0d` -> commit `c9ecd10b`
  (#1431 "format: a function type's return list stops at a code
  keyword"), five commits after `6b88a0db`.
- the run that built and published it: release.yml run 33034667243,
  `event=workflow_dispatch`, `head_sha=6b88a0db4`.

`gh release create` is called with `target_commitish: main`, so the tag
lands at main's head at PUBLISH time, while the artifact was built at
the dispatched run's head. The two diverge whenever main advances
during the ~9 minutes between run start and publish (03:19:40Z ->
03:28:45Z here).

The failure this admits is a FALSE POSITIVE, not a false negative: a
release dispatched at a commit BEFORE the feature, but published after
main advanced past it, passes the ancestry check while its binary does
not carry the feature. The pin would then be bumped to a bootstrap
missing the mechanism the whole bump exists to obtain, and the failure
surfaces later as a cold-build error in whatever item was gated on it.

3ITpcO21 got the right answer by luck of the dispatch: its run's
head_sha WAS `6b88a0db`, the feature commit itself. Verified
empirically instead of by the tag: the downloaded bootstrap's
`_make.patch` exports `paths_of_pin` and `read_all`, the #1424
mechanism.

The check that would be sound reads the release's own build provenance
(the publishing workflow run's `head_sha`), or the procedure proves the
mechanism directly against the downloaded binary rather than by
ancestry. Which of those, and where the procedure text lives, is the
work.
