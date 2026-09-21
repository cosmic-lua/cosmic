#!/bin/sh
# Prove that every successful native leg executed and uploaded one Cosmic.
set -eu

products=${1:?usage: provenance.sh PRODUCTS_DIRECTORY}
case $products in /*) ;; *) products=$PWD/$products ;; esac
[ -d "$products" ] || { echo "provenance: missing products: $products" >&2; exit 2; }

count=0
expected=
baseline=
for product in "$products"/portable-product-*; do
  [ -d "$product" ] || continue
  [ -f "$product/executed-cosmic.sha256" ] && \
    [ -f "$product/expected-platforms" ] && [ -f "$product/cosmic" ] || {
    echo "provenance: incomplete product: $product" >&2
    exit 1
  }
  product_expected=$(cat "$product/expected-platforms")
  (cd "$product" && sha256sum -c executed-cosmic.sha256)
  [ -z "$expected" ] && expected=$product_expected
  [ "$expected" = "$product_expected" ]
  if [ -z "$baseline" ]; then
    baseline=$product/executed-cosmic.sha256
  else
    cmp "$baseline" "$product/executed-cosmic.sha256"
  fi
  count=$((count + 1))
done

[ -n "$expected" ]
[ "$count" -eq "$expected" ] || {
  echo "provenance: expected $expected products, found $count" >&2
  exit 1
}
printf 'provenance: PASS (%s native executions uploaded Cosmic %s)\n' \
  "$count" "$(awk '{print $1}' "$baseline")"
