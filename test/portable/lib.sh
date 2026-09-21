# Shared shell support for test/portable. Source it; it defines functions and
# sets no global state on its own. Every function is POSIX `sh`, safe under
# Alpine BusyBox, and leaves `set -eu`'s failure semantics on the caller.
#
# POSIX `sh` has no `local`, so every function below names its working
# variables with its own prefix. Do not assign a bare `status`, `path`,
# `offset`, etc. inside these bodies -- a same-named variable live in a
# caller is a real bug here, not a style question.

# Prints $* to stderr and exits. FAIL_STATUS (default 1) picks the exit code
# for callers that need a specific one, e.g. `FAIL_STATUS=2 fail "usage: ..."`.
fail() {
  printf '%s\n' "$*" >&2
  exit "${FAIL_STATUS:-1}"
}

# Prints $* to stdout, one line. Exists so a caller's informational output
# reads the same whether it takes one line or accumulates a few of them.
say() {
  printf '%s\n' "$*"
}

# Lightweight CI timing. COSMIC_TIMING_FILE, when set, must name a file outside
# the checkout/product. The POSIX date clock has one-second resolution. Records
# are append-only so an interrupted operation remains visible as an unmatched
# begin event. Labels are stable strings and must not contain tabs or newlines.
timing_begin() {
  tb_label=$1
  [ -n "${COSMIC_TIMING_FILE:-}" ] || return 0
  tb_now=$(date +%s) || return
  printf 'begin\t%s\t%s\n' "$tb_label" "$tb_now" >> "$COSMIC_TIMING_FILE"
  printf 'timing: START %s (clock resolution 1s)\n' "$tb_label" >&2
}

timing_end() {
  te_label=$1
  te_status=$2
  [ -n "${COSMIC_TIMING_FILE:-}" ] || return 0
  te_now=$(date +%s) || return
  te_elapsed=$((te_now - tb_now))
  printf 'end\t%s\t%s\t%s\n' "$te_label" "$te_now" "$te_status" >> "$COSMIC_TIMING_FILE"
  printf 'timing: END %s elapsed=%ss status=%s\n' \
    "$te_label" "$te_elapsed" "$te_status" >&2
}

# Run an external command with argv, streams, environment, and exit status
# unchanged. Do not pass shell functions: placing those in an `if` condition
# can disable their own set -e behavior on some shells.
timing_run() {
  tr_label=$1
  shift
  timing_begin "$tr_label"
  if "$@"; then
    tr_status=0
  else
    tr_status=$?
  fi
  timing_end "$tr_label" "$tr_status"
  return "$tr_status"
}

# Prints the hex sha256 of $1 on stdout. Preserves the digest command's exit
# status (a failed sha256sum/shasum fails this function; nothing downstream
# is fed through a pipe that could swallow that status).
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256_of_line=$(sha256sum "$1") || return
  else
    sha256_of_line=$(shasum -a 256 "$1") || return
  fi
  printf '%s\n' "${sha256_of_line%% *}"
}

