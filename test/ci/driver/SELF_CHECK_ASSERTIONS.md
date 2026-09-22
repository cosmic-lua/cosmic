# Bootstrap self-check assertion map

The former `selfcheck.sh` assertions now run as ordinary selected Teal tests in
the copied external project.

| Former assertion | Selected test |
| --- | --- |
| state path is external to candidate and driver project | `state_test.tl` (`test_external_path_*`) |
| fixture timeout is bounded and retains stdout/stderr | `fixture_test.tl` (`test_child_timeout_retains_diagnostics`) |
| target table parsing rejects malformed records | `fixture_test.tl` (`test_target_records_are_exact`) |
| success preserves cwd and an argv path containing spaces | `bootstrap_test.tl` (`test_driver_records_success_failures_timeout_and_interruption`) |
| exit 23, start failure, timeout, and interruption remain distinct | same test |
| report contains success, exit, start-error, timeout, and incomplete rows | same test |
| symlink operation database is rejected without changing its target | same test |
| cached runner and copied runner match the pin digest | `bootstrap_test.tl` (`test_bootstrap_verifies_and_copies_declared_trees_verbatim`) |
| namespace and testdata trees are copied byte-for-byte | same test |
| corrupt cache plus corrupt download is rejected | `bootstrap_test.tl` (`test_bootstrap_rejects_corrupt_cache_and_download`) |
| corrupt cache is replaced only by a digest-valid download | `bootstrap_test.tl` (`test_bootstrap_replaces_a_corrupt_cache_from_a_verified_download`) |
| pre-existing namespace, symlink runner, and candidate-contained destination are rejected | `bootstrap_test.tl` (`test_bootstrap_rejects_hostile_destinations`) |
| interrupted source copy leaves neither declared destination tree | `bootstrap_test.tl` (`test_interrupted_source_copy_leaves_no_destination_tree`) |
| the check entry refuses a project carrying a prior build database | `bootstrap_test.tl` (`test_check_entry_rejects_a_prestaged_project`) |
| selected tests execute fresh | `check-driver.sh` runs a newly copied project and requires the host's `ran, 0 stood` verdict |

The former `orchestration-selfcheck.sh` assertions also run in the copied
external project:

| Former orchestration assertion | Selected test |
| --- | --- |
| valid matching attestations pass | `orchestration_test.tl` (`test_provenance_failures_are_durable`) |
| changed, corrupt, or missing attestations fail durably | same test and provenance validation branches |
| work and operation state cannot enter either protected project | `orchestration_test.tl` (`test_platform_protects_paths_and_retains_primary_failure`) and `runner_test.tl` (`test_runner_records_without_aliasing_subject_or_project`) |
| cache restore copies only Zig cache directories | `orchestration_test.tl` (`test_platform_protects_paths_and_retains_primary_failure`) |
| large output remains in diagnostic files | same test |
| disposable snapshot inspection state is removed | same test |
| suite exit 23 remains primary when its snapshot also fails | same test |
