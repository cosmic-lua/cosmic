#!/bin/sh
# After a failed weekly review, print why Claude stopped: the result
# message's text and errors, and each API error. The action hides its
# output unless show_full_output is set, and that would put the whole
# transcript in the public log; re-running in debug mode does not show it.
set -eu
f="$RUNNER_TEMP/claude-execution-output.json"
if [ ! -f "$f" ]; then
  echo "no execution file at $f"
  exit 0
fi
# The message types, so an empty or cut-short stream shows as such.
jq -c '[.[] | [.type, .subtype]]' "$f"
# Only error text, cut short: a run that ends after real work has the
# model's final words as its result, which the public log need not hold.
jq '.[] | select((.type == "result" and .is_error)
    or (.type == "assistant" and (.error != null or .message.model == "<synthetic>")))
  | {type, subtype, error, errors, result: (.result // "")[0:1000],
     text: [.message.content[]? | .text? // empty | .[0:1000]]}' "$f"