# Resolves $1 to an absolute, symlink-free path even when its final
# component doesn't exist yet (only some leading prefix has to). Prints the
# result on stdout; returns nonzero if no prefix of the path exists.
canonical_directory_path() {
  cdp_path=$1
  cdp_suffix=
  while [ ! -e "$cdp_path" ]; do
    cdp_component=${cdp_path##*/}
    [ -n "$cdp_component" ] || return 1
    cdp_suffix="/$cdp_component$cdp_suffix"
    cdp_path=${cdp_path%/*}
    [ -n "$cdp_path" ] || cdp_path=/
  done
  cdp_ancestor=$(CDPATH= cd -- "$cdp_path" && pwd -P) || return 1
  if [ "$cdp_ancestor" = / ]; then
    printf '%s\n' "$cdp_ancestor${cdp_suffix#/}"
  else
    printf '%s\n' "$cdp_ancestor$cdp_suffix"
  fi
}

# Validates that $1 is an absolute, normalized path outside $2 (the
# checkout), creates it, and prints its canonical realpath on stdout. Exits 2
# with a named reason on any violation. Diagnostics drivers use this so a
# snapshot or a downloaded canonical artifact can never land inside the tree
# being tested. Always called from a command substitution in practice, so
# its working variables never reach the caller either way.
require_diagnostics_dir() {
  rdd_raw=$1
  rdd_checkout=$2
  case "$rdd_raw" in
    /*) ;;
    *) FAIL_STATUS=2 fail "diagnostics directory must be an absolute path: $rdd_raw" ;;
  esac
  case "/${rdd_raw#/}/" in
    *//*|*/./*|*/../*)
      FAIL_STATUS=2 fail "diagnostics directory must be a normalized path: $rdd_raw" ;;
  esac
  rdd_resolved=$(canonical_directory_path "$rdd_raw") ||
    FAIL_STATUS=2 fail "diagnostics path cannot be resolved: $rdd_raw"
  case "$rdd_resolved/" in
    "$rdd_checkout/"*)
      FAIL_STATUS=2 fail "diagnostics directory must be outside the checkout: $rdd_resolved" ;;
  esac
  mkdir -p "$rdd_resolved"
  rdd_resolved=$(CDPATH= cd -- "$rdd_resolved" && pwd -P)
  case "$rdd_resolved/" in
    "$rdd_checkout/"*)
      FAIL_STATUS=2 fail "diagnostics directory must be outside the checkout: $rdd_resolved" ;;
  esac
  printf '%s\n' "$rdd_resolved"
}

# Copies and hashes the raw working database (and any journal) into
# $diagnostics/$label, then opens a *second*, disposable copy outside the
# checkout with work_db_integrity.tl.in and surfaces its report. $cosmic
# defaults to $checkout/o/bin/cosmic. Returns the integrity probe's own
# status. $diagnostics must already be validated (require_diagnostics_dir).
# Callers that still need their own same-named variables afterward (this
# writes swd_status, among others) should call it inside a `( ... )`
# subshell.
snapshot_work_db() {
  swd_diagnostics=$1
  swd_label=$2
  swd_checkout=$3
  swd_cosmic=${4-}
  case "$swd_label" in
    ""|*/*|.|..)
      FAIL_STATUS=2 fail "snapshot label must be one nonempty path component" ;;
  esac
  swd_database="$swd_checkout/o/build.db"
  if [ -z "$swd_cosmic" ]; then swd_cosmic=$swd_checkout/o/bin/cosmic; fi
  case $swd_cosmic in /*) ;; *) swd_cosmic=$PWD/$swd_cosmic ;; esac
  swd_source_helper="$swd_checkout/test/portable/work_db_integrity.tl.in"
  swd_snapshot="$swd_diagnostics/$swd_label"

  if [ ! -f "$swd_database" ]; then
    fail "working database does not exist: $swd_database"
  fi
  if [ ! -x "$swd_cosmic" ]; then
    fail "Cosmic executable does not exist: $swd_cosmic"
  fi
  if ! mkdir "$swd_snapshot"; then
    fail "snapshot already exists or cannot be created: $swd_snapshot"
  fi

  cp "$swd_database" "$swd_snapshot/build.db"
  if [ -e "$swd_database-journal" ]; then
    cp "$swd_database-journal" "$swd_snapshot/build.db-journal"
  fi

  # Record the untouched bytes before SQLite opens any copy. Opening a
  # database with a journal may recover it, so the integrity probe below
  # gets another, disposable copy of both files.
  wc -c < "$swd_snapshot/build.db" > "$swd_snapshot/build.db.bytes"
  {
    swd_database_hash=$(sha256_of "$swd_snapshot/build.db") || exit
    printf '%s  build.db\n' "$swd_database_hash"
    if [ -e "$swd_snapshot/build.db-journal" ]; then
      swd_journal_hash=$(sha256_of "$swd_snapshot/build.db-journal") || exit
      printf '%s  build.db-journal\n' "$swd_journal_hash"
    fi
  } > "$swd_snapshot/hashes.sha256"
  if [ -e "$swd_snapshot/build.db-journal" ]; then
    wc -c < "$swd_snapshot/build.db-journal" > "$swd_snapshot/build.db-journal.bytes"
  fi

  swd_inspection=$(mktemp -d "$swd_diagnostics/.work-db-inspection.XXXXXX")
  swd_cleanup() {
    rm -rf "$swd_inspection"
  }
  trap swd_cleanup EXIT HUP INT TERM
  cp "$swd_snapshot/build.db" "$swd_inspection/build.db"
  if [ -e "$swd_snapshot/build.db-journal" ]; then
    cp "$swd_snapshot/build.db-journal" "$swd_inspection/build.db-journal"
  fi
  cp "$swd_source_helper" "$swd_inspection/work_db_integrity.tl"

  set +e
  (
    cd "$swd_inspection"
    "$swd_cosmic" work_db_integrity.tl build.db
  ) > "$swd_snapshot/integrity.out" 2> "$swd_snapshot/integrity.err"
  swd_status=$?
  set -e
  cat "$swd_snapshot/integrity.out"
  cat "$swd_snapshot/integrity.err" >&2
  trap - EXIT HUP INT TERM
  swd_cleanup
  return "$swd_status"
}

# Prints the field-numbered ($2) column of the targets.tsv ($1) row matching
# this host's `uname -s`/`uname -m`. Fails (via awk's END guard) if no row
# matches. Field numbers follow targets.tsv's own columns: 1 target_id,
# 2 configuration_id, 3 configuration, 4 target, 5 uname_os, 6 uname_arch.
host_target_field() {
  htf_targets=$1
  htf_field=$2
  awk -F "$(printf '\t')" -v sysname="$(uname -s)" -v arch="$(uname -m)" \
    -v field="$htf_field" \
    '$5 == sysname && $6 == arch { print $field; found = 1 } END { if (!found) exit 1 }' \
    "$htf_targets"
}

# Extracts one manifest core range at OFFSET/LENGTH (OFFSET must be
# block-aligned, like every manifest range) from SOURCE into OUT. If DIGEST
# is given, the extracted bytes' sha256 must equal it. If COMPARE_TO is
# given, the extracted bytes must cmp(1) equal to it. Either check alone
# already proves the range is exactly the expected bytes; callers pass
# whichever they already have on hand, or both.
#
# `head` bounds the final partial block; the length/digest/cmp checks below
# prove the pipeline produced the requested bytes even on a shell without
# pipefail.
extract_core_range() {
  ecr_source=$1
  ecr_offset=$2
  ecr_length=$3
  ecr_out=$4
  ecr_digest=${5-}
  ecr_compare_to=${6-}
  case $((ecr_offset % 16384)) in
    0) ;;
    *) fail "core range offset is not block-aligned: $ecr_offset" ;;
  esac
  ecr_blocks=$(( (ecr_length + 16383) / 16384 ))
  dd if="$ecr_source" bs=16384 skip=$((ecr_offset / 16384)) count="$ecr_blocks" \
      2>/dev/null | head -c "$ecr_length" > "$ecr_out"
  [ "$(wc -c < "$ecr_out" | tr -d ' ')" = "$ecr_length" ] ||
    fail "extracted core range has the wrong length: $ecr_out"
  if [ -n "$ecr_digest" ]; then
    [ "$(sha256_of "$ecr_out")" = "$ecr_digest" ] ||
      fail "extracted core range digest differs: $ecr_out"
  fi
  if [ -n "$ecr_compare_to" ]; then
    cmp "$ecr_compare_to" "$ecr_out"
  fi
}

# Compares exactly the first LENGTH bytes of LEFT and RIGHT. Extracting both
# bounded ranges avoids cmp implementations that still report EOF when -n
# reaches the exact end of one file while the other file continues.
compare_file_prefixes() {
  cfp_left=$1
  cfp_right=$2
  cfp_length=$3
  cfp_out=$4
  head -c "$cfp_length" "$cfp_left" > "$cfp_out.left"
  head -c "$cfp_length" "$cfp_right" > "$cfp_out.right"
  [ "$(wc -c < "$cfp_out.left" | tr -d ' ')" = "$cfp_length" ] ||
    fail "left file is shorter than the compared prefix: $cfp_left"
  [ "$(wc -c < "$cfp_out.right" | tr -d ' ')" = "$cfp_length" ] ||
    fail "right file is shorter than the compared prefix: $cfp_right"
  cmp "$cfp_out.left" "$cfp_out.right"
}

# Runs "$@" under a 30-second bound via `timeout`/`gtimeout`. On a host with
# neither, runs unbounded under GitHub Actions (the job's own bound still
# applies) with a `::notice::` explaining why, using NAME in that notice; off
# GitHub Actions this refuses to run unbounded (status 125) instead.
run_bounded() {
  rb_name=$1
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout 30 "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout 30 "$@"
  elif [ "${GITHUB_ACTIONS:-}" = true ]; then
    echo "::notice::timeout is unavailable; $rb_name runs under the existing job bound"
    "$@"
  else
    echo "timeout or gtimeout is required outside GitHub Actions" >&2
    return 125
  fi
}
