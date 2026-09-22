#!/bin/sh
set -eu

: "${COSMIC_DRIVER:?COSMIC_DRIVER is required}"
case "$COSMIC_DRIVER" in /*) ;; *) exit 1;; esac
cd "$(CDPATH= cd -- "$(dirname "$0")" && pwd -P)"
exec "$COSMIC_DRIVER" cosmic_ci/driver.tl "$@"
