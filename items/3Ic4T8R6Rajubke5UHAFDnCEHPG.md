Evidence (review of PR #1540, 2026-08-30): after the gate-status
mirror's removal, nothing in `.github/workflows/pr.yml` posts a commit
status, but the workflow still grants `permissions: statuses: write`.
Not a security widening (the grant predates the change), just an
unused permission. One-line removal in pr.yml tightens the workflow's
permission surface to what it uses; verify with a grep that no
surviving step calls the statuses API before removing.
