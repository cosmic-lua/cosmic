#!/usr/bin/env bash
# Joins one image's architectures under one tag, for ci-images.yml's
# publish job, and reports the index's digest on the run's summary.
# IMAGE, ARCHES and TOKEN come from the job.
set -euo pipefail
name=$(printf 'ghcr.io/%s-ci-%s' "$GITHUB_REPOSITORY" "$IMAGE" | tr '[:upper:]' '[:lower:]')
printf '%s\n' "$TOKEN" | docker login ghcr.io -u "$GITHUB_ACTOR" --password-stdin
set --
for arch in $ARCHES; do
  set -- "$@" "$name:$GITHUB_SHA-$arch"
done
docker buildx imagetools create --tag "$name:$GITHUB_SHA" "$@"
digest=$(docker buildx imagetools inspect "$name:$GITHUB_SHA" |
  awk '$1 == "Digest:" { print $2; exit }')
case $digest in sha256:*) ;; *) echo "no digest for $name:$GITHUB_SHA" >&2; exit 1 ;; esac
echo "$name@$digest"
printf '%s: `%s@%s`\n' "$IMAGE" "$name" "$digest" >> "$GITHUB_STEP_SUMMARY"
