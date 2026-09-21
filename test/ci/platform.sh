#!/bin/sh
# Shared orchestration for each native CI producer.
set -eu

usage() {
  echo "usage: platform.sh {build|test|portable|fixtures|boundary|alpine} ROOT TARGET WORK [BOUNDARY]" >&2
  exit 2
}

[ "$#" -ge 4 ] || usage
phase=$1
root=$2
target=$3
work=$4
boundary=${5-}

case $root in /*) ;; *) echo "platform CI: ROOT must be absolute" >&2; exit 2;; esac
case $work in /*) ;; *) echo "platform CI: WORK must be absolute" >&2; exit 2;; esac
[ -f "$root/AGENTS.md" ] || { echo "platform CI: invalid root: $root" >&2; exit 2; }
case $target in
  x86_64-linux-musl|aarch64-linux-musl|aarch64-macos) ;;
  *) echo "platform CI: unsupported target: $target" >&2; exit 2;;
esac

. "$root/test/portable/lib.sh"
mkdir -p "$work"
COSMIC_TIMING_FILE=${COSMIC_TIMING_FILE:-$work/timings.tsv}
export COSMIC_TIMING_FILE
: >> "$COSMIC_TIMING_FILE"
product=$work/product
contract=$work/contract
runtime=$work/runtime
local_diagnostics=$work/local-diagnostics
portable_diagnostics=$work/portable-diagnostics
fresh_source=$work/portable-source

archive_source() {
  destination=$1
  [ ! -e "$destination" ] || {
    echo "platform CI: tracked-source destination already exists: $destination" >&2
    exit 1
  }
  mkdir -p "$destination"
  git -C "$root" archive HEAD | tar -x -C "$destination"
  [ ! -e "$destination/o" ]
}

case $phase in
  build)
    [ "$#" -eq 4 ] || usage
    [ ! -e "$root/o" ] || {
      echo 'platform CI build requires a fresh checkout without o/' >&2
      exit 1
    }
    mkdir -p "$work"
    cd "$root"
    # CI keeps bin/zig's compile cache (o/zig-cache, o/zig-global) outside
    # the checkout between runs, since the guard above requires no o/ yet;
    # COSMIC_ZIG_CACHE_SEED, when set, names where it restored that cache
    # to, and this seeds it into place now that the guard has passed.
    if [ -n "${COSMIC_ZIG_CACHE_SEED:-}" ] && { [ -d "$COSMIC_ZIG_CACHE_SEED/zig-cache" ] ||
        [ -d "$COSMIC_ZIG_CACHE_SEED/zig-global" ]; }; then
      mkdir -p o
      [ ! -d "$COSMIC_ZIG_CACHE_SEED/zig-cache" ] || cp -a "$COSMIC_ZIG_CACHE_SEED/zig-cache" o/zig-cache
      [ ! -d "$COSMIC_ZIG_CACHE_SEED/zig-global" ] || cp -a "$COSMIC_ZIG_CACHE_SEED/zig-global" o/zig-global
    fi
    timing_run 'core build and boot' bin/zig build cores boot
    timing_run 'local suite' test/portable/full_suite.sh local "$local_diagnostics"
    ;;

  test)
    [ "$#" -eq 4 ] || usage
    [ -x "$root/o/bin/cosmic" ] || {
      echo 'platform CI test requires the release build' >&2
      exit 1
    }
    [ -f "$local_diagnostics/local-boundary/hashes.sha256" ] || {
      echo 'platform CI test requires the delayed local boundary' >&2
      exit 1
    }
    cd "$root"
    timing_run 'format check' o/bin/cosmic fix --check .
    timing_run 'codesign verification' bin/verify-codesign o/core/aarch64-macos/cosmic-core
    timing_run 'product assembly' test/portable/product.sh build "$product"
    sha256_of "$product/cosmic" > "$work/cosmic.before.sha256"
    timing_run 'format fixture' test/portable/format.sh "$contract/format" "$target"
    timing_run 'launcher fixture assembly' test/portable/launcher.sh build "$contract/launcher" "$target"

    # The checked boot mutates the local working database, so it follows the
    # release suite's delayed boundary. No other boot writer runs concurrently.
    timing_run 'checked build' bin/zig build sanitized
    timing_run 'checked suite' "$root/test/ci/checked-suite.sh" \
      "$root" "$target" "$work"
    timing_run 'hook-core build' bin/zig build portable-hook-cores --prefix "$work/prebuilt"
    mkdir -p "$work/prebuilt/portable-fixture/sanitized"
    cp o/sanitized/cosmic-core \
      "$work/prebuilt/portable-fixture/sanitized/cosmic-core"
    timing_run 'runtime fixture assembly' test/portable/runtime.sh build "$runtime" "$work/prebuilt" \
      "$product/cosmic" "$product/cosmic.db"

    signature=
    [ "$target" != aarch64-macos ] || signature=--codesign
    timing_run 'product verification' test/portable/product.sh test "$product" "$target" \
      "$contract/format/format-test-$target" $signature
    timing_run 'selected format mutation execution' \
      "$contract/format/format-test-$target" "$contract/format/program"

    archive_source "$fresh_source"
    timing_run 'portable suite preparation' \
      "$fresh_source/test/portable/full_suite.sh" prepare \
      "$portable_diagnostics" "$product/cosmic"
    ;;

  portable)
    [ "$#" -eq 4 ] || usage
    timing_run 'portable suite' "$fresh_source/test/portable/full_suite.sh" portable \
      "$portable_diagnostics"
    ;;

  fixtures)
    [ "$#" -eq 4 ] || usage
    cd "$root"
    signature=
    [ "$target" != aarch64-macos ] || signature=--codesign
    mkdir -p "$work/self-rebuild-diagnostics"
    TMPDIR="$work/self-rebuild-diagnostics" \
      timing_run 'self-rebuild regression' test/portable/self_rebuild.sh "$runtime"
    COSMIC_PORTABLE_DIAGNOSTICS="$work/runtime-diagnostics" \
      timing_run 'runtime regression' test/portable/runtime.sh test "$runtime"
    timing_run 'launcher regression' test/portable/launcher.sh test "$contract/launcher/launcher.test" \
      "$contract/launcher/payloads/socket-$target"
    timing_run 'identity regression' test/portable/identity_test.sh "$runtime"
    timing_run 'product regression' test/portable/product.sh test "$product" "$target" \
      "$contract/format/format-test-$target" $signature
    [ "$(sha256_of "$product/cosmic")" = \
      "$(cat "$work/cosmic.before.sha256")" ]
    ;;

  boundary)
    [ "$#" -eq 5 ] || usage
    case $boundary in
      local)
        "$root/test/portable/full_suite.sh" local-boundary \
          "$local_diagnostics"
        ;;
      portable)
        PORTABLE_OUTCOME=${PORTABLE_OUTCOME:-} \
          "$fresh_source/test/portable/full_suite.sh" portable-boundary \
            "$portable_diagnostics"
        ;;
      attest)
        expected=${EXPECTED_PLATFORMS:?platform CI attest requires EXPECTED_PLATFORMS}
        before=$(cat "$work/cosmic.before.sha256")
        after=$(sha256_of "$product/cosmic")
        portable_before=$(cat "$portable_diagnostics/portable-artifact.before.sha256")
        portable_after=$(cat "$portable_diagnostics/portable-artifact.after.sha256")
        [ "$before" = "$after" ]
        [ "$before" = "$portable_before" ]
        [ "$before" = "$portable_after" ]
        printf '%s  cosmic\n' "$before" > "$product/executed-cosmic.sha256"
        printf '%s\n' "$expected" > "$product/expected-platforms"
        ;;
      *) usage ;;
    esac
    ;;

  alpine)
    [ "$#" -eq 4 ] || usage
    [ "$target" = x86_64-linux-musl ] || {
      echo 'platform CI Alpine phase is only valid for x86_64-linux-musl' >&2
      exit 2
    }
    image=alpine:3.24.2@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6
    alpine_source=$work/alpine-source
    archive_source "$alpine_source"
    mkdir -p "$work/alpine-diagnostics" "$work/alpine-home"
    before=$(sha256_of "$product/cosmic")
    timing_run 'Alpine image pull' docker pull "$image"
    timing_run 'Alpine execution' docker run --rm --network none --user "$(id -u):$(id -g)" \
      -e GITHUB_ACTIONS=true -e HOME=/runner/alpine-home \
      -v "$alpine_source:/work" -w /work -v "$work:/runner" \
      "$image" /bin/sh -eu -c '
        test ! -e o
        /runner/contract/format/format-test-x86_64-linux-musl \
          /runner/contract/format/program
        test/portable/product.sh test /runner/product x86_64-linux-musl \
          /runner/contract/format/format-test-x86_64-linux-musl
        test/portable/full_suite.sh prepare \
          /runner/alpine-diagnostics/full /runner/product/cosmic
        test/portable/full_suite.sh portable /runner/alpine-diagnostics/full
      '
    timing_run 'Alpine read-only execution' docker run --rm --network none --user "$(id -u):$(id -g)" \
      -e GITHUB_ACTIONS=true -e HOME=/runner/alpine-home \
      -v "$alpine_source:/work" -w /work -v "$work:/runner" \
      "$image" /bin/sh -eu -c '
        cache=/runner/alpine-diagnostics/full/portable-full-suite-cache
        chmod 500 "$cache"
        COSMIC_PORTABLE_CACHE="$cache" \
          /runner/alpine-diagnostics/full/cosmic-portable help
        chmod 700 "$cache"
        PORTABLE_OUTCOME=success test/portable/full_suite.sh \
          portable-boundary /runner/alpine-diagnostics/full
        test/portable/product.sh test /runner/product x86_64-linux-musl \
          /runner/contract/format/format-test-x86_64-linux-musl
      '
    [ "$before" = "$(sha256_of "$product/cosmic")" ]
    ;;

  *) usage ;;
esac
