#!/bin/sh
set -eu

if [ "$#" -ne 2 ] && [ "$#" -ne 3 ]; then
  echo "usage: $0 {prepare|local|local-boundary|portable|portable-boundary} DIAGNOSTICS-DIRECTORY [PORTABLE_ARTIFACT]" >&2
  exit 2
fi

phase=$1
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
checkout=$(CDPATH= cd -- "$script_dir/../.." && pwd -P)
diagnostics=$2
portable_input=${3-}

canonical_directory_path() {
  path=$1
  suffix=
  while [ ! -e "$path" ]; do
    component=${path##*/}
    [ -n "$component" ] || return 1
    suffix="/$component$suffix"
    path=${path%/*}
    [ -n "$path" ] || path=/
  done
  ancestor=$(CDPATH= cd -- "$path" && pwd -P) || return 1
  if [ "$ancestor" = / ]; then
    printf '%s\n' "$ancestor${suffix#/}"
  else
    printf '%s\n' "$ancestor$suffix"
  fi
}

case "$diagnostics" in
  /*) ;;
  *)
    echo "diagnostics directory must be an absolute path: $diagnostics" >&2
    exit 2
    ;;
esac
case "/${diagnostics#/}/" in
  *//*|*/./*|*/../*)
    echo "diagnostics directory must be a normalized path: $diagnostics" >&2
    exit 2
    ;;
esac
diagnostics=$(canonical_directory_path "$diagnostics") || {
  echo "diagnostics path cannot be resolved: $diagnostics" >&2
  exit 2
}
case "$diagnostics/" in
  "$checkout/"*)
    echo "diagnostics directory must be outside the checkout: $diagnostics" >&2
    exit 2
    ;;
esac
mkdir -p "$diagnostics"
diagnostics=$(CDPATH= cd -- "$diagnostics" && pwd -P)
case "$diagnostics/" in
  "$checkout/"*)
    echo "diagnostics directory must be outside the checkout: $diagnostics" >&2
    exit 2
    ;;
esac
cd "$checkout"

cosmic="$checkout/o/bin/cosmic"
portable="$diagnostics/cosmic-portable"
cache="$diagnostics/portable-full-suite-cache"
snapshot="$script_dir/snapshot_work_db.sh"

hash_value() {
  if command -v sha256sum >/dev/null 2>&1; then value=$(sha256sum "$1") || return
  else value=$(shasum -a 256 "$1") || return; fi
  printf '%s\n' "${value%% *}"
}

run_bounded() {
  suite=$1
  stdout=$2
  stderr=$3
  name=$4
  if command -v timeout >/dev/null 2>&1; then
    timeout 30 "$suite" test > "$stdout" 2> "$stderr"
    status=$?
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout 30 "$suite" test > "$stdout" 2> "$stderr"
    status=$?
  elif [ "${GITHUB_ACTIONS:-}" = true ]; then
    echo "::notice::timeout is unavailable; the $name suite runs once under the existing 20-minute job bound"
    "$suite" test > "$stdout" 2> "$stderr"
    status=$?
  else
    : > "$stdout"
    echo "timeout or gtimeout is required outside GitHub Actions" > "$stderr"
    status=125
  fi
  printf '%s\n' "$status" > "$diagnostics/test.status"
  return "$status"
}

check_test_result() {
  status=$1
  output=$2
  if [ "$status" -ne 0 ]; then
    return "$status"
  fi
  grep -E 'test: PASS \([^;]+; [1-9][0-9]* ran, 0 stood\)' \
    "$output" >/dev/null
}

report_suite_failure() {
  name=$1
  status=$2
  if [ "$status" -eq 124 ]; then
    printf '%s suite: bounded command timed out (status 124)\n' "$name" >&2
  elif [ "$status" -ne 0 ]; then
    printf '%s suite: bounded command failed (status %s)\n' \
      "$name" "$status" >&2
  fi
}

case "$phase" in
  prepare)
    if [ -e "$portable" ] || [ -e "$cache" ]; then
      echo "prepare requires fresh portable artifact and cache paths in $diagnostics" >&2
      exit 1
    fi
    if [ -z "$portable_input" ]; then
      portable_input=$checkout/o/bin/cosmic
    else
      case $portable_input in /*) ;; *) portable_input=$PWD/$portable_input ;; esac
    fi
    if [ ! -x "$portable_input" ]; then
      echo "portable artifact is not executable: $portable_input" >&2
      exit 1
    fi
    cp "$portable_input" "$portable"
    chmod 755 "$portable"
    hash_value "$portable" > \
      "$diagnostics/portable-artifact.before.sha256"
    wc -c < "$portable" > \
      "$diagnostics/portable-artifact.before.bytes"
    ls -l "$portable" > \
      "$diagnostics/portable-artifact.before.listing"
    ;;

  local)
    local_out="$diagnostics/local-test.out"
    local_err="$diagnostics/local-test.err"
    set +e
    run_bounded "$cosmic" "$local_out" "$local_err" local
    status=$?
    set -e
    mv "$diagnostics/test.status" "$diagnostics/local-test.status"
    cat "$local_out"
    cat "$local_err" >&2
    report_suite_failure local "$status"
    set +e
    "$snapshot" "$diagnostics" local-immediate "$cosmic"
    snapshot_status=$?
    set -e
    if [ "$snapshot_status" -ne 0 ]; then
      printf 'local suite: immediate snapshot/integrity failed (status %s)\n' \
        "$snapshot_status" >&2
    fi
    if [ "$status" -ne 0 ]; then exit "$status"; fi
    if [ "$snapshot_status" -ne 0 ]; then exit "$snapshot_status"; fi
    check_test_result "$status" "$local_out"
    ;;

  local-boundary)
    "$snapshot" "$diagnostics" local-boundary "$cosmic"
    cmp "$diagnostics/local-immediate/hashes.sha256" \
      "$diagnostics/local-boundary/hashes.sha256"
    ;;

  portable)
    portable_out="$diagnostics/portable-test.out"
    portable_err="$diagnostics/portable-test.err"
    set +e
    COSMIC_PORTABLE_CACHE="$cache" \
      run_bounded "$portable" "$portable_out" "$portable_err" portable
    status=$?
    set -e
    mv "$diagnostics/test.status" "$diagnostics/portable-test.status"
    cat "$portable_out"
    cat "$portable_err" >&2
    if [ -d "$cache" ]; then
      find "$cache" -maxdepth 1 -type f -exec ls -l {} \; | sort > \
        "$diagnostics/portable-cache-files.txt"
    else
      printf 'cache directory was not created\n' > \
        "$diagnostics/portable-cache-files.txt"
    fi
    report_suite_failure portable "$status"
    set +e
    COSMIC_PORTABLE_CACHE="$cache" \
      "$snapshot" "$diagnostics" portable-immediate "$portable"
    snapshot_status=$?
    hash_value "$portable" > \
      "$diagnostics/portable-artifact.after.sha256"
    hash_status=$?
    if [ "$hash_status" -eq 0 ]; then
      cmp "$diagnostics/portable-artifact.before.sha256" \
        "$diagnostics/portable-artifact.after.sha256"
      hash_status=$?
    fi
    set -e
    if [ "$snapshot_status" -ne 0 ]; then
      printf 'portable suite: immediate snapshot/integrity failed (status %s)\n' \
        "$snapshot_status" >&2
    fi
    if [ "$hash_status" -ne 0 ]; then
      printf 'portable suite: artifact integrity failed (status %s)\n' \
        "$hash_status" >&2
    fi
    if [ "$status" -ne 0 ]; then exit "$status"; fi
    if [ "$snapshot_status" -ne 0 ]; then exit "$snapshot_status"; fi
    if [ "$hash_status" -ne 0 ]; then exit "$hash_status"; fi
    check_test_result "$status" "$portable_out"
    ;;

  portable-boundary)
    COSMIC_PORTABLE_CACHE="$cache" \
      "$snapshot" "$diagnostics" portable-boundary "$portable"
    if [ "${PORTABLE_OUTCOME:-}" = success ]; then
      cmp "$diagnostics/portable-immediate/hashes.sha256" \
        "$diagnostics/portable-boundary/hashes.sha256"
    fi
    ;;

  *)
    echo "unknown phase: $phase" >&2
    exit 2
    ;;
esac
