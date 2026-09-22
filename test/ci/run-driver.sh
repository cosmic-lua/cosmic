#!/bin/sh
set -eu

: "${COSMIC_DRIVER:?COSMIC_DRIVER is required}"
: "${COSMIC_DRIVER_PROJECT:?COSMIC_DRIVER_PROJECT is required}"
case "$COSMIC_DRIVER:$COSMIC_DRIVER_PROJECT" in /*:/*) ;; *) exit 1;; esac
cd "$COSMIC_DRIVER_PROJECT"
COSMIC_DRIVER_PROJECT=$(pwd -P)
exec "$COSMIC_DRIVER" "$COSMIC_DRIVER_PROJECT/cosmic_ci/driver.tl" "$@"
