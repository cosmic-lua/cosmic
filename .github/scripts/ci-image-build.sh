#!/usr/bin/env bash
# Builds one of ci/images/ for one architecture, for ci-images.yml's build
# job, from the checkout's root, and pushes it when PUBLISH is true.
# IMAGE, ARCH, UBUNTU_SNAPSHOT and PUBLISH come from the job.
set -euo pipefail

# --provenance=false: a plain image, so the index publish joins
# holds the platforms and nothing else.
# GHCR names are lowercase; the repository's may not be.
name=$(printf 'ghcr.io/%s-ci-%s' "$GITHUB_REPOSITORY" "$IMAGE" | tr '[:upper:]' '[:lower:]')
set -- --platform "linux/$ARCH" --provenance=false \
  --label "org.opencontainers.image.source=$GITHUB_SERVER_URL/$GITHUB_REPOSITORY" \
  --label "org.opencontainers.image.revision=$GITHUB_SHA" \
  --build-arg "UBUNTU_SNAPSHOT=$UBUNTU_SNAPSHOT" \
  --secret id=ca,src=/etc/ssl/certs/ca-certificates.crt \
  --tag "$name:$GITHUB_SHA-$ARCH"
if [ "$PUBLISH" = true ]; then
  set -- "$@" --push
fi
docker buildx build "$@" "ci/images/$IMAGE"
