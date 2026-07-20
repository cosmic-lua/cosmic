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

$(o)/probe-%.got: .SANDBOXED := 1
$(o)/probe-%.got: $(deps)
	@mkdir -p $(o)
	@if cat shared/secret >/dev/null 2>$(o)/probe-$*.err; then \
	  echo ok > $@ ; \
	else \
	  printf 'DENIED: %s\n' "$$(cat $(o)/probe-$*.err)" > $@ ; \
	fi

# Enforcement canary: read a file in a dir that is NOT unveiled. Under real
# Landlock this MUST be denied; if it reads `ok`, Landlock is no-oping and the
# whole run is inconclusive (every probe would trivially pass). run.sh checks
# this before trusting a clean result.
$(o)/canary.got: .SANDBOXED := 1
$(o)/canary.got: $(deps)
	@mkdir -p $(o)
	@if cat hidden/secret >/dev/null 2>/dev/null; then \
	  echo 'ENFORCE=no' > $@ ; \
	else \
	  echo 'ENFORCE=yes' > $@ ; \
	fi
