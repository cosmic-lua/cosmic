# The image the alpine leg of .github/workflows/ci.yml runs in: Alpine with
# the tools the actions and the build need already installed, so a CI run
# installs nothing from a mirror. .github/workflows/ci-images.yml builds it
# for linux/amd64 and publishes it to GHCR; ci.yml names it by digest, and
# moving that digest is a deliberate edit.
#
# Alpine keeps no dated snapshot of its repositories and drops superseded
# package versions, so a rebuild may install newer ones; the digest ci.yml
# names is what stays fixed.
# TODO: install pinned versions from a mirror that keeps them, should
# Alpine or a third party offer dated snapshots as Ubuntu does.
FROM alpine:3.24.2@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6

RUN for attempt in 1 2 3; do \
      apk add --no-cache git tar zstd curl xz && break; \
      [ "$attempt" = 3 ] && exit 1; \
      sleep 10; \
    done
