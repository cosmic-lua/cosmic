# The image the glibc Linux legs of .github/workflows/ci.yml run in:
# Ubuntu with the tools the actions and the build need already installed,
# so a CI run installs nothing from a mirror. .github/workflows/ci-images.yml
# builds it for linux/amd64 and linux/arm64 and publishes it to GHCR; ci.yml
# names it by digest, and moving that digest is a deliberate edit.
#
# The packages come from a dated snapshot of the archive, which never
# changes, so a rebuild at the same snapshot installs the same versions.
# snapshot.ubuntu.com is HTTPS-only and this base holds no CA bundle until
# ca-certificates is installed, so the build is handed the builder's bundle
# as a secret (id `ca`) for that; apt verifies the archive's signed indexes
# whatever the transport. The secret is readable by all because apt
# fetches as its own unprivileged `_apt` user.
FROM ubuntu:24.04@sha256:008173c23f95b170204355c12626cb5a965d779a7e1283b09e9cffbb1bf33ca3

ARG UBUNTU_SNAPSHOT
RUN --mount=type=secret,id=ca,required=true,mode=0444 \
    test -n "$UBUNTU_SNAPSHOT" && \
    printf '%s\n' 'Types: deb' \
      "URIs: https://snapshot.ubuntu.com/ubuntu/$UBUNTU_SNAPSHOT/" \
      'Suites: noble noble-updates noble-security' 'Components: main' \
      'Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg' \
      > /etc/apt/sources.list.d/ubuntu.sources && \
    set -- -o Acquire::Retries=5 -o Acquire::https::CaInfo=/run/secrets/ca && \
    apt-get "$@" --error-on=any update && \
    DEBIAN_FRONTEND=noninteractive apt-get "$@" install -y --no-install-recommends \
      ca-certificates curl git xz-utils zstd && \
    rm -rf /var/lib/apt/lists/*
