#!/bin/sh
# Says whether a push to main saves one of ci.yml's caches: unless the
# newest entry a restore would take now was saved from a descendant of
# this run's commit ($GITHUB_SHA), which a run of an older commit,
# finishing late, must not come to stand before.
#
#     sh .github/scripts/save-unless-descendant.sh KEY
#
# KEY is the `cache-matched-key` of a lookup of the cache (actions/cache
# with `lookup-only`) just before the save, empty where none is saved
# under its prefix or the lookup failed (the cache service erred), which
# it cannot tell apart. A key ends in `<commit>-<run id>-<attempt>`, the
# commit the entry was saved from; one saved before keys named it has
# none. The script writes `save=false` where that commit is a strict
# descendant of this one; `save=true` where no entry is saved, or it was
# saved from this commit, an ancestor, or a commit of history main no
# longer holds (after a force push: passed over, so main's next run
# saves again); and `save=unknown` where the key names no commit or git
# cannot tell (its fetch failed), to $GITHUB_OUTPUT, and says which and
# why on standard output. It always exits 0: whether to save on
# `unknown` is ci.yml's to decide.
#
# The checkout is one commit deep, and `git merge-base --is-ancestor`
# needs the history between the two commits. So it fetches the entry's
# commit and its ancestry, commits alone (`--filter=tree:0`, which
# leaves the checkout a partial clone for the job's last steps, none of
# which reads history). Where the entry descends from this commit the
# fetch stops here; where it does not -- the common case, an ancestor's
# entry -- the checkout's shallow boundary makes the server send the
# entry's whole ancestry, to the root, which as commits alone is
# cheap. It asks only whether this commit is the entry's ancestor; the
# converse would take this commit's own history, which the checkout
# does not hold. Run from the checkout, at the path
# it was checked out at, where its git finds origin and the credentials
# actions/checkout left for it.
set -u

[ $# -eq 1 ] || { echo "usage: save-unless-descendant.sh KEY" >&2; exit 2; }
key=$1
out=${GITHUB_OUTPUT:-/dev/stdout}
this=${GITHUB_SHA:-}

say() {
  echo "save-unless-descendant.sh: $2"
  echo "save=$1" >> "$out"
}

if [ -z "$key" ]; then
  say true "the lookup found no entry (none saved, or the lookup failed); save"
  exit 0
fi
rest=${key%-*}
rest=${rest%-*}
saved=${rest##*-}
case $saved in
  *[!0-9a-f]*) named= ;;
  ????????????????????????????????????????|????????????????????????????????????????????????????????????????) named=$saved ;;
  *) named= ;;
esac
if [ -z "$named" ]; then
  say unknown "the newest entry, $key, names no commit"
elif [ -z "$this" ]; then
  say unknown "GITHUB_SHA is unset"
elif [ "$saved" = "$this" ]; then
  say true "the newest entry, $key, was saved from this commit; save"
elif ! fetched=$(git fetch --quiet --no-tags --filter=tree:0 origin "$saved" 2>&1); then
  say unknown "the newest entry's commit $saved unfetched: $fetched"
else
  asked=$(git merge-base --is-ancestor "$this" "$saved" 2>&1)
  case $? in
    0) say false "the newest entry, $key, was saved from $saved, a descendant of this commit $this; no save" ;;
    1) say true "the newest entry, $key, was saved from $saved, no descendant of this commit $this; save" ;;
    *) say unknown "git merge-base failed: $asked" ;;
  esac
fi
