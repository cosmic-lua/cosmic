#!/bin/sh
# repro-744.sh — minimal, deterministic reproduction of whilp/cosmic#744
# ("fresh-tree sandboxed compiles rarely fail module resolution").
#
# WHAT #744 ACTUALLY IS
# ---------------------
# Since the #729 sandbox rollout the .tl compile rule is enforced:
#
#     cook.mk:  $(o)/%.lua: .SANDBOXED := 1
#               $(o)/%.lua: .UNVEIL   := rwc:$(o) r:tlconfig.lua $(unveil_hostx)
#
# landlock-make auto-grants rx on each PREREQUISITE (the target's own
# source, types, tl, bootstrap, flag stamp) and merges the global
# .UNVEIL (Makefile: `.UNVEIL := $(unveil_base)` == `r:lib r:3p ...`).
# So a compile child can read `lib/**` ONLY through that one blanket
# `r:lib` grant.
#
# But the modules a file `require`s (`cosmic.fs`, `lib.docs.publish`,
# `cosmic.check`, ...) are NOT prerequisites of the compile rule — tl
# resolves them at type-check time by walking TL_PATH with io.open
# (tl.lua:7407 search_for). A failed io.open is treated, silently, as
# "file absent" and the compile ends with a clean, deliberate
#     file:line:col: error: module not found: '<mod>'
# — never a crash. That is the exact #744 signature.
#
# So the require-closure is reachable at compile time through exactly
# one grant: the global `r:lib`. When landlock-make forks a compile
# child whose ruleset is missing that grant (the #200 sandbox-state
# bleed across a parallel fork burst — the residual the #201 fork fix
# did not fully close), every `require` of a lib module resolves to
# EACCES -> nil -> "module not found". Its siblings, forked with an
# intact ruleset, compile the identical tree cleanly; reruns pass. All
# of the issue's observations follow from this.
#
# NECESSARY CONDITION (why it never reproduces "locally")
# -------------------------------------------------------
# The fault can only occur where Landlock is actually enforceable.
# Where it is not, cosmopolitan's unveil() no-ops, the compile sandbox
# restricts nothing, `r:lib` can never go missing, and the flake cannot
# happen. `require("cosmic.unveil").available()` is the authoritative
# check. This is why the offline CI lane (real root via sudo, Landlock
# live) hits it and a stock dev box does not.
#
# WHAT THIS HARNESS DOES
# ----------------------
# It reproduces the fault deterministically, without depending on the
# race, by modelling a single already-bled compile child: it applies a
# Landlock ruleset shaped exactly like the enforced compile rule's —
# the target source granted as a prerequisite, the output tree granted,
# host dirs granted — but with NO blanket grant over the module tree.
# It then runs `cosmic --compile` on a file that requires a sibling
# module and shows the compile fails with the #744 signature. A second
# run additionally grants the require-closure (modelling the fix:
# declare it as a prerequisite so landlock-make grants it regardless of
# the global) and shows the compile is clean.
#
# On a host without Landlock it SKIPs (exit 0), reporting why.
#
# Exit codes: 0 = reproduced-then-fixed as expected, or skipped;
#             1 = unexpected outcome (details printed).
set -eu

root=$(cd "$(dirname "$0")/../.." && pwd)
bin="$root/o/bootstrap/cosmic"
if [ ! -x "$bin" ]; then
  echo "repro-744: bootstrap missing at $bin; run 'bin/make bootstrap' first" >&2
  exit 2
fi

if ! "$bin" -e 'os.exit(require("cosmic.unveil").available() and 0 or 1)'; then
  echo "repro-744: SKIP — Landlock unavailable (unveil.available()=false)."
  echo "  The compile sandbox cannot enforce here, so #744's fault is"
  echo "  impossible on this host. Run on a Landlock-capable host (e.g."
  echo "  the CI offline lane) to reproduce."
  exit 0
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# Separate dirs so the require-closure can be granted or withheld by
# directory (what cosmopolitan's unveil grants), independent of the
# target source's grant: $work itself is never granted, only children.
mkdir -p "$work/main" "$work/mod" "$work/out"

cat > "$work/mod/mod.tl" <<'TL'
local record M
  greet: function(): string
end
function M.greet(): string
  return "hi"
end
return M
TL

cat > "$work/main/main.tl" <<'TL'
local mod = require("mod")
local function go(): string
  return mod.greet()
end
return { go = go }
TL

# Apply a compile-rule-shaped Landlock ruleset, then exec the compile.
# grant_mod=1 additionally grants the require-closure dir (the fix).
launch() {
  MOD_GRANT="$1" MAIN="$work/main" MOD="$work/mod" OUT="$work/out" BIN="$bin" "$bin" -e '
    local u = require("cosmic.unveil")
    local main = os.getenv("MAIN")
    local mod = os.getenv("MOD")
    local out = os.getenv("OUT")
    local bin = os.getenv("BIN")
    -- prerequisites the compile rule would auto-grant: the binary and the
    -- target source dir. The output dir stands in for rwc:$(o).
    assert(u.allow(bin, "rx"))
    assert(u.allow(out, "rwc"))
    assert(u.allow(main, "r"))
    -- the require-closure is NOT a prerequisite of the compile rule; it is
    -- reachable only via the global r:lib grant. Model the fix by granting it.
    if os.getenv("MOD_GRANT") == "1" then
      assert(u.allow(mod, "r"))
    end
    -- host surface, mirroring cook.mk unveil_hostx (proven under real
    -- enforcement by the sandbox-canary and the enforced CI families).
    for _, d in ipairs({ "/usr", "/bin", "/lib", "/lib64", "/proc" }) do
      u.allow(d, "rx")
    end
    u.allow("/etc", "r")
    u.allow("/dev/null", "rw")
    u.allow("/dev/random", "r")
    u.allow("/dev/urandom", "r")
    assert(u.commit())
    local tlp = mod .. "/?.lua;" .. mod .. "/?/init.lua"
    local cmd = string.format(
      "TL_PATH=%q LUA_PATH=\";;\" %q --compile %q > %q 2> %q",
      tlp, bin, main .. "/main.tl", out .. "/lua", out .. "/err")
    os.exit(os.execute(cmd) and 0 or 1)
  '
}

status=0

echo "repro-744: [1/2] compile with require-closure NOT granted (models a bled child)..."
if launch 0; then
  echo "repro-744: UNEXPECTED — compile succeeded though the module was not granted"
  status=1
elif grep -q "module not found: 'mod'" "$work/out/err"; then
  echo "repro-744: REPRODUCED — $(head -1 "$work/out/err")"
else
  echo "repro-744: compile failed, but not with the #744 signature:"
  cat "$work/out/err"
  status=1
fi

echo "repro-744: [2/2] compile with require-closure granted (models the fix)..."
if launch 1; then
  echo "repro-744: OK — granting the require-closure compiles clean"
else
  echo "repro-744: UNEXPECTED — compile failed even with the module granted:"
  cat "$work/out/err"
  status=1
fi

if [ "$status" -eq 0 ]; then
  echo "repro-744: PASS — fault reproduced under Landlock and closed by granting the require-closure"
fi
exit "$status"
