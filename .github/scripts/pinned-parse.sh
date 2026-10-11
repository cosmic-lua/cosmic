#!/bin/sh
# Compiles the Teal that bin/cosmic-bootstrap runs -- bin/zig,
# bin/vendor, bin/verify-codesign and the build directory's lookup --
# on the cosmic-driver the job has on its PATH, the release
# ci/cosmic-driver.pin names, whose Teal is the one those scripts must
# parse under. Each runs standalone, which type-checks the file before
# calling it, with an argument that does nothing: --help, and for zig.tl
# a COSMIC_ZIG that is the path of `true`, so no zig is installed. A refusal names
# the file, with the compiler's complaints above.
set -u

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
failed=0
true_path=/usr/bin/true
[ -x "$true_path" ] || true_path=/bin/true

check() {
  file=$1
  shift
  if ! "$@" >/dev/null; then
    echo "pinned-parse: build/$file does not run under the pinned cosmic-driver (ci/cosmic-driver.pin)" >&2
    failed=1
  fi
}

check zig.tl env COSMIC_ZIG="$true_path" cosmic-driver --standalone "$root/build/zig.tl" --help
check vendor.tl cosmic-driver --standalone "$root/build/vendor.tl" --help
check verify_codesign.tl cosmic-driver --standalone "$root/build/verify_codesign.tl" --help
check paths.tl cosmic-driver --standalone "$root/build/paths.tl" "$root"

exit "$failed"
