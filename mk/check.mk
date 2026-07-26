# Included from the top-level Makefile at the position this block used to
# occupy, so parse order — and therefore every pattern-specific variable
# and its nesting — is unchanged (#786). The Makefile keeps aggregation
# and the shared path variables; each mk/*.mk holds one rule family.
#
# the check lanes: files, teal, format, lint.

all_built_files := $(foreach x,$(modules),$($(x)_files))
all_built_files += $(all_lua)
all_source_files := $(all_tests)
all_source_files += $(filter-out ,$(foreach x,$(modules),$($(x)_version)))
all_source_files += $(foreach x,$(modules),$($(x)_srcs))
all_source_files += $(all_tl)

.PHONY: files
## Build all module files
files: $(call filter-only,$(all_built_files))

# .got NAMES are $(o)-prefixed; the PREREQUISITE is the source (#775).
all_teals := $(patsubst %,$(o)/%.teal.got,$(call filter-only,$(all_source_files)))

.PHONY: check
## Run Teal type checking
check: teal

## Run teal type checker on all files
teal: $(o)/teal-summary.txt

$(o)/teal-summary.txt: $(all_teals) | $(build_reporter)
	@$(bootstrap_cosmic) -- $(build_reporter) --dir $(o) --out $@ $^

# The `--` is load-bearing (#801): without it the outer getopt consumes
# the child's --check-types, the child runs argument-less, drops into
# the REPL, reads EOF and exits 0 -- so --test faithfully records a pass
# for a check that never ran. lint gets this right at :84; test/mk has
# no inner flags to lose.
$(o)/%.teal.got: % $(cosmic_check_bin) | $(bootstrap_files)
	@$(cosmic_check_bin) --test $(basename $@) -- $(cosmic_check_bin) $(include_dir_flags) --check-types $<

all_formats := $(patsubst %,$(o)/%.format.got,$(call filter-only,$(all_source_files)))

## Check formatting on all files
format: $(o)/format-summary.txt

$(o)/format-summary.txt: $(all_formats) | $(build_reporter)
	@$(bootstrap_cosmic) -- $(build_reporter) --dir $(o) --out $@ $^

# `--` for the same reason as the teal rule above (#801). This gate had
# no second line of defence -- teal's work is redone by --compile-strict,
# but nothing else checks formatting -- so it silently passed everything.
$(o)/%.format.got: % $(cosmic_check_bin) | $(bootstrap_files)
	@$(cosmic_check_bin) --test $(basename $@) -- $(cosmic_check_bin) --check-format $<

# Lint every file that will land (#719): tracked, PLUS untracked ones
# git does not ignore. --others is what makes a brand-new file linted
# before it is staged; without it `git ls-files` alone reported green on
# a file it had never opened, so a new module or test got no lint at all
# locally and first failed in CI, where the checkout has it tracked.
# (teal/format/test never had that gap — their lists come from wildcards
# in each cook.mk, which see a file the moment it exists.)
# --exclude-standard keeps .gitignore honoured, so o/ and other build
# output stay out; a build leaves nothing untracked outside it.
#
# git ls-files fails SILENTLY outside a git checkout — an empty list
# would lint nothing and report green, so the summary recipe fails
# loudly instead. Tracked-but-deleted files appear in ls-files but
# cannot be made: lint what exists, surface the skips in the summary,
# fail if the filter collapses the list. The stamp records the linted
# set so a deletion (which only SHRINKS the prerequisite list) still
# rebuilds the summary instead of staying stale-green "up to date".
# sort dedupes, since --cached and --others are assembled separately.
lint_files := $(sort $(shell git ls-files --cached --others \
  --exclude-standard 2>/dev/null))
lint_present := $(wildcard $(lint_files))
lint_deleted := $(filter-out $(lint_present),$(lint_files))
all_linted := $(patsubst %,$(o)/%.lint.got,$(lint_present))

lint_list_stamp := $(o)/lint-files.stamp
# The makefile fixtures snapshot this very list (makefile_test's #800
# ratchet compares lint_files against all_source_files), but they
# otherwise depend only on the makefiles -- so adding a .tl WITHOUT the
# cook.mk edit, which is exactly the mistake the ratchet exists to
# catch, would leave the fixture stale and the ratchet green. The stamp
# is write-if-changed, so this rebuilds the fixture when the file set
# moves and never otherwise. build_make_out comes from _build/cook.mk,
# included well before this file.
$(build_make_out)/database.out: $(lint_list_stamp)

$(lint_list_stamp): .FORCE
	@$(bootstrap_cosmic) --build list $@ $(lint_present)

## Check file length limits on all files
lint: $(o)/lint-summary.txt

$(o)/lint-summary.txt: export REPORTER_NOTE = $(if $(lint_deleted),lint: skipped deleted tracked file(s): $(lint_deleted))
$(o)/lint-summary.txt: $(all_linted) $(lint_list_stamp) | $(build_reporter)
	$(if $(strip $(lint_files)),,$(error lint: git ls-files found nothing — not a git checkout?))
	$(if $(strip $(lint_present)),,$(error lint: no tracked file exists on disk — filter collapsed the list?))
	@$(bootstrap_cosmic) -- $(build_reporter) --dir $(o) --out $@ $(all_linted)

$(o)/%.lint.got: % $(build_lint) $(lint_style_lua) | $(bootstrap_cosmic)
	@$(bootstrap_cosmic) --test $(basename $@) $(bootstrap_cosmic) -- $(build_lint) $<

# The model gate (3f): does this repo still conform to the project model
# `cosmic --make` builds by? Every slice of phase 3 has been checking it
# by hand, and 3e regressed it unnoticed for exactly that reason — a
# bridge script imported `_make.*` from outside `cosmic/`, which
# the `_` rule forbids, and `bin/make ci` had nothing to say about it.
# A design whose central bet is "the tree describes itself" needs the
# claim gated, not remembered.
#
# It runs the FRESHLY BUILT binary, not the bootstrap: the model is the
# one in this checkout, including any change the same commit makes to
# the validator. Recorded through --test so the stage reports like the
# others -- the reporter names a check by the `.<kind>.got` suffix,
# so the target is `repo.model.got` and the stage reads as `model`.
$(o)/repo.model.got: $(cosmic_bin) $(all_source_files)
	@$(cosmic_bin) --test $(basename $@) -- $(cosmic_bin) --make check

.PHONY: model
## Check this repo against the `cosmic --make` project model
model: $(o)/model-summary.txt

$(o)/model-summary.txt: $(o)/repo.model.got | $(build_reporter)
	@$(bootstrap_cosmic) -- $(build_reporter) --dir $(o) --out $@ $^
