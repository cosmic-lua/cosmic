#!/usr/bin/env bash
# Publishes the staged release as the immutable next-<commit> prerelease,
# for prerelease.yml, or verifies the one already there: it resumes an
# interrupted draft only by accepting assets identical to the staged
# ones. GH_TOKEN, REPOSITORY, RELEASE, SOURCE_COMMIT and SOURCE_RUN_PREFIX
# come from the job.
set -euo pipefail
tag="next-$SOURCE_COMMIT"
expected_digest="$(sha256sum "$RELEASE/cosmic" | cut -d' ' -f1)"

# Return 1 only for an authenticated HTTP 404. Transport errors and
# other API failures return 2, so they can never trigger creation.
api_probe() {
  local endpoint=$1 response=$2 status
  if gh api --include "$endpoint" > "$response"; then
    return 0
  fi
  status="$(awk '/^HTTP\/[0-9.]+ [0-9]+/ { code=$2 } END { print code }' "$response")"
  [ "$status" = 404 ] && return 1
  return 2
}

verify_tag() {
  local resolved
  resolved="$(gh api "repos/$REPOSITORY/commits/$tag" --jq .sha)" || return
  test "$resolved" = "$SOURCE_COMMIT"
}

ensure_tag() {
  local result
  if api_probe "repos/$REPOSITORY/git/ref/tags/$tag" "$RUNNER_TEMP/tag-response"; then
    verify_tag
  else
    result=$?
    test "$result" = 1
    gh api --method POST "repos/$REPOSITORY/git/refs" \
      -f ref="refs/tags/$tag" -f sha="$SOURCE_COMMIT" >/dev/null
    verify_tag
  fi
}

validate_source() {
  local file=$1
  jq -e --arg commit "$SOURCE_COMMIT" --arg digest "$expected_digest" \
    --arg run_prefix "$SOURCE_RUN_PREFIX" \
    '.commit == $commit and .digest == $digest and
     (.run_url | type == "string" and startswith($run_prefix) and
      (ltrimstr($run_prefix) | test("^[0-9]+$")))' \
    "$file" >/dev/null
}

verify_assets() {
  local destination=$1
  mapfile -t names < <(gh release view "$tag" --repo "$REPOSITORY" \
    --json assets --jq '.assets[].name' | sort)
  test "${#names[@]}" -eq 3
  test "${names[0]}" = SHA256SUMS
  test "${names[1]}" = cosmic
  test "${names[2]}" = source.json
  mkdir -p "$destination"
  gh release download "$tag" --repo "$REPOSITORY" --dir "$destination"
  cmp "$RELEASE/cosmic" "$destination/cosmic"
  cmp "$RELEASE/SHA256SUMS" "$destination/SHA256SUMS"
  validate_source "$destination/source.json"
}

# The get-by-tag endpoint only promises published releases. Listing
# releases with authentication also finds an interrupted draft.
gh api --paginate --method GET "repos/$REPOSITORY/releases?per_page=100" \
  --jq ".[] | select(.tag_name == \"$tag\") | .id" \
  > "$RUNNER_TEMP/release-ids"
mapfile -t release_ids < "$RUNNER_TEMP/release-ids"
test "${#release_ids[@]}" -le 1
if [ "${#release_ids[@]}" -eq 1 ]; then
  verify_tag
  is_draft="$(gh release view "$tag" --repo "$REPOSITORY" --json isDraft --jq .isDraft)"
  is_prerelease="$(gh release view "$tag" --repo "$REPOSITORY" --json isPrerelease --jq .isPrerelease)"
  test "$is_prerelease" = true
  if [ "$is_draft" = false ]; then
    verify_assets "$RUNNER_TEMP/published"
    echo "prerelease already published and verified: $tag"
    exit 0
  fi
else
  ensure_tag
  gh release create "$tag" --repo "$REPOSITORY" --verify-tag \
    --title "$tag" --notes-file "$RELEASE/notes.md" --prerelease --draft
  verify_tag
fi

# Resume an interrupted draft by accepting only identical existing
# assets. source.json may name an earlier successful run for this SHA.
mapfile -t existing < <(gh release view "$tag" --repo "$REPOSITORY" \
  --json assets --jq '.assets[].name' | sort)
for name in "${existing[@]}"; do
  case "$name" in cosmic|SHA256SUMS|source.json) ;; *) exit 1 ;; esac
  mkdir -p "$RUNNER_TEMP/existing-$name"
  gh release download "$tag" --repo "$REPOSITORY" --pattern "$name" \
    --dir "$RUNNER_TEMP/existing-$name"
  if [ "$name" = source.json ]; then
    validate_source "$RUNNER_TEMP/existing-$name/$name"
  else
    cmp "$RELEASE/$name" "$RUNNER_TEMP/existing-$name/$name"
  fi
done
for name in cosmic SHA256SUMS source.json; do
  if ! printf '%s\n' "${existing[@]}" | grep -Fxq "$name"; then
    gh release upload "$tag" "$RELEASE/$name" --repo "$REPOSITORY"
  fi
done
verify_assets "$RUNNER_TEMP/completed"
gh release edit "$tag" --repo "$REPOSITORY" --draft=false --prerelease
verify_tag
verify_assets "$RUNNER_TEMP/published"
test "$(gh release view "$tag" --repo "$REPOSITORY" --json isDraft --jq .isDraft)" = false
