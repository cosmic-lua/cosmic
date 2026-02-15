# work.mk: work targets
#
# implements the PDCA work loop as make targets:
#   preflight -> issues.json -> issue.json -> plan -> do -> push -> check -> act
#
# convention: work.tl subcommands read WORK_* env vars and write json to
# stdout. a single pattern rule provides the recipe; dependency-only rules
# add per-target prerequisites.
#
# convergence: check writes o/work/do/feedback.md when verdict is needs-fixes.
# since do depends on feedback.md, the next make run re-executes do -> push -> check.
# the caller runs `make work` which loops until convergence or a retry limit.

REPO ?= whilp/ah
MAX_PRS ?= 4
AH := $(o)/bin/ah
work_tl := lib/work/work.tl

# put o/bin on PATH so shebangs (#!/usr/bin/env cosmic) work
export PATH := $(CURDIR)/$(o)/bin:$(PATH)

# detect the remote default branch
# in CI: DEFAULT_BRANCH is set by the workflow from github.event.repository.default_branch
# locally: fall back to git symbolic-ref, then origin/main
DEFAULT_BRANCH ?= $(shell git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/||')
DEFAULT_BRANCH := $(or $(DEFAULT_BRANCH),origin/main)

# shared env vars for all work scripts
export WORK_REPO := $(REPO)
export WORK_MAX_PRS := $(MAX_PRS)
export WORK_DEFAULT_BRANCH := $(DEFAULT_BRANCH)
export WORK_INPUT := $(o)/work/issues.json
export WORK_ISSUE := $(o)/work/issue.json
export WORK_ACTIONS := $(o)/work/check/actions.json

# named targets
all_issues := $(o)/work/issues.json
picked_issue := $(o)/work/issue.json
doing := $(o)/work/doing.json
plan := $(o)/work/plan/plan.md
feedback := $(o)/work/do/feedback.md
on_branch := $(o)/work/branch.ok
do_done := $(o)/work/do/done
push_done := $(o)/work/push/done
check_done := $(o)/work/check/done
act_done := $(o)/work/act.json

.DELETE_ON_ERROR:

# LOOP: set by the work target (1, 2, 3) to give each convergence
# attempt its own session database. defaults to 1 for manual runs.
LOOP ?= 1

# --- preflight ---

# pattern: run work.tl subcommand, capture json stdout to output file
$(o)/work/%.json: $(work_tl) $(cosmic)
	@mkdir -p $(@D)
	@$(work_tl) $* > $@

# per-target dependencies (no recipes)
$(all_issues): $(o)/work/labels.json $(o)/work/pr-limit.json
$(picked_issue): $(all_issues)
$(doing): $(picked_issue)

# --- agent targets ---

$(plan): $(doing) $(picked_issue) $(AH)
	@mkdir -p $(@D)
	@echo "==> plan"
	@timeout 180 $(AH) -n \
		--sandbox \
		--skill plan \
		--must-produce $@ \
		--max-tokens 100000 \
		--db $(o)/work/plan/session-$(LOOP).db \
		< $(picked_issue)

# feedback.md: created empty after plan, updated by check agent.
# exists as an explicit target so make can resolve the dependency from do_done.
$(feedback): $(plan)
	@mkdir -p $(@D)
	@touch $@

$(on_branch): $(plan) $(picked_issue)
	@git checkout -B $$(jq -r .branch $(picked_issue)) $(DEFAULT_BRANCH)
	@touch $@

$(do_done): $(on_branch) $(plan) $(feedback) $(picked_issue) $(AH)
	@mkdir -p $(@D)
	@echo "==> do"
	@if ! git diff --quiet $(DEFAULT_BRANCH)..HEAD 2>/dev/null; then \
		echo "  (retrying: resetting branch to $(DEFAULT_BRANCH))"; \
		git reset --hard $(DEFAULT_BRANCH); \
	fi
	@timeout 300 $(AH) -n \
		--sandbox \
		--skill do \
		--max-tokens 200000 \
		--unveil $(o)/work/plan:r \
		--db $(o)/work/do/session-$(LOOP).db \
		< $(picked_issue)
	@touch $@

$(push_done): $(do_done)
	@mkdir -p $(@D)
	@echo "==> push"
	@git push --force-with-lease -u origin HEAD
	@touch $@

$(check_done): $(push_done) $(plan) $(AH)
	@mkdir -p $(@D)
	@echo "==> check"
	@timeout 180 $(AH) -n \
		--sandbox \
		--skill check \
		--must-produce $(o)/work/check/actions.json \
		--max-tokens 100000 \
		--unveil $(o)/work/plan:r \
		--unveil $(o)/work/do:r \
		--db $(o)/work/check/session-$(LOOP).db \
		< /dev/null
	@touch $@

# act uses the pattern rule; add dependencies here
$(act_done): $(check_done) $(picked_issue)

# work: converge on act_done, retrying up to 3 times.
# each attempt rebuilds the full chain (do -> push -> check -> act).
# earlier attempts tolerate failure; only the last must succeed.
# when check writes feedback.md, do_done becomes stale and re-runs.
.PHONY: work
converge := $(MAKE) $(act_done)
work:
	-@LOOP=1 $(converge)
	-@LOOP=2 $(converge)
	@LOOP=3 $(converge)
