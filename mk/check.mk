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

$(o)/%.teal.got: % $(cosmic_check_bin) | $(bootstrap_files)
	@$(cosmic_check_bin) --test $(basename $@) $(cosmic_check_bin) $(include_dir_flags) --check-types $<

all_formats := $(patsubst %,$(o)/%.format.got,$(call filter-only,$(all_source_files)))

## Check formatting on all files
format: $(o)/format-summary.txt

$(o)/format-summary.txt: $(all_formats) | $(build_reporter)
	@$(bootstrap_cosmic) -- $(build_reporter) --dir $(o) --out $@ $^

$(o)/%.format.got: % $(cosmic_check_bin) | $(bootstrap_files)
	@$(cosmic_check_bin) --test $(basename $@) $(cosmic_check_bin) --check-format $<

# Lint every tracked file (#719). git ls-files fails SILENTLY outside
# a git checkout — an empty list would lint nothing and report green,
# so the summary recipe fails loudly instead. Tracked-but-deleted files
# appear in ls-files but cannot be made: lint what exists, surface the
# skips in the summary, fail if the filter collapses the list. The
# stamp records the linted set so a deletion (which only SHRINKS the
# prerequisite list) still rebuilds the summary instead of staying
# stale-green "up to date".
lint_tracked := $(shell git ls-files 2>/dev/null)
lint_present := $(wildcard $(lint_tracked))
lint_deleted := $(filter-out $(lint_present),$(lint_tracked))
all_linted := $(patsubst %,$(o)/%.lint.got,$(lint_present))

lint_list_stamp := $(o)/lint-files.stamp
$(lint_list_stamp): .FORCE
	@$(bootstrap_cosmic) --build list $@ $(lint_present)

## Check file length limits on all files
lint: $(o)/lint-summary.txt

$(o)/lint-summary.txt: export REPORTER_NOTE = $(if $(lint_deleted),lint: skipped deleted tracked file(s): $(lint_deleted))
$(o)/lint-summary.txt: $(all_linted) $(lint_list_stamp) | $(build_reporter)
	$(if $(strip $(lint_tracked)),,$(error lint: git ls-files found nothing — not a git checkout?))
	$(if $(strip $(lint_present)),,$(error lint: no tracked file exists on disk — filter collapsed the list?))
	@$(bootstrap_cosmic) -- $(build_reporter) --dir $(o) --out $@ $(all_linted)

$(o)/%.lint.got: % $(build_lint) $(lint_style_lua) | $(bootstrap_cosmic)
	@$(bootstrap_cosmic) --test $(basename $@) $(bootstrap_cosmic) -- $(build_lint) $<
