#!/bin/sh
# Says whether this run's commit ($GITHUB_SHA) is still main's head, for
# ci.yml's verdict cache save on a push to main:
#
#     sh .github/scripts/main-head.sh
#
# writes `head=true`, `head=false`, or `head=unknown` where main's head
# cannot be read (ls-remote failed or answered nothing), to
# $GITHUB_OUTPUT, and says which on standard output. It asks the remote,
# not the checkout, whose main is the commit it fetched: run from the
# checkout, at the path it was checked out at, where its git finds
# origin and the credentials actions/checkout left for it. It always
# exits 0: whether to save on `unknown` is ci.yml's to decide.
set -u

out=${GITHUB_OUTPUT:-/dev/stdout}
remote=$(git ls-remote origin refs/heads/main 2>&1)
status=$?
main=$(printf '%s\n' "$remote" | sed -n 's|^\([0-9a-f]\{40,64\}\)[[:space:]]*refs/heads/main$|\1|p')
if [ "$status" -ne 0 ] || [ -z "$main" ]; then
  echo "main-head.sh: main's head unread (git ls-remote exit $status): $remote"
  echo "head=unknown" >> "$out"
elif [ "$main" = "${GITHUB_SHA:-}" ]; then
  echo "main-head.sh: $main, this run's commit, is main's head"
  echo "head=true" >> "$out"
else
  echo "main-head.sh: main's head is $main, not this run's commit ${GITHUB_SHA:-(unset)}"
  echo "head=false" >> "$out"
fi
