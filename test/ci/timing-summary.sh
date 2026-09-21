#!/bin/sh
set -eu

records=${1:?usage: timing-summary.sh RECORDS [OUTPUT]}
output=${2:-/dev/stdout}

{
  printf '| Operation | Elapsed (s) | Status |\n'
  printf '| --- | ---: | ---: |\n'
  if [ -f "$records" ]; then
    awk -F '\t' '
      $1 == "begin" { started[$2] = $3; order[++count] = $2; next }
      $1 == "end" && ($2 in started) {
        elapsed[$2] = $3 - started[$2]; status[$2] = $4; finished[$2] = 1
      }
      END {
        for (i = 1; i <= count; i++) {
          label = order[i]
          if (finished[label])
            printf "| %s | %s | %s |\n", label, elapsed[label], status[label]
          else
            printf "| %s | — | unfinished |\n", label
        }
      }
    ' "$records"
  fi
} >> "$output"
