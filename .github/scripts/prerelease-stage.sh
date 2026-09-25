#!/usr/bin/env bash
# Checks the products prerelease.yml downloaded from every platform leg
# name the same bytes, which each leg executed, and stages the release
# from them: the cosmic executable, SHA256SUMS, source.json and the
# notes. PRODUCTS, RELEASE, SOURCE_COMMIT and SOURCE_RUN_URL come from
# the job. Nothing it reads is executed.
set -euo pipefail
expected_lanes=(
  alpine-x86_64
  linux-aarch64
  linux-x86_64
  macos-aarch64
)
mapfile -t actual_lanes < <(
  find "$PRODUCTS" -mindepth 1 -maxdepth 1 -type d \
    -name 'portable-product-*' -printf '%f\n' | sort
)
test "${#actual_lanes[@]}" -eq 4
for i in "${!expected_lanes[@]}"; do
  test "${actual_lanes[$i]}" = "portable-product-${expected_lanes[$i]}"
done

digest=
baseline="$PRODUCTS/portable-product-linux-x86_64/cosmic"
for lane in "${expected_lanes[@]}"; do
  product="$PRODUCTS/portable-product-$lane"
  test -f "$product/cosmic"
  test -f "$product/executed-cosmic.sha256"
  test -f "$product/expected-platforms"
  test "$(cat "$product/expected-platforms")" = 4
  manifest="$(cat "$product/executed-cosmic.sha256")"
  [[ "$manifest" =~ ^[0-9a-f]{64}\ \ cosmic$ ]]
  lane_digest="${manifest%% *}"
  test "$lane_digest" = "$(sha256sum "$product/cosmic" | cut -d' ' -f1)"
  cmp "$baseline" "$product/cosmic"
  if [ -z "$digest" ]; then
    digest="$lane_digest"
  else
    test "$lane_digest" = "$digest"
  fi
done

mkdir -p "$RELEASE"
cp "$PRODUCTS/portable-product-linux-x86_64/cosmic" "$RELEASE/cosmic"
printf '%s  cosmic\n' "$digest" > "$RELEASE/SHA256SUMS"
jq -n --arg commit "$SOURCE_COMMIT" --arg digest "$digest" \
  --arg run_url "$SOURCE_RUN_URL" \
  '{commit:$commit,digest:$digest,run_url:$run_url}' > "$RELEASE/source.json"
cat > "$RELEASE/notes.md" <<EOF
Prerelease of commit \`$SOURCE_COMMIT\` from [CI run]($SOURCE_RUN_URL).

The identical Cosmic bytes (SHA-256 \`$digest\`) were tested by all four native workers: Linux x86_64, Linux aarch64, macOS aarch64, and Alpine x86_64. Each worker uploaded its executed-byte attestation, and the provenance join verified all four hashes before publication.
EOF
