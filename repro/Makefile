# Minimal reproduction of whilp/cosmic#744.
#
# Under a fresh, high-concurrency burst of Landlock-sandboxed children, one
# child intermittently loses a GLOBAL unveil grant and is denied a read it
# was granted. This strips the failure to its essence: no teal, no cosmic,
# no bootstrap — just landlock-make spawning many sandboxed children that
# each read one file covered ONLY by the global `.UNVEIL r:shared` grant.
#
# `shared/secret` is deliberately NOT a prerequisite of any rule, so
# landlock-make's per-prerequisite auto-grant cannot cover it — exactly like
# lib/cosmic/*.tl reads that rely on the global `r:lib` grant, not on being a
# prereq of the file that requires them. If the first-burst race drops the
# global grant, `cat` is denied (EACCES) and the probe records DENIED.
#
# Requires REAL Landlock (Linux >=5.13, not blocked). Where Landlock no-ops
# (local containers), every probe records `ok` — that only proves the
# harness runs, never that the race is absent.

o := o
N ?= 300

# Global sandbox grants, mirroring cosmic's enforced compile rule shape:
# write the output tree, read the shared payload + dummy deps, exec the host
# tools the recipe shell needs.
.PLEDGE := stdio rpath wpath cpath proc exec
.UNVEIL := rwc:$(o) r:shared r:deps rx:/usr rx:/bin rx:/lib rx:/lib64 r:/etc

# Dummy prerequisites, auto-granted per child like the compile rule's
# types/tl/bootstrap prereqs — several add_rule() calls per child before the
# global grant, so each ruleset is built the way the real ones are.
deps := $(wildcard deps/*)

probes := $(foreach i,$(shell seq 1 $(N)),$(o)/probe-$(i).got)

.PHONY: all
all: $(o)/canary.got $(probes)

# NOTE: `o` must already exist when a sandboxed child runs — unveil()
# silently skips a grant whose path is absent, so `rwc:o` would be dropped
# and the child could not write its output (cosmic solves this with its
# $(o)/.exists ordering trick). run.sh pre-creates `o` outside the sandbox.
#
# The read is done by the recipe SHELL itself (`: < file`, a redirection on a
# builtin — no exec), so the only thing under test is whether Landlock lets
# the sandboxed process OPEN a file covered by the global `r:shared` grant.
# Using `cat` here confounded a Landlock deny with cat dying (exec/seccomp).
$(o)/probe-%.got: .SANDBOXED := 1
$(o)/probe-%.got: $(deps)
	@if : < shared/secret 2>$(o)/probe-$*.err; then \
	  echo ok > $@ ; \
	else \
	  { printf 'DENIED rc=%s ' "$$?"; cat $(o)/probe-$*.err 2>/dev/null; } > $@ ; \
	fi

# Enforcement canary: open a file in a dir that is NOT unveiled, the same way
# (shell redirection). Under real Landlock this MUST be denied; if it opens
# `ok`, Landlock is no-oping and the run is inconclusive.
$(o)/canary.got: .SANDBOXED := 1
$(o)/canary.got: $(deps)
	@if : < hidden/secret 2>/dev/null; then \
	  echo 'ENFORCE=no' > $@ ; \
	else \
	  echo 'ENFORCE=yes' > $@ ; \
	fi
