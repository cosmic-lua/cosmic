#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: $0 {prepare|native|native-boundary|portable|portable-boundary} DIAGNOSTICS-DIRECTORY" >&2
  exit 2
fi

phase=$1
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
checkout=$(CDPATH= cd -- "$script_dir/../.." && pwd -P)
diagnostics=$2

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
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
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

case "$phase" in
  prepare)
    if [ -e "$portable" ] || [ -e "$cache" ]; then
      echo "prepare requires fresh portable artifact and cache paths in $diagnostics" >&2
      exit 1
    fi
    "$cosmic" "$script_dir/write_runtime_fixture.tl" \
      "$checkout/o/targets.tsv" "$checkout/o/core" \
      "$checkout/o/cosmic.portable.db" "$portable"
    chmod 755 "$portable"
    hash_value "$portable" > \
      "$diagnostics/portable-artifact.before.sha256"
    wc -c < "$portable" > \
      "$diagnostics/portable-artifact.before.bytes"
    ls -l "$portable" > \
      "$diagnostics/portable-artifact.before.listing"
    ;;

  native)
    native_out="$diagnostics/native-test.out"
    native_err="$diagnostics/native-test.err"
    set +e
    run_bounded "$cosmic" "$native_out" "$native_err" native
    status=$?
    set -e
    mv "$diagnostics/test.status" "$diagnostics/native-test.status"
    cat "$native_out"
    cat "$native_err" >&2
    "$snapshot" "$diagnostics" native-immediate
    check_test_result "$status" "$native_out"
    ;;

  native-boundary)
    "$snapshot" "$diagnostics" native-boundary
    cmp "$diagnostics/native-immediate/hashes.sha256" \
      "$diagnostics/native-boundary/hashes.sha256"
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
    "$snapshot" "$diagnostics" portable-immediate
    hash_value "$portable" > \
      "$diagnostics/portable-artifact.after.sha256"
    cmp "$diagnostics/portable-artifact.before.sha256" \
      "$diagnostics/portable-artifact.after.sha256"
    check_test_result "$status" "$portable_out"
    ;;

  portable-boundary)
    "$snapshot" "$diagnostics" portable-boundary
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
