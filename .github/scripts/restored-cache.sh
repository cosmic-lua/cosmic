#!/bin/sh
# Says which run saved the cache a restore step of ci.yml matched, next
# to the lines of the steps that use it: a restore takes the newest
# cache saved under its prefix, which need not be the newest commit's,
# and what the suites and builds say names only this run's work.
#
#     sh .github/scripts/restored-cache.sh WHAT KEY
#
# WHAT names the cache ("test verdicts"), and KEY is the restore step's
# `cache-matched-key`, empty where it restored nothing. A key ends in the
# commit the saving run ran and that run's id and attempt, or, saved
# before keys named the commit, in the id and attempt alone.
set -eu

[ $# -eq 2 ] || { echo "usage: restored-cache.sh WHAT KEY" >&2; exit 2; }
what=$1
key=$2
if [ -z "$key" ]; then
  echo "restored no $what"
else
  run=${key%-*}
  commit=${run%-*}
  commit=${commit##*-}
  case $commit in
    *[!0-9a-f]*) from= ;;
    ????????????????????????????????????????|????????????????????????????????????????????????????????????????) from=" from $commit" ;;
    *) from= ;;
  esac
  echo "restored $what $key, saved by $GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/${run##*-}$from"
fi
