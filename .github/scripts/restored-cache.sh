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
# saving run's id and attempt.
set -eu

[ $# -eq 2 ] || { echo "usage: restored-cache.sh WHAT KEY" >&2; exit 2; }
what=$1
key=$2
if [ -z "$key" ]; then
  echo "restored no $what"
else
  run=${key%-*}
  echo "restored $what $key, saved by $GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/${run##*-}"
fi
